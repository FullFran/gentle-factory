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
	once     bool
	start    startOpts
}

// watchPass starts, sequentially, up to slots ready issues whose design was not started yet.
func watchPass(w watchOpts, statePath string, out io.Writer) error {
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
			case started >= w.slots:
				skip("slots_full")
			default:
				fmt.Fprintf(out, "WATCH: issue=%s start design=%s\n", key, sha[:12])
				res := startIssue(repo, n, w.start, out)
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

func cmdWatch(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("watch", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var w watchOpts
	var repos multiFlag
	var interval int
	w.start.bind(fs)
	fs.Var(&repos, "repo", "GitHub repository OWNER/NAME to watch (repeatable)")
	fs.IntVar(&interval, "interval", 60, "seconds between passes")
	fs.IntVar(&w.slots, "slots", 1, "issues started per pass")
	fs.BoolVar(&w.once, "once", false, "do one pass and exit")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	if len(repos) == 0 || fs.NArg() > 0 || w.slots < 1 || interval < 1 {
		return 0, specErr("watch needs at least one --repo, --slots >= 1 and --interval >= 1, and no positional arguments")
	}
	for _, r := range repos {
		if !strings.Contains(r, "/") || strings.ContainsAny(r, "# ") {
			return 0, specErr("%q is not OWNER/NAME", r)
		}
	}
	w.repos, w.interval = repos, time.Duration(interval)*time.Second
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
