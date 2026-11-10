package runner

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/FullFran/gentle-factory/pipeline"
)

var targetRe = regexp.MustCompile(`^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)#([1-9][0-9]*)$`)

// Final statuses of a start; they map to the exit codes of the other commands.
const (
	startComplete      = "COMPLETE"
	startStopped       = "STOPPED"
	startNotReady      = "NOT_READY"
	startMisconfigured = "MISCONFIGURED"
)

// startOpts are the options shared by start and watch.
type startOpts struct {
	workRoot, archive, spec string
	keep                    bool
}

// startResult is the outcome of one start. locked means nothing ran because
// another process holds the issue.
type startResult struct {
	status, run, archive string
	locked               bool
}

func (r startResult) code() int {
	switch r.status {
	case startComplete:
		return exitOK
	case startMisconfigured:
		return exitUsage
	}
	return exitStopped
}

func xdgDir(env, fallback string) (string, error) {
	if d := os.Getenv(env); d != "" {
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", specErr("cannot find the home directory (set %s): %v", env, err)
	}
	return filepath.Join(home, fallback), nil
}

// resolve fills the defaults: a work root under the cache dir, an archive under the data dir.
func (o *startOpts) resolve() error {
	var err error
	if o.workRoot == "" {
		if o.workRoot, err = xdgDir("XDG_CACHE_HOME", ".cache"); err != nil {
			return err
		}
		o.workRoot = filepath.Join(o.workRoot, "gentle-factory", "work")
	}
	if o.archive == "" {
		if o.archive, err = xdgDir("XDG_DATA_HOME", filepath.Join(".local", "share")); err != nil {
			return err
		}
		o.archive = filepath.Join(o.archive, "gentle-factory", "runs")
	}
	if o.workRoot, err = filepath.Abs(o.workRoot); err != nil {
		return err
	}
	if o.archive, err = filepath.Abs(o.archive); err != nil {
		return err
	}
	if o.spec != "" {
		if o.spec, err = filepath.Abs(o.spec); err != nil {
			return err
		}
	}
	return nil
}

// errLocked reports that another live process holds a lock.
var errLocked = errors.New("locked")

func pidAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// acquireLock creates path exclusively with our pid in it. A lock whose pid is dead is stale and taken over.
func acquireLock(path string) (func(), error) {
	dir := filepath.Dir(path)
	for attempt := 0; attempt < 3; attempt++ {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err == nil {
			_, werr := fmt.Fprintln(f, os.Getpid())
			if cerr := f.Close(); werr == nil {
				werr = cerr
			}
			if werr != nil {
				_ = os.Remove(path)
				return nil, werr
			}
			return func() {
				_ = os.Remove(path)
				_ = os.Remove(dir) // only when empty, so no empty locks dir stays behind
			}, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return nil, err
		}
		data, rerr := os.ReadFile(path)
		if rerr != nil {
			continue // released between the two calls
		}
		if pid, perr := strconv.Atoi(strings.TrimSpace(string(data))); perr == nil && pidAlive(pid) {
			return nil, errLocked
		}
		_ = os.Remove(path)
	}
	return nil, errLocked
}

func issueLockPath(workRoot, repo string, issue int) string {
	return filepath.Join(workRoot, "locks", fmt.Sprintf("%s+%d.lock", strings.ReplaceAll(repo, "/", "+"), issue))
}

// copyTree copies the regular files of src into dst.
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case d.Type().IsRegular():
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			return os.WriteFile(target, data, 0o644)
		}
		return nil
	})
}

