package runner

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	statementType  = "https://in-toto.io/Statement/v1"
	predicateType  = "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md"
	receiptVersion = "0.1.0"
)

// Statement is an in-toto Statement v1 wrapping a gentle-factory receipt predicate.
type Statement struct {
	Type          string    `json:"_type"`
	Subject       []Subject `json:"subject"`
	PredicateType string    `json:"predicateType"`
	Predicate     Predicate `json:"predicate"`
}

type Subject struct {
	Name   string            `json:"name"`
	Digest map[string]string `json:"digest"`
}

type Predicate struct {
	Version          string     `json:"version"`
	RunID            string     `json:"run_id"`
	Step             Step       `json:"step"`
	References       References `json:"references"`
	Execution        Execution  `json:"execution"`
	Telemetry        Telemetry  `json:"telemetry"`
	Outcome          Outcome    `json:"outcome"`
	Gate             *Gate      `json:"gate,omitempty"`
	FailureSignature string     `json:"failure_signature,omitempty"`
	Notes            string     `json:"notes,omitempty"`
}

type Step struct {
	NodeID   string `json:"node_id"`
	NodeKind string `json:"node_kind"`
	Attempt  int    `json:"attempt"`
}

type References struct {
	Repository    string         `json:"repository"`
	Issue         *IssueRef      `json:"issue"`
	DesignComment *DesignComment `json:"design_comment"`
	VCS           VCS            `json:"vcs"`
}

type VCS struct {
	BaseCommit string `json:"base_commit,omitempty"`
	HeadCommit string `json:"head_commit,omitempty"`
	Branch     string `json:"branch,omitempty"`
}

type Execution struct {
	Engine        string   `json:"engine"`
	EngineVersion string   `json:"engine_version,omitempty"`
	Command       []string `json:"command,omitempty"`
	ToolsAllowed  []string `json:"tools_allowed"`
	Caps          Caps     `json:"caps"`
}

type Caps struct {
	MaxTurns       *int     `json:"max_turns,omitempty"`
	MaxBudgetUSD   *float64 `json:"max_budget_usd,omitempty"`
	TimeoutSeconds int      `json:"timeout_seconds"`
}

type Telemetry struct {
	TraceID      string   `json:"trace_id,omitempty"`
	SpanID       string   `json:"span_id,omitempty"`
	Traceparent  string   `json:"traceparent,omitempty"`
	GenAISystem  string   `json:"gen_ai_system,omitempty"`
	RequestModel string   `json:"request_model,omitempty"`
	Tokens       *Tokens  `json:"tokens,omitempty"`
	TotalCostUSD *float64 `json:"total_cost_usd,omitempty"`
	NumTurns     *int     `json:"num_turns,omitempty"`
	DurationMS   int64    `json:"duration_ms"`
}

type Tokens struct {
	InputTokens              int64 `json:"input_tokens"`
	CacheReadInputTokens     int64 `json:"cache_read_input_tokens,omitempty"`
	CacheCreationInputTokens int64 `json:"cache_creation_input_tokens,omitempty"`
	OutputTokens             int64 `json:"output_tokens"`
	TotalTokens              int64 `json:"total_tokens"`
}

type Outcome struct {
	Status         string `json:"status"`
	TerminalReason string `json:"terminal_reason"`
	ExitCode       *int   `json:"exit_code,omitempty"`
}

type Gate struct {
	Status       string   `json:"status"`
	VerdictLine  string   `json:"verdict_line"`
	ChecksPassed []string `json:"checks_passed"`
	ChecksFailed []string `json:"checks_failed"`
}

// failureSignature hashes the failed check names, or the normalized reason.
func failureSignature(res *result) string {
	if res.gate != nil && len(res.gate.ChecksFailed) > 0 {
		return sha256Text("checks:" + strings.Join(res.gate.ChecksFailed, ","))
	}
	reason := res.reason
	if reason == "" {
		reason = res.terminalReason
	}
	return sha256Text("reason:" + strings.Join(strings.Fields(reason), " "))
}

