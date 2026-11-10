package runner

import (
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FullFran/gentle-factory/pipeline"
)

//go:embed panel
var panelFiles embed.FS

// maxPanelText bounds how much of one output, log or feedback file the API returns.
const maxPanelText = 1 << 20

type stringList []string

func (l *stringList) String() string     { return strings.Join(*l, ",") }
func (l *stringList) Set(v string) error { *l = append(*l, v); return nil }

type panelOpts struct {
	addr        string
	runsDirs    stringList
	spec        string
	allowRemote bool
}

func cmdPanel(args []string, stdout, stderr io.Writer) (int, error) {
	fs := flag.NewFlagSet("panel", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var o panelOpts
	fs.StringVar(&o.addr, "addr", "127.0.0.1:8787", "listen address (loopback unless --allow-remote)")
	fs.Var(&o.runsDirs, "runs-dir", "receipt store to show (repeatable; default: the archive)")
	fs.StringVar(&o.spec, "spec", "", "factory spec JSON the graph follows (default: the embedded pipeline)")
	fs.BoolVar(&o.allowRemote, "allow-remote", false, "allow a non-loopback listen address")
	if err := fs.Parse(args); err != nil {
		return 0, err
	}
	if fs.NArg() > 0 {
		return 0, specErr("panel takes no positional arguments")
	}
	if err := checkLoopback(o.addr, o.allowRemote); err != nil {
		return 0, err
	}
	if len(o.runsDirs) == 0 {
		dir, err := xdgDir("XDG_DATA_HOME", filepath.Join(".local", "share"))
		if err != nil {
			return 0, err
		}
		o.runsDirs = stringList{filepath.Join(dir, "gentle-factory", "runs")}
	}
	for i, d := range o.runsDirs {
		abs, err := filepath.Abs(d)
		if err != nil {
			return 0, err
		}
		if st, err := os.Stat(abs); err != nil || !st.IsDir() {
			return 0, specErr("no runs directory at %s", abs)
		}
		o.runsDirs[i] = abs
	}
	spec, err := panelSpec(o.spec)
	if err != nil {
		return 0, err
	}
	ln, err := net.Listen("tcp", o.addr)
	if err != nil {
		return 0, specErr("cannot listen on %s: %v", o.addr, err)
	}
	fmt.Fprintf(stdout, "PANEL: url=http://%s/ runs_dirs=%s\n", ln.Addr(), strings.Join(o.runsDirs, ","))
	p := &panel{spec: spec, runsDirs: o.runsDirs, now: time.Now}
	srv := &http.Server{Handler: p.routes(), ReadHeaderTimeout: 10 * time.Second}
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return 0, err
	}
	return exitOK, nil
}

// checkLoopback refuses any address that is not loopback: logs and notes hold machine paths.
func checkLoopback(addr string, allowRemote bool) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return specErr("invalid --addr %q: %v", addr, err)
	}
	if allowRemote {
		return nil
	}
	if host == "localhost" {
		return nil
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return nil
	}
	return specErr("refusing to serve on %q: it is not a loopback address and logs and notes hold machine paths; "+
		"bind 127.0.0.1 or pass --allow-remote", addr)
}

// panelSpec loads the spec the graph follows; the default is the pipeline embedded in the binary.
func panelSpec(path string) (*Spec, error) {
	if path != "" {
		return loadSpec(path)
	}
	dir, err := os.MkdirTemp("", "factory-panel-spec-")
	if err != nil {
		return nil, specErr("cannot materialize the embedded pipeline: %v", err)
	}
	defer os.RemoveAll(dir)
	specPath, err := pipeline.Materialize(dir)
	if err != nil {
		return nil, specErr("%v", err)
	}
	return loadSpec(specPath)
}

type panel struct {
	spec     *Spec
	runsDirs []string
	now      func() time.Time
}

// runView is one run as the panel shows it, derived from its receipts only.
type runView struct {
	Path           string    `json:"path"`
	RunsDir        string    `json:"runs_dir"`
	RunID          string    `json:"run_id"`
	Repository     string    `json:"repository"`
	Issue          *IssueRef `json:"issue"`
	Status         string    `json:"status"`
	Node           string    `json:"node"`
	TerminalReason string    `json:"terminal_reason"`
	Reason         string    `json:"reason"`
	Attempts       int       `json:"attempts"`
	CostUSD        float64   `json:"cost_usd"`
	DurationMS     int64     `json:"duration_ms"`
	UpdatedAt      time.Time `json:"updated_at"`
	Silent         bool      `json:"silent"`
	PRURL          string    `json:"pr_url"`
	BaseCommit     string    `json:"base_commit"`
	HeadCommit     string    `json:"head_commit"`
	Error          string    `json:"error,omitempty"`
}

type loadedRun struct {
	view     *runView
	receipts []*Predicate
	dir      string
}

