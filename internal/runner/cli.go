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
  factory run --spec SPEC --repo REPO --context CONTEXT [--run-id ID] [--runs-dir DIR]
      Run (or resume, with --run-id) a factory against a target git repository.
  factory summary [--repo REPO] [--runs-dir DIR] [--json]
      Which node fails, retries or costs the most across runs.

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
	case "summary":
		code, err = cmdSummary(args[1:], stdout, stderr)
	default:
		err = specErr("unknown command %q (want run or summary)", args[0])
	}
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK
		}
		fmt.Fprintf(stderr, "RUN: status=MISCONFIGURED reason=%s\n", strings.Join(strings.Fields(err.Error()), " "))
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
	return runFactory(a, stdout)
}

type nodeStats struct {
	Attempts   int     `json:"attempts"`
	Failures   int     `json:"failures"`
	Retries    int     `json:"retries"`
	CostUSD    float64 `json:"cost_usd"`
	DurationMS int64   `json:"duration_ms"`
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
			s.Attempts++
			if r.Outcome.Status != "success" {
				s.Failures++
			}
			if r.Step.Attempt > 1 {
				s.Retries++
			}
			if r.Telemetry.TotalCostUSD != nil {
				s.CostUSD += *r.Telemetry.TotalCostUSD
			}
			s.DurationMS += r.Telemetry.DurationMS
		}
	}
	if *asJSON {
		data, _ := json.MarshalIndent(map[string]any{"runs": runs, "nodes": stats}, "", "  ")
		fmt.Fprintln(stdout, string(data))
		return exitOK, nil
	}
	ids := sortedKeys(stats)
	fmt.Fprintf(stdout, "RUNS: %d\n", runs)
	fmt.Fprintf(stdout, "%-20s %8s %8s %7s %9s %11s\n", "node", "attempts", "failures", "retries", "cost_usd", "duration_ms")
	for _, id := range ids {
		s := stats[id]
		fmt.Fprintf(stdout, "%-20s %8d %8d %7d %9.4f %11d\n", id, s.Attempts, s.Failures, s.Retries, s.CostUSD, s.DurationMS)
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