func buildReceipt(rc *runCtx, node *Node, attempt int, res *result, head string) *Statement {
	p := Predicate{
		Version: receiptVersion,
		RunID:   rc.runID,
		Step:    Step{NodeID: node.ID, NodeKind: node.Kind, Attempt: attempt},
		References: References{
			Repository:    rc.context.Repository,
			Issue:         rc.context.Issue,
			DesignComment: rc.context.DesignComment,
			VCS:           VCS{BaseCommit: rc.baseCommit, HeadCommit: head, Branch: rc.branch},
		},
		Execution: Execution{Engine: res.engine, EngineVersion: res.engineVersion, Command: res.command,
			ToolsAllowed: res.tools, Caps: res.caps},
		Telemetry: res.telemetry,
		Outcome:   Outcome{Status: res.status, TerminalReason: res.terminalReason},
		Gate:      res.gate,
	}
	p.Telemetry.TraceID = rc.traceID
	p.Telemetry.SpanID = res.spanID
	p.Telemetry.Traceparent = fmt.Sprintf("00-%s-%s-01", rc.traceID, res.spanID)
	p.Telemetry.DurationMS = res.durationMS
	if res.status != "success" || res.exitCode == 0 {
		code := res.exitCode
		p.Outcome.ExitCode = &code
	}
	if res.status != "success" {
		p.FailureSignature = failureSignature(res)
	}
	notes := res.notes
	if res.reason != "" && res.status != "success" {
		notes = strings.TrimSpace("reason: " + res.reason + "\n" + notes)
	}
	p.Notes = notes
	return &Statement{
		Type:          statementType,
		Subject:       []Subject{{Name: "git:commit", Digest: map[string]string{"gitCommit": head}}},
		PredicateType: predicateType,
		Predicate:     p,
	}
}

// reasonOf recovers the failure reason the runner stored in a receipt's notes.
func reasonOf(p *Predicate) string {
	first, _, _ := strings.Cut(p.Notes, "\n")
	if r, ok := strings.CutPrefix(first, "reason: "); ok {
		return r
	}
	return p.Outcome.TerminalReason
}

// Store is the append-only receipt store: <runs_dir>/<run_id>/{receipts,logs,feedback}.
type Store struct {
	runsDir string
	runDir  string
}

func newStore(runsDir, runID string) (*Store, error) {
	s := &Store{runsDir: runsDir, runDir: filepath.Join(runsDir, runID)}
	for _, sub := range []string{"receipts", "logs", "feedback"} {
		if err := os.MkdirAll(filepath.Join(s.runDir, sub), 0o755); err != nil {
			return nil, specErr("cannot create receipt store: %v", err)
		}
	}
	return s, nil
}

func (s *Store) receipts() ([]*Predicate, error) {
	return readReceipts(filepath.Join(s.runDir, "receipts"))
}

func readReceipts(dir string) ([]*Predicate, error) {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	names := []string{}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	out := make([]*Predicate, 0, len(names))
	for _, name := range names {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		st := &Statement{}
		if err := json.Unmarshal(data, st); err != nil {
			return nil, fmt.Errorf("receipt %s: %w", name, err)
		}
		out = append(out, &st.Predicate)
	}
	return out, nil
}

func (s *Store) append(st *Statement) error {
	dir := filepath.Join(s.runDir, "receipts")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, fmt.Sprintf("%04d-%s-%d.json", len(entries)+1,
		st.Predicate.Step.NodeID, st.Predicate.Step.Attempt))
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *Store) logPath(nodeID string, attempt int) string {
	_ = os.MkdirAll(filepath.Join(s.runDir, "logs"), 0o755)
	return filepath.Join(s.runDir, "logs", fmt.Sprintf("%s-%d.log", nodeID, attempt))
}

func (s *Store) feedbackPath(nodeID string) string {
	_ = os.MkdirAll(filepath.Join(s.runDir, "feedback"), 0o755)
	return filepath.Join(s.runDir, "feedback", nodeID+".txt")
}

// outputPath holds the full final answer of a node's last successful agent attempt,
// read by later nodes that list it in `inputs`.
func (s *Store) outputPath(nodeID string) string {
	_ = os.MkdirAll(filepath.Join(s.runDir, "outputs"), 0o755)
	return filepath.Join(s.runDir, "outputs", nodeID+".md")
}
