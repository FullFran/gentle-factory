package runner

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	needsDecisionLabel = "factory:needs-decision"
	maxQuoted          = 1500
)

var (
	// An absolute or home-relative path: a slash-separated path at a word start, never part of a URL.
	absPathRe = regexp.MustCompile(`(^|[\s"'(=:\[<` + "`" + `])(~|)(/[\w.@+-]+)+/?`)
	prURLRe   = regexp.MustCompile(`^PR:\s*(https://\S+)\s*$`)
)

// scrubPaths replaces machine paths so text can be posted on a public issue.
func scrubPaths(s string) string {
	return absPathRe.ReplaceAllString(s, "${1}<path>")
}

// quoteText bounds and scrubs free text taken from a receipt.
func quoteText(s string) string {
	s = strings.TrimSpace(scrubPaths(s))
	if len(s) > maxQuoted {
		s = strings.ToValidUTF8(s[:maxQuoted], "") + "..."
	}
	return s
}

// runReport is what the comment, labels and notification are built from. It never holds
// receipts, logs, commands or paths.
type runReport struct {
	runID, state, node, terminalReason, reason, prURL string
	attempts                                          int
	costUSD                                           float64
}

func (r *runReport) marker() string {
	return fmt.Sprintf("<!-- factory-report:v1 run=%s state=%s -->", r.runID, r.state)
}

func (r *runReport) body() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n**Factory run `%s`: %s**\n\n", r.marker(), r.runID, r.state)
	if r.node != "" {
		fmt.Fprintf(&b, "- Node: `%s`\n", r.node)
	}
	if r.state == "stopped" {
		fmt.Fprintf(&b, "- Terminal reason: `%s`\n", r.terminalReason)
	}
	if r.prURL != "" {
		fmt.Fprintf(&b, "- Draft PR: %s\n", r.prURL)
	}
	fmt.Fprintf(&b, "- Attempts: %d\n- Cost (list price): $%.2f\n", r.attempts, r.costUSD)
	switch r.state {
	case "needs_decision":
		fmt.Fprintf(&b, "\nQuestion:\n\n%s\n\nTo answer: edit the design comment and put the `factory:ready` label back; "+
			"the watcher starts a new run.\n", blockquote(r.reason))
	case "stopped":
		fmt.Fprintf(&b, "\nReason:\n\n%s\n\nTo retry: fix the cause in the design comment and put the `factory:ready` label back.\n",
			blockquote(r.reason))
	}
	return b.String()
}

func blockquote(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = "> " + l
	}
	return strings.Join(lines, "\n")
}

func (r *runReport) message(repo string, issue int) string {
	msg := fmt.Sprintf("factory: %s#%d run %s %s", repo, issue, r.runID, r.state)
	if r.node != "" {
		msg += " at " + r.node
	}
	switch {
	case r.state == "complete" && r.prURL != "":
		msg += ": " + r.prURL
	case r.reason != "":
		msg += ": " + strings.Join(strings.Fields(r.reason), " ")
	}
	return msg
}

// deriveReport reads the run's terminal state from its receipts: the last receipt decides.
func deriveReport(runsDir, runID string) (*runReport, error) {
	if !runIDRe.MatchString(runID) {
		return nil, specErr("invalid --run-id %q", runID)
	}
	receipts, err := readReceipts(filepath.Join(runsDir, runID, "receipts"))
	if err != nil {
		return nil, specErr("cannot read receipts: %v", err)
	}
	if len(receipts) == 0 {
		return nil, specErr("no receipts for run %s in %s", runID, filepath.Base(runsDir))
	}
	last := receipts[len(receipts)-1]
	r := &runReport{runID: runID, attempts: len(receipts), node: last.Step.NodeID}
	for _, p := range receipts {
		if p.Telemetry.TotalCostUSD != nil {
			r.costUSD += *p.Telemetry.TotalCostUSD
		}
	}
	switch last.Outcome.Status {
	case "success":
		r.state = "complete"
	case "needs_decision":
		r.state = "needs_decision"
		r.reason = quoteText(reasonOf(last))
	default:
		r.state = "stopped"
		r.terminalReason = quoteText(last.Outcome.TerminalReason)
		r.reason = quoteText(reasonOf(last))
	}
	r.prURL = findPR(filepath.Join(runsDir, runID, "logs"))
	return r, nil
}

