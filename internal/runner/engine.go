package runner

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const failPrefix = "FALLO:"

var (
	deniedBash     = []string{"Bash(git push:*)", "Bash(git tag:*)", "Bash(git reset:*)", "Bash(gh:*)"}
	readOnlyDenied = []string{"Edit", "Write", "NotebookEdit", "Bash(git commit:*)"}
	verdictRe      = regexp.MustCompile(`^FACTORY_GATES:.*(?:^|\s)status=(GREEN|RED|MISCONFIGURED)(?:\s|$)`)
	gateFailedRe   = regexp.MustCompile(`GATE: name=(\S+) status=(?:RED|MISCONFIGURED)`)
	gatePassedRe   = regexp.MustCompile(`GATE: name=(\S+) status=GREEN`)
	claudeReasons  = map[string]string{"success": "completed", "error_max_turns": "max_turns_exceeded",
		"error_max_budget_usd": "budget_exceeded", "error_during_execution": "engine_error"}
)

// result is what one node attempt produced, before guards and the receipt.
type result struct {
	status, terminalReason, reason string
	engine, engineVersion          string
	command, tools                 []string
	caps                           Caps
	durationMS                     int64
	exitCode                       int
	telemetry                      Telemetry
	gate                           *Gate
	notes                          string
	spanID                         string
	logOut, logErr                 string
}

func (r *result) fail(status, terminal, reason string) *result {
	r.status, r.terminalReason, r.reason = status, terminal, reason
	return r
}

// runProcess runs cmd in its own process group; SIGTERM then SIGKILL on timeout.
func runProcess(cmd []string, dir string, env []string, stdin string, timeout int) (code int, out, errOut string, timedOut bool) {
	grace := 30 * time.Second
	if v, err := strconv.ParseFloat(os.Getenv("FACTORY_KILL_GRACE"), 64); err == nil {
		grace = time.Duration(v * float64(time.Second))
	}
	c := exec.Command(cmd[0], cmd[1:]...)
	c.Dir, c.Env = dir, env
	c.Stdin = strings.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	c.Stdout, c.Stderr = &stdout, &stderr
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := c.Start(); err != nil {
		return 127, "", fmt.Sprintf("cannot start %s: %v", cmd[0], err), false
	}
	done := make(chan struct{})
	go func() { _ = c.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Duration(timeout) * time.Second):
		timedOut = true
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(grace):
			_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
			<-done
		}
	}
	return c.ProcessState.ExitCode(), stdout.String(), stderr.String(), timedOut
}

func mergeOtel(existing string, attrs [][2]string) string {
	keys := map[string]bool{}
	for _, kv := range attrs {
		keys[kv[0]] = true
	}
	parts := []string{}
	for _, p := range strings.Split(existing, ",") {
		k, _, _ := strings.Cut(p, "=")
		if p != "" && !keys[k] {
			parts = append(parts, p)
		}
	}
	for _, kv := range attrs {
		parts = append(parts, kv[0]+"="+kv[1])
	}
	return strings.Join(parts, ",")
}

func nodeEnv(rc *runCtx, node *Node, attempt int, feedbackFile, engine string) []string {
	attrs := [][2]string{{"service.name", "factory-" + rc.factory}, {"factory.name", rc.factory},
		{"run.id", rc.runID}, {"task.id", rc.context.TaskID}, {"agent.engine", engine}}
	set := map[string]string{
		"FACTORY_NAME":             rc.factory,
		"FACTORY_RUN_ID":           rc.runID,
		"FACTORY_TASK_ID":          rc.context.TaskID,
		"FACTORY_NODE_ID":          node.ID,
		"FACTORY_ATTEMPT":          strconv.Itoa(attempt),
		"FACTORY_FEEDBACK_FILE":    feedbackFile,
		"TRACEPARENT":              rc.traceparent,
		"OTEL_RESOURCE_ATTRIBUTES": mergeOtel(os.Getenv("OTEL_RESOURCE_ATTRIBUTES"), attrs),
	}
	env := []string{}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if _, override := set[k]; !override {
			env = append(env, kv)
		}
	}
	for k, v := range set {
		env = append(env, k+"="+v)
	}
	return env
}

