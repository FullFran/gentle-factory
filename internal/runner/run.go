package runner

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	exitOK      = 0
	exitStopped = 1
	exitUsage   = 2
)

// A guard trip is final: retrying would let the next producer commit the violation.
var guardReasons = map[string]bool{"read_only_modified": true, "protected_path_modified": true,
	"unexpected_path_modified": true}

// runCtx is the state shared by every node of one run.
type runCtx struct {
	factory, runID, repo, specDir, baseCommit, branch string
	traceID, traceparent, engineVersion               string
	context                                           *Context
	protected                                         []string
	store                                             *Store
	out                                               io.Writer
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func newRunID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("run_%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func isCurrent(r *Predicate, node *Node, head string) bool {
	if r.Outcome.Status != "success" {
		return false
	}
	return node.Role == "producer" || r.References.VCS.HeadCommit == head
}

// nextNode is the first node without a current success receipt (node contract 5.1).
func nextNode(nodes []*Node, receipts []*Predicate, head string) *Node {
	for _, node := range nodes {
		current := false
		for _, r := range receipts {
			if r.Step.NodeID == node.ID && isCurrent(r, node, head) {
				current = true
				break
			}
		}
		if !current {
			return node
		}
	}
	return nil
}

func receiptsOf(receipts []*Predicate, nodeID string) []*Predicate {
	out := []*Predicate{}
	for _, r := range receipts {
		if r.Step.NodeID == nodeID {
			out = append(out, r)
		}
	}
	return out
}

// execute runs one attempt of node, applies the guards and writes its receipt.
func execute(rc *runCtx, node *Node, receipts []*Predicate, feedback string) (*Predicate, *result, error) {
	attempt := len(receiptsOf(receipts, node.ID)) + 1
	feedbackFile := ""
	if feedback != "" {
		feedbackFile = rc.store.feedbackPath(node.ID)
		if err := os.WriteFile(feedbackFile, []byte(feedback+"\n"), 0o644); err != nil {
			return nil, nil, err
		}
	}
	before, err := repoState(rc.repo)
	if err != nil {
		return nil, nil, err
	}
	headBefore, err := headCommit(rc.repo)
	if err != nil {
		return nil, nil, err
	}
	upstream := [][2]string{}
	for _, in := range node.Inputs {
		data, err := os.ReadFile(rc.store.outputPath(in))
		if err != nil {
			return nil, nil, specErr("node %s: no output of input %s yet", node.ID, in)
		}
		upstream = append(upstream, [2]string{in, string(data)})
	}
	protectedBefore := pathDigests(rc.repo, rc.protected)
	storeBefore := pathDigests(rc.store.runsDir, []string{"."})
	fmt.Fprintf(rc.out, "NODE: id=%s attempt=%d kind=%s\n", node.ID, attempt, node.Kind)

	var res *result
	if node.Kind == "agent" {
		res = runAgent(rc, node, attempt, feedback, feedbackFile, upstream)
		if rc.engineVersion == "" {
			rc.engineVersion = engineVersion(res.command[0])
		}
		res.engineVersion = rc.engineVersion
	} else {
		res = runCode(rc, node, attempt, feedbackFile)
	}
	res.spanID = randomHex(8)

	// Guards run before the receipt is written (node contract 4.2).
	if node.ReadOnly {
		after, err := repoState(rc.repo)
		if err != nil {
			return nil, nil, err
		}
		if after != before {
			res.fail("failure", "read_only_modified", "read-only step changed the target repository (git status/HEAD differ)")
		}
	}
	if node.Kind == "agent" {
		hits := changedEntries(protectedBefore, pathDigests(rc.repo, rc.protected))
		if len(changedEntries(storeBefore, pathDigests(rc.store.runsDir, []string{"."}))) > 0 {
			rel, _ := filepath.Rel(rc.repo, rc.store.runsDir)
			hits = append(hits, strings.TrimSuffix(filepath.ToSlash(rel), "/")+"/")
		}
		if len(hits) > 0 {
			res.fail("failure", "protected_path_modified", "protected paths changed: "+strings.Join(hits, ", "))
		}
	}
	if node.Kind == "agent" && node.Role == "producer" && len(rc.context.ExpectedFiles) > 0 && res.status == "success" {
		outside, err := unexpectedPaths(rc.repo, headBefore, rc.context.ExpectedFiles)
		if err != nil {
			return nil, nil, err
		}
		if len(outside) > 0 {
			res.fail("failure", "unexpected_path_modified", "paths outside the design's expected_files changed: "+strings.Join(outside, ", "))
		}
	}
	// The log goes into the receipt store only after the store integrity check.
	if err := writeLog(rc.store.logPath(node.ID, attempt), res); err != nil {
		return nil, nil, err
	}
	if res.status == "success" && node.Kind == "agent" {
		if err := os.WriteFile(rc.store.outputPath(node.ID), []byte(res.output), 0o644); err != nil {
			return nil, nil, err
		}
	}
	if res.status == "success" && node.Role == "producer" {
		if err := commitProducerChanges(rc, node, attempt); err != nil {
			return nil, nil, err
		}
	}
	head, err := headCommit(rc.repo)
	if err != nil {
		return nil, nil, err
	}
	st := buildReceipt(rc, node, attempt, res, head)
	if err := rc.store.append(st); err != nil {
		return nil, nil, err
	}
	fmt.Fprintf(rc.out, "NODE: id=%s attempt=%d status=%s reason=%s duration_ms=%d\n",
		node.ID, attempt, res.status, res.terminalReason, res.durationMS)
	return &st.Predicate, res, nil
}

func (rc *runCtx) stop(nodeID, reason, detail string) int {
	fmt.Fprintf(rc.out, "RUN: status=STOPPED node=%s reason=%s detail=%s\n", nodeID, reason, strings.Join(strings.Fields(detail), " "))
	return exitStopped
}

type runArgs struct{ spec, repo, context, runID, runsDir string }

func runFactory(a runArgs, out io.Writer) (int, error) {
	spec, err := loadSpec(a.spec)
	if err != nil {
		return 0, err
	}
	context, err := loadContext(a.context)
	if err != nil {
		return 0, err
	}
	abs, _ := filepath.Abs(a.repo)
	top, err := git(abs, "rev-parse", "--show-toplevel")
	if err != nil {
		return 0, specErr("%s is not a git repository", abs)
	}
	repo := strings.TrimSpace(top)
	runsDir := a.runsDir
	if runsDir == "" {
		runsDir = filepath.Join(repo, "odd", "runs")
	}
	if runsDir, err = filepath.Abs(runsDir); err != nil {
		return 0, err
	}
	runID := a.runID
	if runID == "" {
		runID = newRunID()
	}
	if !runIDRe.MatchString(runID) {
		return 0, specErr("run id must match [A-Za-z0-9][A-Za-z0-9_.-]*")
	}
	if err := excludeRunsDir(repo, runsDir); err != nil {
		return 0, err
	}
	store, err := newStore(runsDir, runID)
	if err != nil {
		return 0, err
	}
	receipts, err := store.receipts()
	if err != nil {
		return 0, err
	}
	var base string
	if len(receipts) > 0 {
		base = receipts[0].References.VCS.BaseCommit
	} else {
		status, err := git(repo, "status", "--porcelain")
		if err != nil {
			return 0, err
		}
		if strings.TrimSpace(status) != "" {
			return 0, specErr("target repository has uncommitted changes; a new run needs a clean tree")
		}
		if base, err = headCommit(repo); err != nil {
			return 0, err
		}
	}
	branch, err := git(repo, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return 0, err
	}
	traceID := sha256Text(runID)[:32]
	rc := &runCtx{factory: spec.Factory, runID: runID, repo: repo, specDir: spec.dir, baseCommit: base,
		branch: strings.TrimSpace(branch), traceID: traceID,
		traceparent: fmt.Sprintf("00-%s-%s-01", traceID, randomHex(8)),
		context:     context, protected: spec.ProtectedPaths, store: store, out: out}
	fmt.Fprintf(out, "RUN: id=%s factory=%s task=%s runs_dir=%s\n", runID, spec.Factory, context.TaskID, runsDir)

	byID := map[string]*Node{}
	for _, n := range spec.Nodes {
		byID[n.ID] = n
	}
	for {
		receipts, err := store.receipts()
		if err != nil {
			return 0, err
		}
		head, err := headCommit(repo)
		if err != nil {
			return 0, err
		}
		node := nextNode(spec.Nodes, receipts, head)
		if node == nil {
			fmt.Fprintf(out, "RUN: status=COMPLETE id=%s\n", runID)
			return exitOK, nil
		}
		mine := receiptsOf(receipts, node.ID)
		var last *Predicate
		if len(mine) > 0 {
			last = mine[len(mine)-1]
		}
		currentFailure := last != nil && last.Outcome.Status == "failure" && last.References.VCS.HeadCommit == head
		if last != nil && last.Outcome.Status == "needs_decision" && last.References.VCS.HeadCommit == head {
			// Silence in the design means stop: only a new design (a new run) moves on.
			return rc.stop(node.ID, last.Outcome.TerminalReason, reasonOf(last)), nil
		}
		if currentFailure && guardReasons[last.Outcome.TerminalReason] {
			return rc.stop(node.ID, last.Outcome.TerminalReason, reasonOf(last)), nil
		}
		var predicate *Predicate
		var prior []*Predicate
		if node.Retry != "" && currentFailure {
			// Resumed after this checker failed on the current code: decide, do not re-run.
			predicate, prior = last, mine[:len(mine)-1]
		} else {
			p, res, err := execute(rc, node, receipts, "")
			if err != nil {
				return 0, err
			}
			if res.status == "success" {
				continue
			}
			if res.status != "failure" || node.Retry == "" || guardReasons[res.terminalReason] {
				return rc.stop(node.ID, res.terminalReason, reasonOf(p)), nil
			}
			predicate, prior = p, mine
		}
		reason := reasonOf(predicate)
		if n := len(prior); n > 0 && prior[n-1].Outcome.Status == "failure" &&
			prior[n-1].FailureSignature == predicate.FailureSignature {
			return rc.stop(node.ID, "same_failure_signature", reason), nil
		}
		target := byID[node.Retry]
		if len(receiptsOf(receipts, target.ID))-1 >= *spec.MaxRetries {
			return rc.stop(node.ID, "retries_exhausted", reason), nil
		}
		fmt.Fprintf(out, "RETRY: node=%s after=%s reason=%s\n", target.ID, node.ID, strings.Join(strings.Fields(reason), " "))
		current, err := store.receipts()
		if err != nil {
			return 0, err
		}
		_, res, err := execute(rc, target, current, reason)
		if err != nil {
			return 0, err
		}
		if res.status != "success" {
			return rc.stop(target.ID, res.terminalReason, firstNonEmpty(res.reason, res.terminalReason)), nil
		}
	}
}