func (p *panel) nodeByID() map[string]*Node {
	byID := map[string]*Node{}
	for _, n := range p.spec.Nodes {
		byID[n.ID] = n
	}
	return byID
}

// runState mirrors the runner's stop rules on the receipts alone: a run with no terminal
// state yet is running.
func (p *panel) runState(receipts []*Predicate) (status, terminal, reason string) {
	if len(receipts) == 0 {
		return "running", "", ""
	}
	last := receipts[len(receipts)-1]
	switch last.Outcome.Status {
	case "needs_decision":
		return "needs_decision", last.Outcome.TerminalReason, reasonOf(last)
	case "success":
		if last.Step.NodeID == p.spec.Nodes[len(p.spec.Nodes)-1].ID {
			return "complete", "", ""
		}
		return "running", "", ""
	}
	terminal, reason = last.Outcome.TerminalReason, reasonOf(last)
	node := p.nodeByID()[last.Step.NodeID]
	if last.Outcome.Status != "failure" || node == nil || node.Retry == "" || guardReasons[terminal] {
		return "stopped", terminal, reason
	}
	mine := receiptsOf(receipts, node.ID)
	if n := len(mine); n > 1 && mine[n-2].Outcome.Status == "failure" && mine[n-2].FailureSignature == last.FailureSignature {
		return "stopped", "same_failure_signature", reason
	}
	if len(receiptsOf(receipts, node.Retry))-1 >= *p.spec.MaxRetries {
		return "stopped", "retries_exhausted", reason
	}
	return "running", "", reason
}

// longestTimeout is how long a node may legitimately run without writing anything.
func (p *panel) longestTimeout() time.Duration {
	longest := 0
	for _, n := range p.spec.Nodes {
		def := 600
		if n.Kind == "agent" {
			def = 1800
		}
		if t := n.timeout(def); t > longest {
			longest = t
		}
	}
	return time.Duration(longest) * time.Second
}

func (p *panel) loadRun(index int, runID string) (*loadedRun, error) {
	runsDir := p.runsDirs[index]
	dir := filepath.Join(runsDir, runID)
	v := &runView{Path: fmt.Sprintf("%d/%s", index, runID), RunsDir: runsDir, RunID: runID}
	lr := &loadedRun{view: v, dir: dir}
	v.UpdatedAt = latestChange(dir)
	receipts, err := readReceipts(filepath.Join(dir, "receipts"))
	if err != nil {
		v.Status, v.Error = "unreadable", err.Error()
		return lr, nil
	}
	lr.receipts = receipts
	v.Attempts = len(receipts)
	for _, r := range receipts {
		if r.Telemetry.TotalCostUSD != nil {
			v.CostUSD += *r.Telemetry.TotalCostUSD
		}
		v.DurationMS += r.Telemetry.DurationMS
		if r.References.Repository != "" {
			v.Repository = r.References.Repository
		}
		if r.References.Issue != nil {
			v.Issue = r.References.Issue
		}
		if v.BaseCommit == "" {
			v.BaseCommit = r.References.VCS.BaseCommit
		}
		if r.References.VCS.HeadCommit != "" {
			v.HeadCommit = r.References.VCS.HeadCommit
		}
	}
	if len(receipts) > 0 {
		v.Node = receipts[len(receipts)-1].Step.NodeID
	}
	v.Status, v.TerminalReason, v.Reason = p.runState(receipts)
	v.Silent = v.Status == "running" && p.now().Sub(v.UpdatedAt) > p.longestTimeout()+5*time.Minute
	v.PRURL = findPR(filepath.Join(dir, "logs"))
	return lr, nil
}

// latestChange is the newest modification time of the run directory and its artifacts.
func latestChange(dir string) time.Time {
	var latest time.Time
	for _, sub := range []string{"", "receipts", "logs", "outputs", "feedback"} {
		d := filepath.Join(dir, sub)
		if st, err := os.Stat(d); err == nil && st.ModTime().After(latest) {
			latest = st.ModTime()
		}
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			if info, err := e.Info(); err == nil && info.ModTime().After(latest) {
				latest = info.ModTime()
			}
		}
	}
	return latest
}

func (p *panel) loadAll() []*loadedRun {
	out := []*loadedRun{}
	for i, runsDir := range p.runsDirs {
		entries, _ := os.ReadDir(runsDir)
		for _, e := range entries {
			if !e.IsDir() || !runIDRe.MatchString(e.Name()) {
				continue
			}
			if lr, err := p.loadRun(i, e.Name()); err == nil {
				out = append(out, lr)
			}
		}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].view.UpdatedAt.After(out[b].view.UpdatedAt) })
	return out
}

type panelTotals struct {
	Runs int `json:"runs"`
	nodeStats
}