func claudeBin() string {
	if b := os.Getenv("FACTORY_CLAUDE_BIN"); b != "" {
		return b
	}
	return "claude"
}

func claudeCommand(node *Node) (cmd, tools []string) {
	denied := append(append([]string{}, deniedBash...), node.Deny...)
	for _, t := range node.Tools {
		if !(node.ReadOnly && contains(readOnlyDenied, t)) {
			tools = append(tools, t)
		}
	}
	if node.ReadOnly {
		denied = append(denied, readOnlyDenied...)
	}
	cmd = []string{claudeBin(), "-p", "--output-format", "json",
		"--max-turns", strconv.Itoa(node.maxTurns()),
		"--max-budget-usd", strconv.FormatFloat(node.maxBudget(), 'f', -1, 64),
		"--no-session-persistence"}
	if len(tools) > 0 {
		cmd = append(append(cmd, "--allowedTools"), tools...)
	}
	cmd = append(append(cmd, "--disallowedTools"), denied...)
	return cmd, tools
}

// claudeResult is the subset of `claude -p --output-format json` the runner reads.
type claudeResult struct {
	Subtype      string                     `json:"subtype"`
	IsError      bool                       `json:"is_error"`
	Result       string                     `json:"result"`
	NumTurns     *int                       `json:"num_turns"`
	TotalCostUSD *float64                   `json:"total_cost_usd"`
	Usage        map[string]json.RawMessage `json:"usage"`
	ModelUsage   map[string]map[string]any  `json:"modelUsage"`
}

// tokenUsage sums modelUsage; top-level usage is all zeros on error results.
func tokenUsage(d *claudeResult) *Tokens {
	var in, out int64
	seen := false
	for _, u := range d.ModelUsage {
		o, ok := u["outputTokens"].(float64)
		if !ok {
			continue
		}
		seen = true
		for _, k := range []string{"inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"} {
			if v, ok := u[k].(float64); ok {
				in += int64(v)
			}
		}
		out += int64(o)
	}
	if !seen {
		num := func(k string) (int64, bool) {
			var v int64
			raw, ok := d.Usage[k]
			return v, ok && json.Unmarshal(raw, &v) == nil
		}
		i, ok1 := num("input_tokens")
		o, ok2 := num("output_tokens")
		if !ok1 || !ok2 {
			return nil
		}
		cr, _ := num("cache_read_input_tokens")
		cc, _ := num("cache_creation_input_tokens")
		in, out = i+cr+cc, o
	}
	return &Tokens{InputTokens: in, OutputTokens: out, TotalTokens: in + out}
}

func runAgent(rc *runCtx, node *Node, attempt int, feedback, feedbackFile string) *result {
	data, err := os.ReadFile(node.PromptFile)
	prompt := string(data)
	cmd, tools := claudeCommand(node)
	timeout := node.timeout(1800)
	turns, budget := node.maxTurns(), node.maxBudget()
	res := &result{engine: "claude-code-headless", command: cmd, tools: tools,
		caps: Caps{MaxTurns: &turns, MaxBudgetUSD: &budget, TimeoutSeconds: timeout}}
	if err != nil {
		res.logErr = err.Error()
		return res.fail("misconfigured", "misconfigured", "cannot read prompt_file")
	}
	if feedback != "" {
		prompt += "\n\n## Feedback from the previous attempt\n\n" +
			"A later step failed with the reason below. Fix it.\n\n" + feedback + "\n"
	}
	env := nodeEnv(rc, node, attempt, feedbackFile, "claude-code")
	start := time.Now()
	code, out, errOut, timedOut := runProcess(cmd, rc.repo, env, prompt, timeout)
	res.durationMS = time.Since(start).Milliseconds()
	res.exitCode, res.logOut, res.logErr = code, out, errOut
	if timedOut {
		return res.fail("failure", "timeout", fmt.Sprintf("timed out after %ds", timeout))
	}
	d := &claudeResult{}
	if err := json.Unmarshal([]byte(out), d); err != nil {
		return res.fail("failure", "engine_output_invalid", firstNonEmpty(lastLine(errOut), lastLine(out), fmt.Sprintf("exit %d", code)))
	}
	res.telemetry = Telemetry{GenAISystem: "anthropic", NumTurns: d.NumTurns, TotalCostUSD: d.TotalCostUSD,
		Tokens: tokenUsage(d)}
	if models := sortedKeys(d.ModelUsage); len(models) > 0 {
		res.telemetry.RequestModel = models[0]
	}
	if runes := []rune(d.Result); len(runes) > 2000 {
		res.notes = string(runes[len(runes)-2000:])
	} else {
		res.notes = d.Result
	}
	final := lastLine(d.Result)
	if strings.HasPrefix(final, failPrefix) {
		return res.fail("failure", "step_failed", strings.TrimSpace(final[len(failPrefix):]))
	}
	if d.IsError || d.Subtype != "success" || code != 0 {
		reason, ok := claudeReasons[d.Subtype]
		if !ok {
			reason = firstNonEmpty(d.Subtype, "engine_error")
		}
		return res.fail("failure", reason, firstNonEmpty(final, d.Subtype, fmt.Sprintf("exit %d", code)))
	}
	return res.fail("success", "completed", "")
}

