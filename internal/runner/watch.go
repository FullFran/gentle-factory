package runner

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// stateFile maps OWNER/NAME#N to the design sha256 last started; it lives in the work root.
const stateFile = "watch-state.json"

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func loadWatchState(path string) (map[string]string, error) {
	state := map[string]string{}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	if err != nil {
		return nil, err
	}
	if err := decodeStrictBytes(data, &state); err != nil {
		return nil, specErr("cannot read %s: %v", path, err)
	}
	return state, nil
}

func saveWatchState(path string, state map[string]string) error {
	data, _ := json.MarshalIndent(state, "", "  ")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func decodeStrictBytes(data []byte, v any) error {
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// designSHA is the sha256 of the latest factory-design:v1 comment of an issue ("" when there is none).
func designSHA(repo string, issue int) (string, error) {
	c, err := latestDesignComment(repo, issue)
	if err != nil || c == nil {
		return "", err
	}
	return sha256Text(c.Body), nil
}

func readyIssues(repo string) ([]int, error) {
	raw, err := gh("issue", "list", "-R", repo, "--label", readyLabel, "--state", "open", "--limit", "200", "--json", "number")
	if err != nil {
		return nil, err
	}
	var issues []struct {
		Number int `json:"number"`
	}
	if err := json.Unmarshal(raw, &issues); err != nil {
		return nil, specErr("cannot read issue list JSON: %v", err)
	}
	numbers := make([]int, 0, len(issues))
	for _, i := range issues {
		numbers = append(numbers, i.Number)
	}
	sort.Ints(numbers)
	return numbers, nil
}

type watchOpts struct {
	repos    []string
	interval time.Duration
	slots    int
	maxOpen  int
	once     bool
	start    startOpts
}

// watchPass starts, sequentially, up to slots ready issues whose design was not started yet.
func watchPass(w watchOpts, statePath string, out io.Writer) error {
	sp := w.start.statusPath
	// Every pass ends by saying so in the status file (#43), also when it had errors.
	defer updateStatus(sp, out, func(s *factoryStatus) {
		if s.Watcher != nil {
			s.Watcher.LastPassAt = statusTime(time.Now())
		}
	})
	state, err := loadWatchState(statePath)
	if err != nil {
		return err
	}
	started := 0
	var firstErr error
	note := func(err error) {
		fmt.Fprintf(out, "WATCH: error=%s\n", strings.Join(strings.Fields(err.Error()), " "))
		if firstErr == nil {
			firstErr = err
		}
	}
	for _, repo := range w.repos {
		numbers, err := readyIssues(repo)
		if err != nil {
			note(err)
			continue
		}
		updateStatus(sp, out, func(s *factoryStatus) { setQueue(s, repo, numbers) })
		open, err := openFactoryPRs(repo)
		if err != nil {
			note(err)
			continue
		}
		for _, n := range numbers {
			key := fmt.Sprintf("%s#%d", repo, n)
			sha, err := designSHA(repo, n)
			if err != nil {
				note(err)
				continue
			}
			skip := func(reason string) { fmt.Fprintf(out, "WATCH: issue=%s skip reason=%s\n", key, reason) }
			switch {
			case sha == "":
				skip("no_design")
			case state[key] == sha:
				skip("same_design")
			case open >= w.maxOpen:
				skip(fmt.Sprintf("backpressure open_factory_prs=%d", open))
			case started >= w.slots:
				skip("slots_full")
			default:
				fmt.Fprintf(out, "WATCH: issue=%s start design=%s\n", key, sha[:12])
				updateStatus(sp, out, func(s *factoryStatus) { setSlotsBusy(s, 1) })
				res := startIssue(repo, n, w.start, out)
				updateStatus(sp, out, func(s *factoryStatus) { setSlotsBusy(s, 0) })
				printStart(out, repo, n, res)
				if res.locked {
					continue // another run owns it; it neither consumes a slot nor counts as started
				}
				started++
				if res.status != startMisconfigured { // a broken environment may heal; retry on the next pass
					state[key] = sha
					if err := saveWatchState(statePath, state); err != nil {
						return err
					}
				}
			}
		}
	}
	fmt.Fprintf(out, "WATCH: pass done started=%d\n", started)
	return firstErr
}

// watchRepoOK is the OWNER/NAME rule shared by --repo and --repos-file entries.
func watchRepoOK(r string) bool {
	return strings.Contains(r, "/") && !strings.ContainsAny(r, "# \t\r\n\v\f")
}

// watchRepos returns the repositories to watch: the entries of each file (in flag order, then
// line order), then the --repo values, with duplicates dropped keeping the first occurrence.
// A file holds one OWNER/NAME per line; blank lines, # comment lines and trailing " #..." are ignored.
func watchRepos(files, repos []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	add := func(r string) {
		if !seen[r] {
			seen[r] = true
			out = append(out, r)
		}
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, specErr("cannot read repos file %s: %v", f, err)
		}
		for i, line := range strings.Split(string(data), "\n") {
			entry := strings.TrimSpace(line)
			if entry == "" || strings.HasPrefix(entry, "#") {
				continue
			}
			if j := strings.IndexFunc(entry, func(c rune) bool { return c == ' ' || c == '\t' }); j >= 0 {
				if rest := strings.TrimLeft(entry[j:], " \t"); strings.HasPrefix(rest, "#") {
					entry = strings.TrimSpace(entry[:j])
				}
			}
			if !watchRepoOK(entry) {
				return nil, specErr("%s:%d: %q is not OWNER/NAME", f, i+1, entry)
			}
			add(entry)
		}
	}
	for _, r := range repos {
		if !watchRepoOK(r) {
			return nil, specErr("%q is not OWNER/NAME", r)
		}
		add(r)
	}
	return out, nil
}

func cmdWatch(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("watch", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var w watchOpts
	var repos, reposFiles multiFlag
	var interval int
	w.start.bind(fs)
	fs.Var(&repos, "repo", "GitHub repository OWNER/NAME to watch (repeatable)")
	fs.Var(&reposFiles, "repos-file", "file with one OWNER/NAME per line (repeatable); blank lines and # comments are ignored")
	fs.IntVar(&interval, "interval", 60, "seconds between passes")
	fs.IntVar(&w.slots, "slots", 1, "issues started per pass")
	fs.IntVar(&w.maxOpen, "max-open-prs", 3, "start nothing while this many factory draft PRs await review")
	fs.BoolVar(&w.once, "once", false, "do one pass and exit")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	all, err := watchRepos(reposFiles, repos)
	if err != nil {
		return 0, err
	}
	if len(all) == 0 || fs.NArg() > 0 || w.slots < 1 || w.maxOpen < 1 || interval < 1 {
		return 0, specErr("watch needs at least one --repo or --repos-file entry, --slots >= 1, --max-open-prs >= 1 and --interval >= 1, and no positional arguments")
	}
	w.repos, w.interval = all, time.Duration(interval)*time.Second
	if err := w.start.resolve(); err != nil {
		return 0, err
	}
	if err := os.MkdirAll(w.start.workRoot, 0o755); err != nil {
		return 0, err
	}
	release, err := acquireLock(filepath.Join(w.start.workRoot, "watch.lock"))
	if errors.Is(err, errLocked) {
		fmt.Fprintf(stdout, "WATCH: status=STOPPED reason=another watcher holds %s\n", filepath.Join(w.start.workRoot, "watch.lock"))
		return exitStopped, nil
	}
	if err != nil {
		return 0, err
	}
	defer release()
	updateStatus(w.start.statusPath, stdout, func(s *factoryStatus) { startWatcher(s, w) })

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	statePath := filepath.Join(w.start.workRoot, stateFile)
	for {
		err := watchPass(w, statePath, stdout)
		if w.once {
			if err != nil {
				return exitUsage, nil
			}
			return exitOK, nil
		}
		if err != nil {
			fmt.Fprintf(stdout, "WATCH: pass failed, retrying in %s\n", w.interval)
		}
		select { // a signal ends the watcher between passes; a run in progress finishes first
		case <-sigs:
			return exitOK, nil
		case <-time.After(w.interval):
		}
	}
}

// openFactoryPRs counts the repository's open draft PRs from factory/ branches: work that
// waits for the owner's review. Back-pressure (#16) stops new runs at --max-open-prs.
func openFactoryPRs(repo string) (int, error) {
	raw, err := gh("pr", "list", "-R", repo, "--state", "open", "--json", "headRefName,isDraft", "--limit", "100")
	if err != nil {
		return 0, err
	}
	var prs []struct {
		HeadRefName string `json:"headRefName"`
		IsDraft     bool   `json:"isDraft"`
	}
	if err := json.Unmarshal(raw, &prs); err != nil {
		return 0, specErr("cannot read pull requests JSON: %v", err)
	}
	n := 0
	for _, pr := range prs {
		if pr.IsDraft && strings.HasPrefix(pr.HeadRefName, "factory/") {
			n++
		}
	}
	return n, nil
}

// startWatcher sets the watcher section of the status file (#43) when a watcher takes its
// lock. A run left as current by a crashed process is not running anymore, and only the
// queue of watched repositories is kept, in the order they are watched.
func startWatcher(s *factoryStatus, w watchOpts) {
	s.Watcher = &watcherStatus{StartedAt: statusTime(time.Now()), Slots: w.slots, Repositories: append([]string{}, w.repos...)}
	s.CurrentRun = nil
	queue := []queueEntry{}
	for _, repo := range w.repos {
		for _, q := range s.Queue {
			if q.Repository == repo {
				queue = append(queue, q)
				break
			}
		}
	}
	s.Queue = queue
}

func setSlotsBusy(s *factoryStatus, n int) {
	if s.Watcher != nil {
		s.Watcher.SlotsBusy = n
	}
}

// setQueue replaces the ready issues of repo, or adds them after the other repositories.
func setQueue(s *factoryStatus, repo string, numbers []int) {
	for i := range s.Queue {
		if s.Queue[i].Repository == repo {
			s.Queue[i].Issues = append([]int{}, numbers...)
			return
		}
	}
	s.Queue = append(s.Queue, queueEntry{Repository: repo, Issues: append([]int{}, numbers...)})
}