func totalsOf(runs []*loadedRun) (panelTotals, map[string]*nodeStats) {
	t := panelTotals{}
	nodes := map[string]*nodeStats{}
	for _, lr := range runs {
		t.Runs++
		for _, r := range lr.receipts {
			t.add(r)
			s := nodes[r.Step.NodeID]
			if s == nil {
				s = &nodeStats{}
				nodes[r.Step.NodeID] = s
			}
			s.add(r)
		}
	}
	return t, nodes
}

func (p *panel) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/runs", p.handleRuns)
	mux.HandleFunc("GET /api/runs/{dir}/{run}", p.handleRun)
	mux.HandleFunc("GET /api/runs/{dir}/{run}/attempts/{node}/{attempt}", p.handleAttempt)
	mux.HandleFunc("GET /api/decisions", p.handleDecisions)
	static, _ := fs.Sub(panelFiles, "panel")
	mux.Handle("GET /", http.FileServerFS(static))
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func (p *panel) handleRuns(w http.ResponseWriter, _ *http.Request) {
	runs := p.loadAll()
	views := make([]*runView, 0, len(runs))
	for _, lr := range runs {
		views = append(views, lr.view)
	}
	totals, nodes := totalsOf(runs)
	writeJSON(w, map[string]any{"runs": views, "totals": totals, "nodes": nodes, "runs_dirs": p.runsDirs,
		"factory": p.spec.Factory, "generated_at": p.now()})
}

// lookup resolves {dir}/{run} to a run, or writes 404.
func (p *panel) lookup(w http.ResponseWriter, r *http.Request) *loadedRun {
	index, err := strconv.Atoi(r.PathValue("dir"))
	runID := r.PathValue("run")
	if err != nil || index < 0 || index >= len(p.runsDirs) || !runIDRe.MatchString(runID) {
		http.NotFound(w, r)
		return nil
	}
	if st, err := os.Stat(filepath.Join(p.runsDirs[index], runID)); err != nil || !st.IsDir() {
		http.NotFound(w, r)
		return nil
	}
	lr, err := p.loadRun(index, runID)
	if err != nil {
		http.NotFound(w, r)
		return nil
	}
	return lr
}

type graphAttempt struct {
	Seq            int      `json:"seq"`
	Attempt        int      `json:"attempt"`
	Status         string   `json:"status"`
	TerminalReason string   `json:"terminal_reason"`
	CostUSD        *float64 `json:"cost_usd"`
	DurationMS     int64    `json:"duration_ms"`
}

type graphNode struct {
	ID       string         `json:"id"`
	Kind     string         `json:"kind"`
	Role     string         `json:"role"`
	Retry    string         `json:"retry,omitempty"`
	InSpec   bool           `json:"in_spec"`
	Attempts []graphAttempt `json:"attempts"`
}

type graphEdge struct {
	From  string `json:"from"`
	To    string `json:"to"`
	Kind  string `json:"kind"` // next or retry
	Taken int    `json:"taken"`
}

type graph struct {
	Nodes   []*graphNode `json:"nodes"`
	Edges   []graphEdge  `json:"edges"`
	Current string       `json:"current"`
}

// buildGraph lays the receipts over the spec: one node per spec node with its attempts,
// forward edges in spec order, and retry edges counting how often a checker sent work back.
func (p *panel) buildGraph(receipts []*Predicate) graph {
	g := graph{}
	byID := map[string]*graphNode{}
	for _, n := range p.spec.Nodes {
		gn := &graphNode{ID: n.ID, Kind: n.Kind, Role: n.Role, Retry: n.Retry, InSpec: true, Attempts: []graphAttempt{}}
		byID[n.ID] = gn
		g.Nodes = append(g.Nodes, gn)
	}
	for i, r := range receipts {
		gn := byID[r.Step.NodeID]
		if gn == nil { // a receipt from a node this spec does not have
			gn = &graphNode{ID: r.Step.NodeID, Kind: r.Step.NodeKind, Attempts: []graphAttempt{}}
			byID[gn.ID] = gn
			g.Nodes = append(g.Nodes, gn)
		}
		gn.Attempts = append(gn.Attempts, graphAttempt{Seq: i + 1, Attempt: r.Step.Attempt, Status: r.Outcome.Status,
			TerminalReason: r.Outcome.TerminalReason, CostUSD: r.Telemetry.TotalCostUSD, DurationMS: r.Telemetry.DurationMS})
	}
	taken := map[string]int{}
	for i := 0; i+1 < len(receipts); i++ {
		r, next := receipts[i], receipts[i+1]
		if gn := byID[r.Step.NodeID]; gn != nil && r.Outcome.Status == "failure" && gn.Retry != "" && gn.Retry == next.Step.NodeID {
			taken[r.Step.NodeID]++
		}
	}
	for i, n := range p.spec.Nodes {
		if i+1 < len(p.spec.Nodes) {
			g.Edges = append(g.Edges, graphEdge{From: n.ID, To: p.spec.Nodes[i+1].ID, Kind: "next"})
		}
	}
	for _, n := range p.spec.Nodes {
		if n.Retry != "" {
			g.Edges = append(g.Edges, graphEdge{From: n.ID, To: n.Retry, Kind: "retry", Taken: taken[n.ID]})
		}
	}
	if len(receipts) > 0 {
		g.Current = receipts[len(receipts)-1].Step.NodeID
	}
	return g
}