// findPR returns the last `PR: <url>` line of the output node's logs, if any.
func findPR(logsDir string) string {
	logs, _ := filepath.Glob(filepath.Join(logsDir, "output-*.log"))
	url := ""
	for _, path := range logs { // Glob returns them sorted
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			if m := prURLRe.FindStringSubmatch(sc.Text()); m != nil {
				url = m[1]
			}
		}
		f.Close()
	}
	return url
}

// alreadyPosted reports whether an issue comment already carries the marker.
func alreadyPosted(repo string, issue int, marker string) (bool, error) {
	raw, err := gh("api", fmt.Sprintf("repos/%s/issues/%d/comments", repo, issue), "--paginate", "--slurp")
	if err != nil {
		return false, err
	}
	var pages [][]struct {
		Body string `json:"body"`
	}
	if err := json.Unmarshal(raw, &pages); err != nil {
		return false, specErr("cannot read comments JSON: %v", err)
	}
	for _, page := range pages {
		for _, c := range page {
			if strings.Contains(c.Body, marker) {
				return true, nil
			}
		}
	}
	return false, nil
}

func postComment(repo string, issue int, body string) error {
	f, err := os.CreateTemp("", "factory-report-*.md")
	if err != nil {
		return specErr("cannot write comment: %v", err)
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(body); err != nil {
		f.Close()
		return specErr("cannot write comment: %v", err)
	}
	if err := f.Close(); err != nil {
		return specErr("cannot write comment: %v", err)
	}
	_, err = gh("issue", "comment", fmt.Sprint(issue), "-R", repo, "--body-file", f.Name())
	return err
}

func updateLabels(repo string, issue int, state string) error {
	args := []string{"issue", "edit", fmt.Sprint(issue), "-R", repo, "--remove-label", readyLabel}
	if state == "needs_decision" {
		if _, err := gh("label", "create", needsDecisionLabel, "-R", repo, "--force",
			"--description", "The factory stopped on a question for the owner"); err != nil {
			return err
		}
		args = append(args, "--add-label", needsDecisionLabel)
	}
	_, err := gh(args...)
	return err
}

// notify runs FACTORY_NOTIFY_CMD once (split on spaces, no shell) with the message on stdin.
func notify(msg string, stderr io.Writer) {
	argv := strings.Fields(os.Getenv("FACTORY_NOTIFY_CMD"))
	if len(argv) == 0 {
		return
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = strings.NewReader(msg + "\n")
	cmd.Stdout, cmd.Stderr = io.Discard, stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(stderr, "REPORT: notify failed: %v\n", err)
	}
}

func cmdReport(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("report", flag.ContinueOnError)
	fs.SetOutput(stderr)
	runsDir := fs.String("runs-dir", "", "receipt store")
	runID := fs.String("run-id", "", "run to report")
	ctxPath := fs.String("context", "", "context.json written by collect")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	code, err := report(*runsDir, *runID, *ctxPath, fs.NArg(), stdout, stderr)
	if err != nil {
		fmt.Fprintf(stderr, "REPORT: status=MISCONFIGURED reason=%s\n", strings.Join(strings.Fields(err.Error()), " "))
		return exitUsage, nil
	}
	return code, nil
}

func report(runsDir, runID, ctxPath string, positional int, stdout, stderr io.Writer) (int, error) {
	if runsDir == "" || runID == "" || ctxPath == "" || positional > 0 {
		return 0, specErr("report needs --runs-dir, --run-id and --context and no positional arguments")
	}
	ctx, err := loadContext(ctxPath)
	if err != nil {
		return 0, err
	}
	r, err := deriveReport(runsDir, runID)
	if err != nil {
		return 0, err
	}
	repo, issue := ctx.Repository, ctx.Issue.Number
	status := "already-posted"
	posted, err := alreadyPosted(repo, issue, r.marker())
	if err != nil {
		return 0, err
	}
	if !posted {
		if err := postComment(repo, issue, r.body()); err != nil {
			return 0, err
		}
		if err := updateLabels(repo, issue, r.state); err != nil {
			return 0, err
		}
		notify(r.message(repo, issue), stderr)
		status = "posted"
	}
	fmt.Fprintf(stdout, "REPORT: status=%s state=%s issue=%s#%d\n", status, r.state, repo, issue)
	return exitOK, nil
}
