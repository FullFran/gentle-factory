// Package runner runs the nodes of a gentle-factory spec against a target git
// repository and writes one in-toto receipt per node attempt
// (docs/design/receipt-format.md). The next node is computed from the receipts
// (docs/design/node-contract.md section 5), so a stopped or crashed run
// resumes by running the same command again.
package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// SpecError is an invalid spec, context, argument or repository (exit 2).
type SpecError struct{ msg string }

func (e *SpecError) Error() string { return e.msg }

func specErr(format string, args ...any) error { return &SpecError{fmt.Sprintf(format, args...)} }

var (
	defaultProtected = []string{"odd/runs/", ".factory/", "gates/"}
	nodeIDRe         = regexp.MustCompile(`^[a-z0-9_-]+$`)
	runIDRe          = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)
	modelRe          = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._\[\]:-]*$`)
)

// Node is one step of a factory.
type Node struct {
	ID             string   `json:"id"`
	Kind           string   `json:"kind"`
	Engine         string   `json:"engine,omitempty"`
	Role           string   `json:"role,omitempty"`
	PromptFile     string   `json:"prompt_file,omitempty"`
	Model          string   `json:"model,omitempty"`
	Tools          []string `json:"tools,omitempty"`
	Deny           []string `json:"deny,omitempty"`
	ReadOnly       bool     `json:"read_only,omitempty"`
	Retry          string   `json:"retry,omitempty"`
	Inputs         []string `json:"inputs,omitempty"`
	Command        []string `json:"command,omitempty"`
	MaxTurns       *int     `json:"max_turns,omitempty"`
	MaxBudgetUSD   *float64 `json:"max_budget_usd,omitempty"`
	TimeoutSeconds *int     `json:"timeout_seconds,omitempty"`
}

func (n *Node) maxTurns() int {
	if n.MaxTurns != nil {
		return *n.MaxTurns
	}
	return 30
}

func (n *Node) maxBudget() float64 {
	if n.MaxBudgetUSD != nil {
		return *n.MaxBudgetUSD
	}
	return 3.0
}

func (n *Node) timeout(def int) int {
	if n.TimeoutSeconds != nil {
		return *n.TimeoutSeconds
	}
	return def
}

// The design caps (#51) are ceilings: the effective cap is the smaller of the node's cap and
// the design's, so a design can lower a cap but never raise it. A nil context or cap keeps the node's.

func effectiveTurns(n *Node, c *Context) int {
	if c != nil && c.TurnCap != nil {
		return min(n.maxTurns(), *c.TurnCap)
	}
	return n.maxTurns()
}

func effectiveBudget(n *Node, c *Context) float64 {
	if c != nil && c.BudgetCapUSD != nil {
		return min(n.maxBudget(), *c.BudgetCapUSD)
	}
	return n.maxBudget()
}

func effectiveTimeout(n *Node, c *Context, def int) int {
	if c != nil && c.TimeoutSeconds != nil {
		return min(n.timeout(def), *c.TimeoutSeconds)
	}
	return n.timeout(def)
}

// Spec is a factory definition: nodes in order plus run-wide settings.
type Spec struct {
	Factory        string   `json:"factory"`
	MaxRetries     *int     `json:"max_retries,omitempty"`
	ProtectedPaths []string `json:"protected_paths,omitempty"`
	Nodes          []*Node  `json:"nodes"`
	dir            string
}

// Context holds the references every receipt carries; the runner never fetches them.
type Context struct {
	Repository    string         `json:"repository"`
	Issue         *IssueRef      `json:"issue"`
	DesignComment *DesignComment `json:"design_comment"`
	TaskID        string         `json:"task_id,omitempty"`
	// Set by `factory collect` from the design comment (gentle-factory#3).
	DoneWhen      string   `json:"done_when,omitempty"`
	ExpectedFiles []string `json:"expected_files,omitempty"`
	DesignFile    string   `json:"design_file,omitempty"`
	IssueFile     string   `json:"issue_file,omitempty"`
	Slice         bool     `json:"slice"`
	// Design caps (#51): ceilings that lower each node's caps, never raise them.
	BudgetCapUSD   *float64 `json:"budget_cap_usd,omitempty"`
	TurnCap        *int     `json:"turn_cap,omitempty"`
	TimeoutSeconds *int     `json:"timeout_seconds,omitempty"`
	path           string
}

type IssueRef struct {
	Number int    `json:"number"`
	URL    string `json:"url"`
}

type DesignComment struct {
	ID        int64  `json:"id"`
	URL       string `json:"url"`
	SHA256    string `json:"sha256"`
	UpdatedAt string `json:"updated_at"`
}

// decodeStrict rejects unknown fields so a misspelt key (for example
// "readonly") fails loudly instead of silently dropping a guard.
func decodeStrict(path, what string, into any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return specErr("cannot read %s %s: %v", what, path, err)
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(into); err != nil {
		return specErr("cannot read %s %s: %v", what, path, err)
	}
	return nil
}

func loadSpec(path string) (*Spec, error) {
	spec := &Spec{}
	if err := decodeStrict(path, "spec", spec); err != nil {
		return nil, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, specErr("cannot resolve spec path: %v", err)
	}
	spec.dir = filepath.Dir(abs)
	if spec.Factory == "" {
		return nil, specErr("spec.factory must be a non-empty string")
	}
	if len(spec.Nodes) == 0 {
		return nil, specErr("spec.nodes must be a non-empty list")
	}
	if spec.MaxRetries == nil {
		two := 2
		spec.MaxRetries = &two
	} else if *spec.MaxRetries < 0 {
		return nil, specErr("spec.max_retries must be a non-negative integer")
	}
	seen := map[string]*Node{}
	for _, node := range spec.Nodes {
		if node == nil || !nodeIDRe.MatchString(node.ID) {
			return nil, specErr("node ids must match [a-z0-9_-]+")
		}
		if seen[node.ID] != nil {
			return nil, specErr("duplicate node id %s", node.ID)
		}
		switch node.Kind {
		case "code":
			if len(node.Command) == 0 {
				return nil, specErr("code node %s needs a non-empty command list", node.ID)
			}
			if node.Model != "" {
				return nil, specErr("node %s: model is only allowed on agent nodes", node.ID)
			}
		case "agent":
			if node.Engine != "" && node.Engine != "claude" {
				return nil, specErr("agent node %s: only engine 'claude' is supported", node.ID)
			}
			if node.Model != "" && !modelRe.MatchString(node.Model) {
				return nil, specErr("agent node %s: model must match %s", node.ID, modelRe)
			}
			if node.PromptFile == "" {
				return nil, specErr("agent node %s needs prompt_file", node.ID)
			}
			node.PromptFile = filepath.Join(spec.dir, node.PromptFile)
			if st, err := os.Stat(node.PromptFile); err != nil || !st.Mode().IsRegular() {
				return nil, specErr("agent node %s: prompt_file not found", node.ID)
			}
		default:
			return nil, specErr("node %s: kind must be 'code' or 'agent'", node.ID)
		}
		if node.Role == "" {
			if node.Kind == "code" || node.ReadOnly {
				node.Role = "checker"
			} else {
				node.Role = "producer"
			}
		}
		if node.Role != "producer" && node.Role != "checker" {
			return nil, specErr("node %s: role must be producer or checker", node.ID)
		}
		for _, in := range node.Inputs {
			if seen[in] == nil {
				return nil, specErr("node %s: input %q must be an earlier node", node.ID, in)
			}
		}
		if node.Retry != "" {
			target := seen[node.Retry]
			if target == nil {
				return nil, specErr("node %s: retry target %q must be an earlier node", node.ID, node.Retry)
			}
			if target.Role != "producer" {
				return nil, specErr("node %s: retry target %s must be a producer", node.ID, node.Retry)
			}
		}
		seen[node.ID] = node
	}
	if spec.ProtectedPaths == nil {
		spec.ProtectedPaths = defaultProtected
	}
	if spec.ProtectedPaths, err = normalizeProtected(spec.ProtectedPaths); err != nil {
		return nil, err
	}
	return spec, nil
}

func normalizeProtected(entries []string) ([]string, error) {
	out := make([]string, 0, len(entries))
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		for strings.HasPrefix(entry, "./") {
			entry = entry[2:]
		}
		entry = strings.Trim(entry, "/")
		if entry == "" || strings.HasPrefix(entry, "..") || filepath.IsAbs(entry) {
			return nil, specErr("protected path %q must be relative to the repository", entry)
		}
		out = append(out, entry)
	}
	return out, nil
}

func loadContext(path string) (*Context, error) {
	ctx := &Context{}
	if err := decodeStrict(path, "context", ctx); err != nil {
		return nil, err
	}
	if ctx.Repository == "" {
		return nil, specErr("context.repository is required")
	}
	if ctx.Issue == nil {
		return nil, specErr("context.issue is required")
	}
	if ctx.DesignComment == nil {
		return nil, specErr("context.design_comment is required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, specErr("cannot resolve context path: %v", err)
	}
	ctx.path = abs
	for _, f := range []*string{&ctx.DesignFile, &ctx.IssueFile} {
		if *f == "" {
			continue
		}
		if !filepath.IsAbs(*f) {
			*f = filepath.Join(filepath.Dir(abs), *f)
		}
		if st, err := os.Stat(*f); err != nil || !st.Mode().IsRegular() {
			return nil, specErr("context file %s not found", *f)
		}
	}
	for _, entry := range ctx.ExpectedFiles {
		if err := checkExpectedFile(entry); err != nil {
			return nil, specErr("context: %v", err)
		}
	}
	if ctx.TaskID == "" {
		ctx.TaskID = fmt.Sprintf("%s#%d", ctx.Repository, ctx.Issue.Number)
	}
	return ctx, nil
}

var expectedFileBad = regexp.MustCompile(`(^|/)\.\.?(/|$)|//|^(\.factory|\.git|odd/runs|gates)(/|$)`)

// checkExpectedFile applies the design-comment schema rules to one expected_files entry.
func checkExpectedFile(entry string) error {
	if entry == "" || strings.ContainsAny(entry[:1], "/ \t\r\n") || expectedFileBad.MatchString(entry) {
		return fmt.Errorf("expected_files entry %q must be a normalized repository-relative path outside .factory/, .git/, odd/runs/ and gates/", entry)
	}
	return nil
}

// matchExpected reports whether a repository path is covered by an expected_files
// entry: an exact path, a path.Match glob, or a "dir/**" (or "dir/") prefix.
func matchExpected(patterns []string, p string) bool {
	for _, pat := range patterns {
		if pat == p {
			return true
		}
		if prefix, ok := strings.CutSuffix(pat, "/**"); ok && strings.HasPrefix(p, prefix+"/") {
			return true
		}
		if strings.HasSuffix(pat, "/") && strings.HasPrefix(p, pat) {
			return true
		}
		if ok, _ := path.Match(pat, p); ok {
			return true
		}
	}
	return false
}
