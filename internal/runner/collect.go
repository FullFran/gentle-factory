package runner

import (
	"bytes"
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

const readyLabel = "factory:ready"

var designBlockRe = regexp.MustCompile(`(?s)<!--\s*factory-design:v1\s*(.*?)-->`)

// notReady is a collect refusal caused by the issue, not by the caller (exit 1).
type notReady struct{ msg string }

func (e *notReady) Error() string { return e.msg }

func notReadyf(format string, args ...any) error { return &notReady{fmt.Sprintf(format, args...)} }

// Design is the machine-readable block of a design comment (schemas/design-comment.schema.json).
type Design struct {
	SchemaVersion  string   `json:"schema_version"`
	Issue          *int     `json:"issue,omitempty"`
	ReadySignal    string   `json:"ready_signal"`
	DoneWhen       string   `json:"done_when"`
	ExpectedFiles  []string `json:"expected_files"`
	GateLevel      string   `json:"gate_level,omitempty"`
	BudgetCapUSD   *float64 `json:"budget_cap_usd,omitempty"`
	TurnCap        *int     `json:"turn_cap,omitempty"`
	TimeoutSeconds *int     `json:"timeout_seconds,omitempty"`
	Slice          *bool    `json:"slice,omitempty"`
}

func ghBin() string {
	if b := os.Getenv("FACTORY_GH_BIN"); b != "" {
		return b
	}
	return "gh"
}

func gh(args ...string) ([]byte, error) {
	cmd := exec.Command(ghBin(), args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, specErr("gh %s failed: %s", strings.Join(args, " "), strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// parseDesign extracts and validates the factory-design:v1 block of a comment body.
func parseDesign(body string, issue int) (*Design, error) {
	m := designBlockRe.FindStringSubmatch(body)
	if m == nil {
		return nil, notReadyf("no factory-design:v1 block")
	}
	d := &Design{}
	dec := json.NewDecoder(strings.NewReader(m[1]))
	dec.DisallowUnknownFields()
	if err := dec.Decode(d); err != nil {
		if strings.Contains(err.Error(), "unknown field") {
			return nil, notReadyf("design block: %v", err)
		}
		return nil, notReadyf("design block is not valid JSON: %v", err)
	}
	switch {
	case d.SchemaVersion != "1.0":
		return nil, notReadyf("design block: schema_version must be \"1.0\"")
	case d.ReadySignal != readyLabel:
		return nil, notReadyf("design block: ready_signal must be %q", readyLabel)
	case strings.TrimSpace(d.DoneWhen) == "":
		return nil, notReadyf("design block: done_when is required")
	case len(d.ExpectedFiles) == 0:
		return nil, notReadyf("design block: expected_files needs at least one entry")
	case d.Issue != nil && *d.Issue != issue:
		return nil, notReadyf("design is for issue %d, not %d", *d.Issue, issue)
	case d.GateLevel != "" && d.GateLevel != "light" && d.GateLevel != "standard" && d.GateLevel != "full":
		return nil, notReadyf("design block: gate_level must be light, standard or full")
	}
	for _, f := range d.ExpectedFiles {
		if err := checkExpectedFile(f); err != nil {
			return nil, notReadyf("design block: %v", err)
		}
	}
	return d, nil
}

type collectArgs struct {
	repo, checkout, out string
	issue               int
}

// collect is factory#3 step 1: issue, design gate, pinned references and branch.
func collect(a collectArgs, stdout io.Writer) error {
	top, err := git(a.checkout, "rev-parse", "--show-toplevel")
	if err != nil {
		return specErr("%s is not a git repository", a.checkout)
	}
	checkout := strings.TrimSpace(top)
	branch := fmt.Sprintf("factory/%d", a.issue)
	if _, err := git(checkout, "rev-parse", "--verify", "--quiet", "refs/heads/"+branch); err == nil {
		return specErr("branch %s already exists in %s; delete it to collect again", branch, checkout)
	}
	if status, err := git(checkout, "status", "--porcelain"); err != nil || strings.TrimSpace(status) != "" {
		return specErr("checkout %s has uncommitted changes", checkout)
	}

	raw, err := gh("issue", "view", fmt.Sprint(a.issue), "-R", a.repo, "--json", "number,url,title,body,labels")
	if err != nil {
		return err
	}
	var issue struct {
		Number int    `json:"number"`
		URL    string `json:"url"`
		Title  string `json:"title"`
		Body   string `json:"body"`
		Labels []struct {
			Name string `json:"name"`
		} `json:"labels"`
	}
	if err := json.Unmarshal(raw, &issue); err != nil {
		return specErr("cannot read issue JSON: %v", err)
	}
	ready := false
	for _, l := range issue.Labels {
		ready = ready || l.Name == readyLabel
	}
	if !ready {
		return notReadyf("missing label %s", readyLabel)
	}

	latest, err := latestDesignComment(a.repo, a.issue)
	if err != nil {
		return err
	}
	var comment *DesignComment
	var body string
	if latest != nil {
		comment = &DesignComment{ID: latest.ID, URL: latest.URL, SHA256: sha256Text(latest.Body), UpdatedAt: latest.UpdatedAt}
		body = latest.Body
	}
	if comment == nil {
		return notReadyf("no comment with a factory-design:v1 block")
	}
	design, err := parseDesign(body, a.issue)
	if err != nil {
		return err
	}

	if _, err := git(checkout, "fetch", "-q", "origin"); err != nil {
		return err
	}
	base := "origin/main"
	if ref, err := git(checkout, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil {
		base = strings.TrimSpace(ref)
	}
	if _, err := git(checkout, "switch", "-q", "-c", branch, "--no-track", base); err != nil {
		return err
	}
	if err := checkDoneWhenFails(checkout, design.DoneWhen, stdout); err != nil {
		if _, swErr := git(checkout, "switch", "-q", "-"); swErr == nil {
			_, _ = git(checkout, "branch", "-q", "-D", branch)
		}
		return err
	}
	if err := os.MkdirAll(a.out, 0o755); err != nil {
		return err
	}
	ctx := Context{Repository: a.repo, Issue: &IssueRef{Number: issue.Number, URL: issue.URL}, DesignComment: comment,
		DoneWhen: design.DoneWhen, ExpectedFiles: design.ExpectedFiles, DesignFile: "design.md", IssueFile: "issue.md",
		Slice: design.Slice != nil && *design.Slice}
	files := map[string]string{
		"design.md": body,
		"issue.md":  fmt.Sprintf("# %s\n\n%s\n", issue.Title, issue.Body),
	}
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(a.out, name), []byte(text), 0o644); err != nil {
			return err
		}
	}
	data, _ := json.MarshalIndent(ctx, "", "  ")
	contextPath := filepath.Join(a.out, "context.json")
	if err := os.WriteFile(contextPath, append(data, '\n'), 0o644); err != nil {
		return err
	}

	fmt.Fprintf(stdout, "COLLECT: status=READY issue=%s#%d design_comment=%d branch=%s base=%s context=%s\n",
		a.repo, a.issue, comment.ID, branch, base, contextPath)
	return nil
}

func cmdCollect(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("collect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var a collectArgs
	fs.StringVar(&a.repo, "repo", "", "GitHub repository OWNER/NAME")
	fs.IntVar(&a.issue, "issue", 0, "issue number")
	fs.StringVar(&a.checkout, "checkout", "", "local clone of the repository (clean)")
	fs.StringVar(&a.out, "out", "", "directory for context.json, design.md and issue.md")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	if a.repo == "" || a.issue < 1 || a.checkout == "" || a.out == "" || fs.NArg() > 0 {
		return 0, specErr("collect needs --repo, --issue, --checkout and --out and no positional arguments")
	}
	err := collect(a, stdout)
	if nr, ok := err.(*notReady); ok {
		fmt.Fprintf(stdout, "COLLECT: status=NOT_READY reason=%s\n", strings.Join(strings.Fields(nr.msg), " "))
		return exitStopped, nil
	}
	if err != nil {
		return 0, err
	}
	return exitOK, nil
}

// doneWhenTimeout bounds the pre-run check of the design's done_when.
const doneWhenTimeout = 600

// checkDoneWhenFails runs the design's done_when at the base: it must fail, or it proves
// nothing about the change. The checkout is restored afterwards.
func checkDoneWhenFails(checkout, doneWhen string, stdout io.Writer) error {
	code, _, _, timedOut := runProcess([]string{"bash", "-c", doneWhen}, checkout, os.Environ(), "", doneWhenTimeout)
	if _, err := git(checkout, "checkout", "-q", "--", "."); err != nil {
		return err
	}
	if _, err := git(checkout, "clean", "-q", "-f", "-d"); err != nil {
		return err
	}
	switch {
	case timedOut:
		return notReadyf("done_when timed out after %ds before any change", doneWhenTimeout)
	case code == 0:
		return notReadyf("done_when already passes before any change, so it cannot prove the issue done")
	case code == 126 || code == 127:
		return notReadyf("done_when cannot run (exit %d)", code)
	}
	fmt.Fprintf(stdout, "COLLECT: check=done_when status=RED exit=%d\n", code)
	return nil
}

// issueComment is the part of a GitHub issue comment the factory reads.
type issueComment struct {
	ID        int64  `json:"id"`
	URL       string `json:"html_url"`
	UpdatedAt string `json:"updated_at"`
	Body      string `json:"body"`
}

// latestDesignComment returns the issue's latest comment holding a factory-design:v1
// block (the latest one wins), or nil when there is none.
func latestDesignComment(repo string, issue int) (*issueComment, error) {
	raw, err := gh("api", fmt.Sprintf("repos/%s/issues/%d/comments", repo, issue), "--paginate", "--slurp")
	if err != nil {
		return nil, err
	}
	var pages [][]issueComment
	if err := json.Unmarshal(raw, &pages); err != nil {
		return nil, specErr("cannot read comments JSON: %v", err)
	}
	var latest *issueComment
	for _, page := range pages {
		for i := range page {
			if designBlockRe.MatchString(page[i].Body) {
				latest = &page[i]
			}
		}
	}
	return latest, nil
}
