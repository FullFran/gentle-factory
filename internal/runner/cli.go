package runner

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const usage = `factory: gentle-factory node runner

Usage:
  factory collect --repo OWNER/NAME --issue N --checkout DIR --out DIR
      Check that the issue is ready (label factory:ready and a valid
      factory-design:v1 comment whose done_when fails before any change), write
      context.json, design.md and issue.md
      to DIR, and create branch factory/N from origin's default branch.
      Exit 1 when the issue is not ready.
  factory run --spec SPEC --repo REPO --context CONTEXT [--run-id ID] [--runs-dir DIR]
      Run (or resume, with --run-id) a factory against a target git repository.
  factory start OWNER/NAME#N [--work-root DIR] [--archive DIR] [--spec FILE] [--keep]
      Clone the repository with gh into a fresh directory under the work root
      (default ${XDG_CACHE_HOME:-$HOME/.cache}/gentle-factory/work), collect, run the
      pipeline (default: the one embedded in this binary; --spec overrides it), copy
      the run's receipts to the archive (default ${XDG_DATA_HOME:-$HOME/.local/share}/
      gentle-factory/runs/<run_id>) and delete the clone unless --keep. An existing
      factory/N on origin is kept, renamed to factory/N-<run_id>, and the run starts
      from a fresh factory/N; it stops before running when an open PR uses factory/N.
      A run is recorded in the status file
      ${XDG_STATE_HOME:-$HOME/.local/state}/gentle-factory/status.json (see README).
      Last line:
      START: status=COMPLETE|STOPPED|NOT_READY|MISCONFIGURED issue=... run=ID archive=DIR
  factory watch --repo OWNER/NAME [--repo ...] [--interval SECONDS] [--slots N] [--max-open-prs N] [--once]
      List open issues labelled factory:ready and start each one like "start" (up to
      --slots per pass, default 1; --interval default 60; also --work-root, --archive,
      --spec). Back-pressure: nothing starts while --max-open-prs (default 3) factory
      draft PRs of that repository await review. A design is started once: the sha256 of its comment is kept in
      <work-root>/watch-state.json and a changed design starts again. Locks keep two
      watchers, or two runs of one issue, apart. --once does a single pass.
      The watcher, its queue and its runs are written to the same status file as "start".
  factory report --runs-dir DIR --run-id ID --context FILE
      Tell the owner how a run ended: post one issue comment (complete with the
      draft PR link, needs_decision with the question, or stopped with the
      reason; idempotent through a hidden marker), swap labels (needs_decision:
      factory:ready -> factory:needs-decision; otherwise drop factory:ready) and
      pipe a short message to $FACTORY_NOTIFY_CMD when set. Never posts receipts,
      logs, commands or absolute paths. Exit 2 on missing receipts or context.
  factory summary [--repo REPO] [--runs-dir DIR] [--json]
      Which node fails, retries or costs the most across runs.
  factory status [--json]
      Print the status file written by start and watch
      (${XDG_STATE_HOME:-$HOME/.local/state}/gentle-factory/status.json) as JSON or as a
      short summary. Never reads receipts. Exit 1 when the file is missing or invalid.
  factory panel [--addr 127.0.0.1:8787] [--runs-dir DIR ...] [--spec FILE] [--allow-remote]
      Serve a read-only web panel and JSON API over receipt stores (repeatable
      --runs-dir, default the archive of "start"): runs with their status, a graph
      of the pipeline (--spec, default the embedded one) with every attempt and
      retry, each attempt's receipt, output, log and feedback, and every run parked
      on an owner decision. Binds loopback only unless --allow-remote, because logs
      and notes hold machine paths. Never writes to a runs dir. First line:
      PANEL: url=http://HOST:PORT/

The receipt store defaults to <repo>/odd/runs. Exit codes: 0 complete,
1 stopped, 2 invalid spec, context, arguments or repository.
`

// Main runs the CLI and returns the process exit code.
func Main(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Fprint(stdout, usage)
		if len(args) == 0 {
			return exitUsage
		}
		return exitOK
	}
	var code int
	var err error
	switch args[0] {
	case "run":
		code, err = cmdRun(args[1:], stdout, stderr)
	case "collect":
		code, err = cmdCollect(args[1:], stdout, stderr)
	case "report":
		code, err = cmdReport(args[1:], stdout, stderr)
	case "start":
		code, err = cmdStart(args[1:], stdout, stderr)
	case "watch":
		code, err = cmdWatch(args[1:], stdout, stderr)
	case "summary":
		code, err = cmdSummary(args[1:], stdout, stderr)
	case "panel":
		code, err = cmdPanel(args[1:], stdout, stderr)
	case "status":
		code, err = cmdStatus(args[1:], stdout, stderr)
	default:
		err = specErr("unknown command %q (want collect, run, start, watch, report, summary, panel or status)", args[0])
	}
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		label := "RUN"
		if args[0] == "start" || args[0] == "watch" || args[0] == "panel" || args[0] == "status" {
			label = strings.ToUpper(args[0])
		}
		fmt.Fprintf(stderr, "%s: status=MISCONFIGURED reason=%s\n", label, strings.Join(strings.Fields(err.Error()), " "))
		return exitUsage
	}
	return code
}