func runCode(rc *runCtx, node *Node, attempt int, feedbackFile string) *result {
	repl := strings.NewReplacer("{repo}", rc.repo, "{base_commit}", rc.baseCommit, "{run_dir}", rc.store.runDir,
		"{spec_dir}", rc.specDir, "{feedback_file}", feedbackFile)
	cmd := make([]string, len(node.Command))
	for i, a := range node.Command {
		cmd[i] = repl.Replace(a)
	}
	timeout := node.timeout(600)
	env := nodeEnv(rc, node, attempt, feedbackFile, "code")
	start := time.Now()
	code, out, errOut, timedOut := runProcess(cmd, rc.repo, env, "", timeout)
	res := &result{engine: filepath.Base(cmd[0]), command: cmd, tools: []string{filepath.Base(cmd[0])},
		caps: Caps{TimeoutSeconds: timeout}, durationMS: time.Since(start).Milliseconds(),
		exitCode: code, logOut: out, logErr: errOut}
	lines := strings.Split(out, "\n")
	verdict := ""
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); verdictRe.MatchString(l) {
			verdict = l
			break
		}
	}
	gateStatus := ""
	if verdict != "" {
		gateStatus = verdictRe.FindStringSubmatch(verdict)[1]
		res.gate = &Gate{Status: gateStatus, VerdictLine: verdict,
			ChecksPassed: uniqueMatches(gatePassedRe, out), ChecksFailed: uniqueMatches(gateFailedRe, out)}
	}
	if timedOut {
		return res.fail("failure", "timeout", fmt.Sprintf("timed out after %ds", timeout))
	}
	final := lastLine(out)
	if strings.HasPrefix(final, failPrefix) {
		return res.fail("failure", "step_failed", strings.TrimSpace(final[len(failPrefix):]))
	}
	if gateStatus == "MISCONFIGURED" || code == 126 || code == 127 {
		return res.fail("misconfigured", "misconfigured", firstNonEmpty(verdict, lastLine(errOut), fmt.Sprintf("exit %d", code)))
	}
	if code != 0 || gateStatus == "RED" {
		terminal := "step_failed"
		if gateStatus != "" {
			terminal = "gate_failed"
		}
		return res.fail("failure", terminal, firstNonEmpty(verdict, final, lastLine(errOut), fmt.Sprintf("exit %d", code)))
	}
	if gateStatus != "" {
		return res.fail("success", "gate_passed", "")
	}
	return res.fail("success", "completed", "")
}

func writeLog(path string, res *result) error {
	var b strings.Builder
	b.WriteString("$ " + strings.Join(res.command, " ") + "\n")
	b.WriteString(res.logOut)
	if res.logErr != "" {
		b.WriteString("\n--- stderr ---\n" + res.logErr)
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func engineVersion(bin string) string {
	out, err := exec.Command(bin, "--version").Output()
	if err != nil {
		return ""
	}
	return lastLine(string(out))
}

func uniqueMatches(re *regexp.Regexp, text string) []string {
	set := map[string]bool{}
	for _, m := range re.FindAllStringSubmatch(text, -1) {
		set[m[1]] = true
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func lastLine(text string) string {
	lines := strings.Split(text, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