// startIssue clones repo, collects issue, runs the pipeline, archives the receipts and
// deletes the clone. Whatever happens after the clone, the receipts are archived first.
func startIssue(repo string, issue int, o startOpts, out io.Writer) (res startResult) {
	target := fmt.Sprintf("%s#%d", repo, issue)
	res = startResult{status: startMisconfigured, run: "-", archive: "-"}
	fail := func(status, format string, args ...any) startResult {
		fmt.Fprintf(out, "START: reason=%s\n", strings.Join(strings.Fields(fmt.Sprintf(format, args...)), " "))
		res.status = status
		return res
	}
	if err := os.MkdirAll(o.workRoot, 0o755); err != nil {
		return fail(startMisconfigured, "cannot create the work root: %v", err)
	}
	release, err := acquireLock(issueLockPath(o.workRoot, repo, issue))
	if errors.Is(err, errLocked) {
		res.locked = true
		return fail(startStopped, "%s is locked by another run", target)
	}
	if err != nil {
		return fail(startMisconfigured, "cannot lock %s: %v", target, err)
	}
	defer release()

	workDir, err := os.MkdirTemp(o.workRoot, "run-")
	if err != nil {
		return fail(startMisconfigured, "cannot create a work directory: %v", err)
	}
	keep := o.keep
	defer func() {
		if keep {
			fmt.Fprintf(out, "START: kept clone=%s\n", filepath.Join(workDir, "repo"))
			return
		}
		_ = os.RemoveAll(workDir)
	}()

	clone := filepath.Join(workDir, "repo")
	if _, err := gh("repo", "clone", repo, clone); err != nil {
		return fail(startMisconfigured, "%v", err)
	}
	branch := fmt.Sprintf("factory/%d", issue)
	remote, err := git(clone, "ls-remote", "--heads", "origin", "refs/heads/"+branch)
	if err != nil {
		return fail(startMisconfigured, "%v", err)
	}
	if strings.TrimSpace(remote) != "" {
		return fail(startStopped, "branch %s already exists on origin; delete it to start again (nothing was run or changed)", branch)
	}

	spec := o.spec
	if spec == "" {
		specDir := filepath.Join(workDir, "pipeline")
		if err := os.Mkdir(specDir, 0o755); err != nil {
			return fail(startMisconfigured, "%v", err)
		}
		if spec, err = pipeline.Materialize(specDir); err != nil {
			return fail(startMisconfigured, "%v", err)
		}
	}

	ctxDir := filepath.Join(workDir, "context")
	err = collect(collectArgs{repo: repo, issue: issue, checkout: clone, out: ctxDir}, out)
	if nr, ok := err.(*notReady); ok {
		fmt.Fprintf(out, "COLLECT: status=NOT_READY reason=%s\n", strings.Join(strings.Fields(nr.msg), " "))
		res.status = startNotReady
		return res
	}
	if err != nil {
		return fail(startMisconfigured, "%v", err)
	}

	runID := newRunID()
	code, runErr := runFactory(runArgs{spec: spec, repo: clone, context: filepath.Join(ctxDir, "context.json"), runID: runID}, out)
	switch {
	case runErr != nil:
		fmt.Fprintf(out, "START: reason=%s\n", strings.Join(strings.Fields(runErr.Error()), " "))
		res.status = startMisconfigured
	case code == exitOK:
		res.status = startComplete
	default:
		res.status = startStopped
	}

	// The receipts outlive the clone; if they cannot be copied, the clone stays.
	if src := filepath.Join(clone, "odd", "runs", runID); dirExists(src) {
		dst := filepath.Join(o.archive, runID)
		if err := copyTree(src, dst); err != nil {
			keep = true
			fmt.Fprintf(out, "START: reason=cannot archive the receipts to %s: %v\n", dst, err)
			res.status = startMisconfigured
			res.run = runID
			return res
		}
		res.run, res.archive = runID, dst
		// Tell the owner on the issue (#15); a failed report never changes the run's outcome.
		if runErr == nil {
			if _, err := report(o.archive, runID, filepath.Join(ctxDir, "context.json"), 0, out, out); err != nil {
				fmt.Fprintf(out, "START: reason=report failed: %s\n", strings.Join(strings.Fields(err.Error()), " "))
			}
		}
	}
	return res
}

func dirExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func printStart(out io.Writer, repo string, issue int, r startResult) {
	fmt.Fprintf(out, "START: status=%s issue=%s#%d run=%s archive=%s\n", r.status, repo, issue, r.run, r.archive)
}

// parseFlagsAnywhere parses fs, allowing positional arguments before, between or after flags.
func parseFlagsAnywhere(fs *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		if fs.NArg() == 0 {
			return positional, nil
		}
		positional = append(positional, fs.Arg(0))
		args = fs.Args()[1:]
	}
}

func (o *startOpts) bind(fs *flag.FlagSet) {
	fs.StringVar(&o.workRoot, "work-root", "", "where clones live while a run lasts (default $XDG_CACHE_HOME/gentle-factory/work)")
	fs.StringVar(&o.archive, "archive", "", "where receipts are kept (default $XDG_DATA_HOME/gentle-factory/runs)")
	fs.StringVar(&o.spec, "spec", "", "factory spec JSON (default: the pipeline embedded in the binary)")
}

func cmdStart(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var o startOpts
	o.bind(fs)
	fs.BoolVar(&o.keep, "keep", false, "keep the clone after the run (debugging)")
	pos, err := parseFlagsAnywhere(fs, args)
	if err != nil {
		return 0, err
	}
	if len(pos) != 1 {
		return 0, specErr("start needs one OWNER/NAME#N argument")
	}
	m := targetRe.FindStringSubmatch(pos[0])
	if m == nil {
		return 0, specErr("%q is not OWNER/NAME#N", pos[0])
	}
	issue, _ := strconv.Atoi(m[3])
	repo := m[1] + "/" + m[2]
	if err := o.resolve(); err != nil {
		return 0, err
	}
	res := startIssue(repo, issue, o, stdout)
	printStart(stdout, repo, issue, res)
	return res.code(), nil
}