func cmdRun(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var a runArgs
	fs.StringVar(&a.spec, "spec", "", "factory spec JSON")
	fs.StringVar(&a.repo, "repo", "", "target git repository")
	fs.StringVar(&a.context, "context", "", "references JSON: repository, issue, design_comment")
	fs.StringVar(&a.runID, "run-id", "", "resume this run id (default: a new one)")
	fs.StringVar(&a.runsDir, "runs-dir", "", "receipt store (default: <repo>/odd/runs)")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	if a.spec == "" || a.repo == "" || a.context == "" || fs.NArg() > 0 {
		return 0, specErr("run needs --spec, --repo and --context and no positional arguments")
	}
	a.stderr = stderr
	return runFactory(a, stdout)
}

type nodeStats struct {
	Attempts   int     `json:"attempts"`
	Failures   int     `json:"failures"`
	Decisions  int     `json:"decisions"`
	Retries    int     `json:"retries"`
	CostUSD    float64 `json:"cost_usd"`
	DurationMS int64   `json:"duration_ms"`
}

// add counts one receipt: the numbers `summary` and the panel report.
func (s *nodeStats) add(r *Predicate) {
	s.Attempts++
	switch r.Outcome.Status {
	case "failure", "misconfigured":
		s.Failures++
	case "needs_decision":
		s.Decisions++
	}
	if r.Step.Attempt > 1 {
		s.Retries++
	}
	if r.Telemetry.TotalCostUSD != nil {
		s.CostUSD += *r.Telemetry.TotalCostUSD
	}
	s.DurationMS += r.Telemetry.DurationMS
}

func cmdSummary(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("summary", flag.ContinueOnError)
	fs.SetOutput(stderr)
	repo := fs.String("repo", ".", "target repository")
	runsDir := fs.String("runs-dir", "", "receipt store (default: <repo>/odd/runs)")
	asJSON := fs.Bool("json", false, "machine-readable output")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	dir := *runsDir
	if dir == "" {
		dir = filepath.Join(*repo, "odd", "runs")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, specErr("no runs directory at %s", dir)
	}
	stats := map[string]*nodeStats{}
	runs := 0
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		receipts, err := readReceipts(filepath.Join(dir, e.Name(), "receipts"))
		if err != nil {
			return 0, err
		}
		if len(receipts) == 0 {
			continue
		}
		runs++
		for _, r := range receipts {
			s := stats[r.Step.NodeID]
			if s == nil {
				s = &nodeStats{}
				stats[r.Step.NodeID] = s
			}
			s.add(r)
		}
	}
	if *asJSON {
		data, _ := json.MarshalIndent(map[string]any{"runs": runs, "nodes": stats}, "", "  ")
		fmt.Fprintln(stdout, string(data))
		return exitOK, nil
	}
	ids := sortedKeys(stats)
	fmt.Fprintf(stdout, "RUNS: %d\n", runs)
	fmt.Fprintf(stdout, "%-20s %8s %8s %9s %7s %9s %11s\n", "node", "attempts", "failures", "decisions", "retries", "cost_usd", "duration_ms")
	for _, id := range ids {
		s := stats[id]
		fmt.Fprintf(stdout, "%-20s %8d %8d %9d %7d %9.4f %11d\n", id, s.Attempts, s.Failures, s.Decisions, s.Retries, s.CostUSD, s.DurationMS)
	}
	most := func(value func(*nodeStats) float64) string {
		best := ""
		for _, id := range ids { // sorted, so ties go to the first id
			if value(stats[id]) > 0 && (best == "" || value(stats[id]) > value(stats[best])) {
				best = id
			}
		}
		if best == "" {
			return "-"
		}
		return best
	}
	fmt.Fprintf(stdout, "MOST: failures=%s retries=%s cost=%s\n",
		most(func(s *nodeStats) float64 { return float64(s.Failures) }),
		most(func(s *nodeStats) float64 { return float64(s.Retries) }),
		most(func(s *nodeStats) float64 { return s.CostUSD }))
	return exitOK, nil
}