func (p *panel) handleRun(w http.ResponseWriter, r *http.Request) {
	lr := p.lookup(w, r)
	if lr == nil {
		return
	}
	nodes := map[string]*nodeStats{}
	for _, rc := range lr.receipts {
		s := nodes[rc.Step.NodeID]
		if s == nil {
			s = &nodeStats{}
			nodes[rc.Step.NodeID] = s
		}
		s.add(rc)
	}
	totals, _ := totalsOf([]*loadedRun{lr})
	writeJSON(w, map[string]any{"run": lr.view, "graph": p.buildGraph(lr.receipts), "nodes": nodes, "totals": totals})
}

// readPanelText returns a bounded copy of a run artifact; a missing file is empty.
func readPanelText(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	data, _ := io.ReadAll(io.LimitReader(f, maxPanelText+1))
	if len(data) > maxPanelText {
		return strings.ToValidUTF8(string(data[:maxPanelText]), "") + "\n[... truncated by the panel]", true
	}
	return strings.ToValidUTF8(string(data), "�"), true
}

type sentBack struct {
	Node    string `json:"node"`
	Attempt int    `json:"attempt"`
	Reason  string `json:"reason"`
}

func (p *panel) handleAttempt(w http.ResponseWriter, r *http.Request) {
	lr := p.lookup(w, r)
	if lr == nil {
		return
	}
	node := r.PathValue("node")
	attempt, err := strconv.Atoi(r.PathValue("attempt"))
	if !nodeIDRe.MatchString(node) || err != nil || attempt < 1 {
		http.NotFound(w, r)
		return
	}
	index := -1
	for i, rc := range lr.receipts {
		if rc.Step.NodeID == node && rc.Step.Attempt == attempt {
			index = i
		}
	}
	if index < 0 {
		http.NotFound(w, r)
		return
	}
	receipt := lr.receipts[index]
	resp := map[string]any{"receipt": receipt, "reason": reasonOf(receipt), "seq": index + 1}
	// What sent this attempt back: the checker failure right before it.
	if index > 0 {
		prev := lr.receipts[index-1]
		if n := p.nodeByID()[prev.Step.NodeID]; n != nil && prev.Outcome.Status == "failure" && n.Retry == node {
			resp["sent_back_by"] = sentBack{Node: prev.Step.NodeID, Attempt: prev.Step.Attempt, Reason: reasonOf(prev)}
		}
	}
	// The feedback file is overwritten on each retry: it belongs to the latest attempt only.
	mine := receiptsOf(lr.receipts, node)
	if mine[len(mine)-1] == receipt && attempt > 1 {
		if text, ok := readPanelText(filepath.Join(lr.dir, "feedback", node+".txt")); ok {
			resp["feedback"] = text
		}
	}
	if text, ok := readPanelText(filepath.Join(lr.dir, "logs", fmt.Sprintf("%s-%d.log", node, attempt))); ok {
		resp["log"] = text
	}
	// outputs/<node>.md holds the answer of the node's last successful agent attempt.
	if text, ok := readPanelText(filepath.Join(lr.dir, "outputs", node+".md")); ok {
		resp["output"] = text
		resp["output_note"] = "the answer of this node's last successful attempt"
	}
	writeJSON(w, resp)
}

type decisionView struct {
	Path       string    `json:"path"`
	RunID      string    `json:"run_id"`
	Repository string    `json:"repository"`
	Issue      *IssueRef `json:"issue"`
	Node       string    `json:"node"`
	Question   string    `json:"question"`
	UpdatedAt  time.Time `json:"updated_at"`
	AgeSeconds int64     `json:"age_seconds"`
}

func (p *panel) handleDecisions(w http.ResponseWriter, _ *http.Request) {
	out := []decisionView{}
	for _, lr := range p.loadAll() {
		v := lr.view
		if v.Status != "needs_decision" {
			continue
		}
		age := int64(p.now().Sub(v.UpdatedAt).Seconds())
		if age < 0 {
			age = 0
		}
		out = append(out, decisionView{Path: v.Path, RunID: v.RunID, Repository: v.Repository, Issue: v.Issue,
			Node: v.Node, Question: v.Reason, UpdatedAt: v.UpdatedAt, AgeSeconds: age})
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].AgeSeconds > out[b].AgeSeconds })
	writeJSON(w, map[string]any{"decisions": out})
}
