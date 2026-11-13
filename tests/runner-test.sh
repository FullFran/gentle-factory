#!/usr/bin/env bash
# Contract tests for the factory runner (cmd/factory), through its public CLI.
# Agent nodes run against a claude double; no model is called and nothing is spent.
# Needs bash, git, go and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in git go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
validator=()
if command -v check-jsonschema >/dev/null 2>&1; then validator=(check-jsonschema)
elif command -v uvx >/dev/null 2>&1; then validator=(uvx -q check-jsonschema); fi

# The pre-existing scenarios must not export traces to whatever collector the caller has.
unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_HEADERS

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-runner-test.XXXXXX")"
receiver_pids=()
trap '[ "${#receiver_pids[@]}" -gt 0 ] && kill "${receiver_pids[@]}" 2>/dev/null; rm -rf "$scratch"' EXIT
factory="$scratch/factory"
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf "FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "  %s\n" "$2"; [ -n "${out:-}" ] && printf "  out: %s\n" "${out//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }

# --- doubles ---------------------------------------------------------------

mkdir -p "$scratch/bin"
cat >"$scratch/bin/claude" <<'EOF'
#!/usr/bin/env bash
# claude double: records argv, env and prompt, then acts per FAKE_MODE.
# Its JSON mirrors claude 2.1.x: top-level usage can be zero, per-model counts are in modelUsage.
if [ "${1:-}" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
log="${FAKE_LOG:?}"
prompt="$(cat)"
{
  printf 'ARGV:'; printf ' [%s]' "$@"; printf '\n'
  printf 'OTEL: %s\n' "$OTEL_RESOURCE_ATTRIBUTES"
  printf 'TRACEPARENT: %s\n' "$TRACEPARENT"
  printf 'IDS: %s %s %s %s\n' "$FACTORY_RUN_ID" "$FACTORY_TASK_ID" "$FACTORY_NODE_ID" "$FACTORY_ATTEMPT"
  printf 'PROMPT: %s\n' "$(printf '%s' "$prompt" | tr '\n' ' ')"
} >>"$log"
result="hecho"
mode_var="FAKE_MODE_${FACTORY_NODE_ID}"
case "${!mode_var:-${FAKE_MODE:-edit}}" in
  edit) echo "attempt $FACTORY_ATTEMPT" >impl.txt ;;
  plan) result=$'PLAN: write impl.txt\nthen stop' ;;
  failonce) [ "$FACTORY_ATTEMPT" = 1 ] && result=$'the summary leaks a path\nFALLO: remove the local path from the summary' ;;
  decision) result=$'no sé qué hacer\nDECISION: should the symlink be followed or copied?' ;;
  outside) echo "attempt $FACTORY_ATTEMPT" >impl.txt; echo x >other.txt ;;
  hang) : ;;
  noop) : ;;
  fallo) result=$'lo he intentado\nFALLO: el diseño no dice qué hacer con los symlinks' ;;
  protected) echo "tampered" >>gates/gate.sh ;;
  ignored) mkdir -p .factory && echo x >.factory/cfg ;;
  receipts) for f in "${FAKE_RUNS:?}"/*/receipts/*.json; do echo ' ' >>"$f"; done; echo x >impl.txt ;;
esac
printf '%s\n' '{"type":"system","subtype":"init"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
if [ "${!mode_var:-${FAKE_MODE:-edit}}" = hang ]; then sleep 30; fi
jq -cn --arg r "$result" '{type:"result",subtype:"success",is_error:false,result:$r,num_turns:3,
  total_cost_usd:0.25,usage:{input_tokens:0,output_tokens:0},
  modelUsage:{"claude-fake-1":{inputTokens:40,cacheReadInputTokens:50,cacheCreationInputTokens:10,outputTokens:20}}}'
EOF
chmod +x "$scratch/bin/claude"
export FACTORY_CLAUDE_BIN="$scratch/bin/claude"
export FAKE_LOG="$scratch/claude.log"
export FACTORY_KILL_GRACE=1

# check.sh: passes once impl.txt reports attempt >= PASS_AT; REASON=fixed keeps the reason constant.
cat >"$scratch/bin/check.sh" <<'EOF'
#!/usr/bin/env bash
n="$(sed -n 's/^attempt //p' impl.txt 2>/dev/null)"
if [ "${n:-0}" -ge "${PASS_AT:-1}" ]; then echo "all good"; exit 0; fi
if [ "${REASON:-}" = fixed ]; then echo "FALLO: impl.txt is wrong"; else echo "FALLO: impl.txt is wrong at attempt ${n:-0}"; fi
exit 1
EOF
chmod +x "$scratch/bin/check.sh"

new_repo() { # new_repo NAME -> path of a clean repo with one commit and a gate script
  local repo="$scratch/$1"
  mkdir -p "$repo/gates"
  git -C "$repo" init -q -b main
  echo 'echo gate' >"$repo/gates/gate.sh"
  echo base >"$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
  printf '%s' "$repo"
}

cat >"$scratch/context.json" <<'EOF'
{"repository": "FullFran/sample-app",
 "issue": {"number": 55, "url": "https://github.com/FullFran/sample-app/issues/55"},
 "design_comment": {"id": 123, "url": "https://github.com/FullFran/sample-app/issues/55#issuecomment-123",
   "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
   "updated_at": "2026-11-10T01:15:30Z"}}
EOF
echo "Implement the change described in the issue." >"$scratch/implement.md"

write_spec() { # write_spec FILE MAX_RETRIES CHECK_JSON_EXTRA
  cat >"$1" <<EOF
{"factory": "test", "max_retries": $2,
 "nodes": [
  {"id": "implement", "kind": "agent", "prompt_file": "implement.md",
   "tools": ["Read", "Edit", "Write", "Bash"], "max_turns": 5, "max_budget_usd": 0.5},
  {"id": "verify", "kind": "code", "command": ["$scratch/bin/check.sh"], "read_only": true $3}
 ]}
EOF
}

run() { # run REPO SPEC [extra args] -> sets out, code
  out="$("$factory" run --spec "$2" --repo "$1" --context "$scratch/context.json" "${@:3}" 2>&1)"
  code=$?
}
receipt() { # receipt REPO N -> predicate of the Nth receipt (1-based) of the only run
  jq -c .predicate "$(find "$1/odd/runs" -path '*/receipts/*.json' | sort | sed -n "${2}p")"
}
count_receipts() { find "$1/odd/runs" -path '*/receipts/*.json' | wc -l | tr -d ' '; }

# --- step success ----------------------------------------------------------

write_spec "$scratch/spec.json" 2 ', "retry": "implement"'
repo="$(new_repo success)"
: >"$FAKE_LOG"
run "$repo" "$scratch/spec.json"
check "success: exit 0 and COMPLETE" '[ "$code" = 0 ] && grep -q "RUN: status=COMPLETE" <<<"$out"'
check "success: one receipt per node" '[ "$(count_receipts "$repo")" = 2 ]'
check "success: implement receipt is a success agent receipt" \
  '[ "$(receipt "$repo" 1 | jq -r "[.step.node_kind,.outcome.status,.outcome.terminal_reason]|join(\",\")")" = "agent,success,completed" ]'
check "success: runner committed the producer edits and receipts bind that commit" \
  '[ "$(receipt "$repo" 1 | jq -r .references.vcs.head_commit)" = "$(git -C "$repo" rev-parse HEAD)" ] && [ -z "$(git -C "$repo" status --porcelain)" ]'
check "success: receipt store is not committed" '! git -C "$repo" ls-files | grep -q "^odd/runs"'
check "success: claude ran headless with json output and caps" \
  'grep -q "\[-p\] \[--output-format\] \[stream-json\] \[--verbose\] \[--max-turns\] \[5\] \[--max-budget-usd\] \[0.5\]" "$FAKE_LOG"'
check "success: allowlist passed" 'grep -q "\[--allowedTools\] \[Read\] \[Edit\] \[Write\] \[Bash\]" "$FAKE_LOG"'
check "success: deny list passed" \
  'grep -q "\[--disallowedTools\] \[Bash(git push:\*)\] \[Bash(git tag:\*)\] \[Bash(git reset:\*)\] \[Bash(gh:\*)\]" "$FAKE_LOG"'
run_id="$(receipt "$repo" 1 | jq -r .run_id)"
check "success: identity reaches the agent (factory#6 attributes)" \
  'grep -q "OTEL: .*service.name=factory-test,factory.name=test,run.id=$run_id,task.id=FullFran/sample-app#55,agent.engine=claude-code" "$FAKE_LOG"'
check "success: trace context reaches the agent and the receipt" \
  'grep -q "TRACEPARENT: 00-$(receipt "$repo" 1 | jq -r .telemetry.trace_id)-" "$FAKE_LOG"'
check "success: agent telemetry recorded from the engine JSON" \
  '[ "$(receipt "$repo" 1 | jq -c "[.telemetry.total_cost_usd,.telemetry.num_turns,.telemetry.tokens.total_tokens,.telemetry.request_model]")" = "[0.25,3,120,\"claude-fake-1\"]" ]'
check "success: the receipt keeps cache reads and cache writes apart inside input tokens" \
  '[ "$(receipt "$repo" 1 | jq -c "[.telemetry.tokens.input_tokens,.telemetry.tokens.cache_read_input_tokens,.telemetry.tokens.cache_creation_input_tokens]")" = "[100,50,10]" ]'
check "success: agent decisions recorded as notes" '[ "$(receipt "$repo" 1 | jq -r .notes)" = hecho ]'
check "success: verify receipt is a success code receipt" \
  '[ "$(receipt "$repo" 2 | jq -r "[.step.node_id,.outcome.status]|join(\",\")")" = "verify,success" ]'
check "success: a log per step" '[ -s "$(find "$repo/odd/runs" -name implement-1.log)" ] && grep -q "all good" "$(find "$repo/odd/runs" -name verify-1.log)"'
if [ "${#validator[@]}" -gt 0 ]; then
  check "success: receipts validate against schemas/receipt.schema.json" \
    '"${validator[@]}" --schemafile "$here/schemas/receipt.schema.json" $(find "$repo/odd/runs" -path "*/receipts/*.json") >/dev/null 2>&1'
else
  printf 'SKIP receipt schema validation (check-jsonschema unavailable)\n'
fi

# --- resume and staleness --------------------------------------------------

: >"$FAKE_LOG"
run "$repo" "$scratch/spec.json" --run-id "$run_id"
check "resume: a complete run runs nothing" '[ "$code" = 0 ] && ! grep -q "NODE:" <<<"$out" && [ ! -s "$FAKE_LOG" ]'
echo more >>"$repo/README.md"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam "human edit"
run "$repo" "$scratch/spec.json" --run-id "$run_id"
check "resume: a new commit makes the checker stale, not the producer" \
  '[ "$code" = 0 ] && grep -q "NODE: id=verify attempt=2 kind=code" <<<"$out" && ! grep -q "NODE: id=implement" <<<"$out"'

# --- step failure via last line FALLO: --------------------------------------

write_spec "$scratch/spec-noretry.json" 2 ''
repo="$(new_repo fallo-noretry)"
PASS_AT=9 run "$repo" "$scratch/spec-noretry.json"
check "FALLO (code): run stops with the step's reason" \
  '[ "$code" = 1 ] && grep -q "RUN: status=STOPPED node=verify reason=step_failed detail=impl.txt is wrong at attempt 1" <<<"$out"'
check "FALLO (code): failure receipt carries a failure signature" \
  '[ "$(receipt "$repo" 2 | jq -r "[.outcome.status,.outcome.exit_code,(.failure_signature|length)]|join(\",\")")" = "failure,1,64" ]'
repo="$(new_repo fallo-agent)"
FAKE_MODE=fallo run "$repo" "$scratch/spec.json"
check "FALLO (agent): last line FALLO: fails the step even with is_error=false" \
  '[ "$code" = 1 ] && grep -q "node=implement reason=step_failed detail=el diseño no dice qué hacer con los symlinks" <<<"$out" && [ "$(count_receipts "$repo")" = 1 ]'

# --- guards ----------------------------------------------------------------

cat >"$scratch/spec-ro.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "review", "kind": "code", "command": ["bash", "-c", "echo x >> README.md"], "read_only": true}]}
EOF
repo="$(new_repo guard-ro)"
run "$repo" "$scratch/spec-ro.json"
check "guard: a read-only step that changes the repo fails" \
  '[ "$code" = 1 ] && grep -q "reason=read_only_modified" <<<"$out" && [ "$(receipt "$repo" 1 | jq -r .outcome.terminal_reason)" = read_only_modified ]'
cat >"$scratch/spec-ro2.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "review", "kind": "code", "command": ["bash", "-c", "git -c user.name=t -c user.email=t@t commit -q --allow-empty -m sneaky"], "read_only": true}]}
EOF
repo="$(new_repo guard-ro-commit)"
run "$repo" "$scratch/spec-ro2.json"
check "guard: a read-only step that commits fails (HEAD moved)" '[ "$code" = 1 ] && grep -q "reason=read_only_modified" <<<"$out"'
cat >"$scratch/spec-review.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "review", "kind": "agent", "prompt_file": "implement.md", "read_only": true, "tools": ["Read", "Edit", "Bash"]}]}
EOF
repo="$(new_repo guard-ro-agent)"
: >"$FAKE_LOG"
FAKE_MODE=noop run "$repo" "$scratch/spec-review.json"
check "guard: a read-only agent loses edit tools and is denied commits" \
  '[ "$code" = 0 ] && grep -q "\[--allowedTools\] \[Read\] \[Bash\] \[--disallowedTools\]" "$FAKE_LOG" && grep -q "\[Edit\] \[Write\] \[NotebookEdit\] \[Bash(git commit:\*)\]" "$FAKE_LOG"'
repo="$(new_repo guard-protected)"
FAKE_MODE=protected run "$repo" "$scratch/spec.json"
check "guard: an agent editing gate scripts fails with protected_path_modified" \
  '[ "$code" = 1 ] && grep -q "node=implement reason=protected_path_modified detail=protected paths changed: gates/gate.sh" <<<"$out"'
check "guard: protected edits are not committed by the runner" '[ -n "$(git -C "$repo" status --porcelain)" ]'
repo="$(new_repo guard-receipts)"
run "$repo" "$scratch/spec.json"
run_id="$(receipt "$repo" 1 | jq -r .run_id)"
echo more >>"$repo/README.md"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam "human edit"
cat >"$scratch/spec-redo.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "verify", "kind": "code", "command": ["$scratch/bin/check.sh"], "read_only": true},
  {"id": "polish", "kind": "agent", "prompt_file": "implement.md", "tools": ["Edit"]}]}
EOF
FAKE_MODE=receipts FAKE_RUNS="$repo/odd/runs" run "$repo" "$scratch/spec-redo.json" --run-id "$run_id"
check "guard: an agent editing receipts fails with protected_path_modified" \
  '[ "$code" = 1 ] && grep -q "node=polish reason=protected_path_modified detail=protected paths changed: odd/runs/" <<<"$out"'

repo="$(new_repo guard-ignored)"
printf '.factory/\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm ignore
FAKE_MODE=ignored run "$repo" "$scratch/spec.json"
check "guard: an agent writing a gitignored protected path still fails" \
  '[ "$code" = 1 ] && grep -q "node=implement reason=protected_path_modified detail=protected paths changed: .factory/, .factory/cfg" <<<"$out"'
cat >"$scratch/spec-ro-retry.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "implement", "kind": "agent", "prompt_file": "implement.md", "tools": ["Edit"]},
  {"id": "verify", "kind": "code", "command": ["bash", "-c", "echo artifact > build.out"], "read_only": true, "retry": "implement"}]}
EOF
repo="$(new_repo guard-ro-final)"
run "$repo" "$scratch/spec-ro-retry.json"
check "guard: a read-only trip is final, not retried into a producer commit" \
  '[ "$code" = 1 ] && grep -q "node=verify reason=read_only_modified" <<<"$out" && ! grep -q "RETRY:" <<<"$out" && ! git -C "$repo" log --format=%H -1 -- build.out | grep -q .'
run_id="$(receipt "$repo" 1 | jq -r .run_id)"
run "$repo" "$scratch/spec-ro-retry.json" --run-id "$run_id"
check "guard: resuming after a read-only trip stops again without running anything" \
  '[ "$code" = 1 ] && grep -q "node=verify reason=read_only_modified" <<<"$out" && ! grep -q "NODE:" <<<"$out"'

# --- bounded return loop ---------------------------------------------------

repo="$(new_repo retry-ok)"
: >"$FAKE_LOG"
PASS_AT=2 run "$repo" "$scratch/spec.json"
check "retry: a failing checker sends its reason back and the run completes" \
  '[ "$code" = 0 ] && grep -q "RETRY: node=implement after=verify reason=impl.txt is wrong at attempt 1" <<<"$out"'
check "retry: the implementer gets the reason in its prompt" \
  'grep -q "IDS: .* implement 2" "$FAKE_LOG" && grep "IDS: .* implement 2" -A1 "$FAKE_LOG" | grep -q "PROMPT: .*Feedback from the previous attempt.*impl.txt is wrong at attempt 1"'
check "retry: the reason is written to a feedback file" \
  'grep -qx "impl.txt is wrong at attempt 1" "$(find "$repo/odd/runs" -name implement.txt)"'
repo="$(new_repo retry-exhausted)"
PASS_AT=9 run "$repo" "$scratch/spec.json"
check "retry: exhaustion stops with the last reason after N extra attempts" \
  '[ "$code" = 1 ] && grep -q "RUN: status=STOPPED node=verify reason=retries_exhausted detail=impl.txt is wrong at attempt 3" <<<"$out" && [ "$(grep -c "NODE: id=implement attempt=.* status=" <<<"$out")" = 3 ]'
repo="$(new_repo retry-same)"
PASS_AT=9 REASON=fixed run "$repo" "$scratch/spec.json"
check "retry: an identical failure signature halts early" \
  '[ "$code" = 1 ] && grep -q "reason=same_failure_signature" <<<"$out" && [ "$(grep -c "NODE: id=implement attempt=.* status=" <<<"$out")" = 2 ]'
repo="$(new_repo retry-resume)"
PASS_AT=9 run "$repo" "$scratch/spec-noretry.json"   # stands in for a run interrupted right after the checker failed
run_id="$(receipt "$repo" 1 | jq -r .run_id)"
PASS_AT=2 run "$repo" "$scratch/spec.json" --run-id "$run_id"
check "retry: resuming after a checker failure retries without re-running the checker first" \
  '[ "$code" = 0 ] && [ "$(grep -v "^RUN: id=" <<<"$out" | head -1)" = "RETRY: node=implement after=verify reason=impl.txt is wrong at attempt 1" ]'

# --- timeout -----------------------------------------------------------------

cat >"$scratch/spec-slow.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "slow", "kind": "code", "command": ["sleep", "30"], "timeout_seconds": 1}]}
EOF
repo="$(new_repo timeout)"
start=$SECONDS
run "$repo" "$scratch/spec-slow.json"
check "timeout: the step is killed and fails with timeout" \
  '[ "$code" = 1 ] && grep -q "node=slow reason=timeout" <<<"$out" && [ $((SECONDS - start)) -lt 10 ]'

# --- identity for engines without OTLP (#6 fallback) -------------------------

cat >"$scratch/spec-wrapper.json" <<'EOF'
{"factory": "test", "nodes": [
  {"id": "wrapped", "kind": "code", "read_only": true, "command": ["bash", "-c",
   "echo \"OTEL=$OTEL_RESOURCE_ATTRIBUTES\"; echo \"IDS=$FACTORY_NAME $FACTORY_RUN_ID $FACTORY_TASK_ID $FACTORY_NODE_ID $FACTORY_ATTEMPT\"; echo \"TP=$TRACEPARENT\""]}]}
EOF
repo="$(new_repo wrapper)"
run "$repo" "$scratch/spec-wrapper.json"
wrapper_log="$(find "$repo/odd/runs" -name wrapped-1.log)"
run_id="$(receipt "$repo" 1 | jq -r .run_id)"
check "fallback: a code node wrapping another engine gets the OTEL attributes with agent.engine=code" \
  '[ "$code" = 0 ] && grep -q "^OTEL=.*service.name=factory-test,factory.name=test,run.id=$run_id,task.id=FullFran/sample-app#55,agent.engine=code" "$wrapper_log"'
check "fallback: the same identity arrives as plain FACTORY_* variables" \
  'grep -qx "IDS=test $run_id FullFran/sample-app#55 wrapped 1" "$wrapper_log"'
check "fallback: the receipt keeps run, node, engine and trace for the wrapped engine" \
  '[ "$(receipt "$repo" 1 | jq -r "[.step.node_id,.execution.engine]|join(\",\")")" = "wrapped,bash" ] && grep -q "^TP=00-$(receipt "$repo" 1 | jq -r .telemetry.trace_id)-" "$wrapper_log"'

# --- summary and cost recorded once ------------------------------------------

repo="$(new_repo summary)"
PASS_AT=2 run "$repo" "$scratch/spec.json"
PASS_AT=9 run "$repo" "$scratch/spec.json"
summary_json="$("$factory" summary --repo "$repo" --json)"
check "summary: cost recorded once per agent attempt (5 attempts x 0.25)" \
  'jq -e ".nodes.implement.cost_usd == 1.25 and .nodes.verify.cost_usd == 0" <<<"$summary_json" >/dev/null'
check "summary: counts runs, failures and retries" \
  '[ "$(jq -c "[.runs,.nodes.verify.failures,.nodes.implement.retries]" <<<"$summary_json")" = "[2,4,3]" ]'
summary_text="$("$factory" summary --repo "$repo")"
check "summary: names the step that fails, retries and costs the most" \
  'grep -qx "MOST: failures=verify retries=implement cost=implement" <<<"$summary_text"'

# --- upstream handoff, design, decisions and expected files (factory#3) -------

mkdir -p "$scratch/designed"
echo "Count the JSON files. DESIGN-MARKER" >"$scratch/designed/design.md"
echo "agy fails with ENOENT. ISSUE-MARKER" >"$scratch/designed/issue.md"
cat >"$scratch/designed/context.json" <<'EOF'
{"repository": "FullFran/bifrost",
 "issue": {"number": 7, "url": "https://github.com/FullFran/bifrost/issues/7"},
 "design_comment": {"id": 9, "url": "https://github.com/FullFran/bifrost/issues/7#issuecomment-9",
   "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
   "updated_at": "2026-11-10T01:15:30Z"},
 "done_when": "test -f impl.txt", "expected_files": ["impl.*", "docs/**"],
 "design_file": "design.md", "issue_file": "issue.md"}
EOF
echo "Plan the change." >"$scratch/plan.md"
cat >"$scratch/handoff.json" <<EOF
{"factory": "test", "max_retries": 2,
 "nodes": [
  {"id": "plan", "kind": "agent", "prompt_file": "plan.md", "role": "producer", "read_only": true},
  {"id": "implement", "kind": "agent", "prompt_file": "implement.md", "inputs": ["plan"]},
  {"id": "verify", "kind": "code", "read_only": true, "retry": "implement",
   "command": ["bash", "-c", "jq -r .done_when \"\$FACTORY_CONTEXT_FILE\" | bash && echo DONE-OK"]}
 ]}
EOF
drun() { # drun REPO SPEC [extra args]: run with the designed context
  out="$("$factory" run --spec "$2" --repo "$1" --context "$scratch/designed/context.json" "${@:3}" 2>&1)"
  code=$?
}
repo="$(new_repo handoff)"
: >"$FAKE_LOG"
FAKE_MODE_plan=plan drun "$repo" "$scratch/handoff.json"
check "handoff: designed run completes" '[ "$code" = 0 ] && grep -q "RUN: status=COMPLETE" <<<"$out"'
check "handoff: the implementer prompt carries the plan node notes" \
  'grep "IDS: .* implement 1" -A1 "$FAKE_LOG" | grep -q "## Output of plan .*PLAN: write impl.txt"'
check "handoff: the planner prompt carries no upstream section" '! grep "IDS: .* plan 1" -A1 "$FAKE_LOG" | grep -q "## Output of"'
check "design: every agent prompt carries the issue and the design" \
  '[ "$(grep -c "PROMPT: .*## Issue .*ISSUE-MARKER.*## Design .*DESIGN-MARKER" "$FAKE_LOG")" = 2 ]'
check "design: code nodes get the context file (done_when ran)" \
  'grep -q DONE-OK "$(find "$repo/odd/runs" -name "verify-1.log")"'
check "design: allowed edits inside expected_files are committed" \
  '[ -z "$(git -C "$repo" status --porcelain)" ] && git -C "$repo" ls-files | grep -qx impl.txt'

echo '{"factory": "test", "nodes": [{"id": "implement", "kind": "agent", "prompt_file": "implement.md", "inputs": ["later"]}, {"id": "later", "kind": "code", "command": ["true"]}]}' >"$scratch/bad-inputs.json"
run "$(new_repo bad-inputs)" "$scratch/bad-inputs.json"
check "handoff: inputs must name earlier nodes" '[ "$code" = 2 ] && grep -q "input \"later\" must be an earlier node" <<<"$out"'

repo="$(new_repo decision)"
FAKE_MODE=decision drun "$repo" "$scratch/handoff.json"
check "decision: a DECISION: last line stops the run (exit 1, needs_decision)" \
  '[ "$code" = 1 ] && grep -q "RUN: status=STOPPED node=plan reason=user_decision_required detail=should the symlink be followed or copied?" <<<"$out"'
check "decision: the receipt status is needs_decision" \
  '[ "$(receipt "$repo" 1 | jq -r "[.outcome.status,.outcome.terminal_reason]|join(\",\")")" = "needs_decision,user_decision_required" ]'
rid="$(receipt "$repo" 1 | jq -r .run_id)"
FAKE_MODE=edit drun "$repo" "$scratch/handoff.json" --run-id "$rid"
check "decision: resuming does not re-run the node until the design changes" \
  '[ "$code" = 1 ] && grep -q "reason=user_decision_required" <<<"$out" && [ "$(count_receipts "$repo")" = 1 ]'
decision_json="$("$factory" summary --repo "$repo" --json)"
check "summary: decisions are counted apart from failures" \
  'jq -e ".nodes.plan.decisions == 1 and .nodes.plan.failures == 0" <<<"$decision_json" >/dev/null'

repo="$(new_repo outside)"
FAKE_MODE_plan=plan FAKE_MODE_implement=outside drun "$repo" "$scratch/handoff.json"
check "expected-files: an edit outside expected_files stops the run" \
  '[ "$code" = 1 ] && grep -q "RUN: status=STOPPED node=implement reason=unexpected_path_modified detail=.*other.txt" <<<"$out"'
check "expected-files: the violation is not committed and not retried" \
  '[ "$(git -C "$repo" rev-list --count HEAD)" = 1 ] && [ "$(count_receipts "$repo")" = 2 ]'

# A checker that failed must run again after its producer retried, even when the
# producer only changed its answer and HEAD did not move.
echo "Review the change." >"$scratch/review.md"
cat >"$scratch/textfix.json" <<EOF
{"factory": "test", "max_retries": 2,
 "nodes": [
  {"id": "implement", "kind": "agent", "prompt_file": "implement.md"},
  {"id": "review", "kind": "agent", "prompt_file": "review.md", "read_only": true, "retry": "implement"}
 ]}
EOF
repo="$(new_repo textfix)"
FAKE_MODE_implement=noop FAKE_MODE_review=failonce run "$repo" "$scratch/textfix.json"
check "retry: a checker re-runs after a producer retry that left HEAD unchanged" \
  '[ "$code" = 0 ] && grep -q "NODE: id=review attempt=2 kind=agent" <<<"$out" && grep -q "RUN: status=COMPLETE" <<<"$out"'

# A timed-out agent keeps what it did (#30): the stream so far is in the log and the receipt notes.
cat >"$scratch/hang.json" <<EOF
{"factory": "test", "nodes": [{"id": "implement", "kind": "agent", "prompt_file": "implement.md", "timeout_seconds": 2}]}
EOF
repo="$(new_repo hang)"
FAKE_MODE=hang run "$repo" "$scratch/hang.json"
check "timeout: a timed-out agent node stops the run with reason timeout" '[ "$code" = 1 ] && grep -q "reason=timeout" <<<"$out"'
check "timeout: the node log keeps the agent's stream until the kill" 'grep -q "\"command\":\"npm test\"" "$(find "$repo/odd/runs" -name "implement-1.log")"'
check "timeout: the receipt notes name the last tool call" '[ "$(receipt "$repo" 1 | jq -r .notes | grep -c "last tool: Bash npm test")" = 1 ]'

# --- collect (factory#3 step 1) -------------------------------------------------

cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh double: serves issue 7 of FullFran/bifrost from $FAKE_GH_DIR.
printf '%s\n' "$*" >>"${FAKE_GH_DIR:?}/calls"
case "$1 $2" in
  "issue view") cat "$FAKE_GH_DIR/issue.json" ;;
  "api repos/FullFran/bifrost/issues/7/comments") cat "$FAKE_GH_DIR/comments.json" ;;
  *) echo "gh double: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$scratch/bin/gh"
export FACTORY_GH_BIN="$scratch/bin/gh"
design_body() { # design_body JSON -> a design comment body around that block
  printf '<!-- factory-design:v1\n%s\n-->\n\n# Resolve the bifrost binary\n\nDone when the test passes.\n' "$1"
}
good='{"schema_version": "1.0", "issue": 7, "ready_signal": "factory:ready", "done_when": "test -f fixed.txt", "expected_files": ["pi/runtime.mjs", "pi/bifrost.test.mjs"]}'
setup_gh() { # setup_gh LABEL DESIGN_JSON -> fresh $FAKE_GH_DIR
  export FAKE_GH_DIR; FAKE_GH_DIR="$(mktemp -d "$scratch/gh.XXXX")"
  jq -n --arg l "$1" '{number:7,url:"https://github.com/FullFran/bifrost/issues/7",title:"agy: spawn bifrost ENOENT",
    body:"Every agy run fails.",labels:[{name:"bug"},{name:$l}]}' >"$FAKE_GH_DIR/issue.json"
  jq -n --arg old "$(design_body "${good/node --test/OLD}")" --arg new "$(design_body "$2")" '[[
    {id:1,html_url:"u1",updated_at:"2026-11-09T00:00:00Z",body:"just chatting"},
    {id:2,html_url:"u2",updated_at:"2026-11-09T01:00:00Z",body:$old}],[
    {id:3,html_url:"https://github.com/FullFran/bifrost/issues/7#issuecomment-3",updated_at:"2026-11-10T02:00:00Z",body:$new}]]' \
    >"$FAKE_GH_DIR/comments.json"
}
new_checkout() { # new_checkout NAME -> clone of a bare origin with main
  local origin="$scratch/$1-origin.git" src; src="$(new_repo "$1-src")"
  git clone -q --bare "$src" "$origin" && git clone -q "$origin" "$scratch/$1" && printf '%s' "$scratch/$1"
}
collect() { # collect CHECKOUT OUT -> sets out, code
  out="$("$factory" collect --repo FullFran/bifrost --issue 7 --checkout "$1" --out "$2" 2>&1)"
  code=$?
}
setup_gh factory:ready "$good"
co="$(new_checkout collect-ok)"
collect "$co" "$scratch/collect-ok-out"
ctx="$scratch/collect-ok-out/context.json"
check "collect: ready issue with a valid design exits 0" '[ "$code" = 0 ] && grep -q "COLLECT: status=READY" <<<"$out"'
check "collect: pins the latest design comment by id, url, sha256 and updated_at" \
  '[ "$(jq -c .design_comment "$ctx")" = "$(jq -nc --arg s "$(jq -r ".[1][0].body" "$FAKE_GH_DIR/comments.json" | tr -d "\n" | head -c0; jq -j ".[1][0].body" "$FAKE_GH_DIR/comments.json" | sha256sum | cut -d" " -f1)" "{id:3,url:\"https://github.com/FullFran/bifrost/issues/7#issuecomment-3\",sha256:\$s,updated_at:\"2026-11-10T02:00:00Z\"}")" ]'
check "collect: context carries repository, issue, done_when and expected_files" \
  '[ "$(jq -c "[.repository,.issue.number,.issue.url,.done_when,.expected_files]" "$ctx")" = "[\"FullFran/bifrost\",7,\"https://github.com/FullFran/bifrost/issues/7\",\"test -f fixed.txt\",[\"pi/runtime.mjs\",\"pi/bifrost.test.mjs\"]]" ]'
check "collect: writes the design and issue texts next to the context" \
  'grep -q "Resolve the bifrost binary" "$scratch/collect-ok-out/design.md" && grep -q "Every agy run fails." "$scratch/collect-ok-out/issue.md" && grep -q "agy: spawn bifrost ENOENT" "$scratch/collect-ok-out/issue.md"'
check "collect: checks out factory/7 from origin's default branch" \
  '[ "$(git -C "$co" rev-parse --abbrev-ref HEAD)" = factory/7 ] && [ "$(git -C "$co" rev-parse HEAD)" = "$(git -C "$co" rev-parse origin/main)" ]'
check "collect: a design without slice writes slice false to context.json" '[ "$(jq .slice "$ctx")" = false ]'
check "collect: the context is accepted by run" \
  'out="$("$factory" run --spec "$scratch/spec.json" --repo "$co" --context "$ctx" 2>&1)"; grep -q "RUN: id=.* task=FullFran/bifrost#7" <<<"$out"'
collect "$co" "$scratch/collect-again"
check "collect: refuses when factory/7 already exists" '[ "$code" = 2 ] && grep -q "branch factory/7 already exists" <<<"$out"'

setup_gh other "$good"
collect "$(new_checkout collect-nolabel)" "$scratch/o1"
check "collect: without factory:ready the issue is not ready (exit 1)" \
  '[ "$code" = 1 ] && grep -q "COLLECT: status=NOT_READY reason=missing label factory:ready" <<<"$out" && [ ! -e "$scratch/o1/context.json" ]'
not_ready() { # not_ready NAME DESIGN_JSON EXPECTED_REASON
  setup_gh factory:ready "$2"
  collect "$(new_checkout "collect-$1")" "$scratch/out-$1"
  want="$3"
  check "collect: $1 is not ready" '[ "$code" = 1 ] && grep -qF "$want" <<<"$out" && grep -q "COLLECT: status=NOT_READY" <<<"$out"'
}
not_ready unknown-key "${good/\"issue\": 7/\"issue\": 7, \"extra\": 1}" 'unknown field "extra"'
not_ready no-done-when "${good/\"done_when\": \"test -f fixed.txt\", /}" 'done_when'
not_ready wrong-issue "${good/\"issue\": 7/\"issue\": 8}" 'design is for issue 8'
not_ready absolute-path "${good/pi\/runtime.mjs/\/etc\/passwd}" 'expected_files entry "/etc/passwd"'
not_ready dotdot-path "${good/pi\/runtime.mjs/pi\/..\/..\/x}" 'expected_files entry "pi/../../x"'
not_ready protected-path "${good/pi\/runtime.mjs/gates\/gate.sh}" 'expected_files entry "gates/gate.sh"'
not_ready bad-json '{"schema_version": ' 'design block is not valid JSON'
setup_gh factory:ready "${good/\"issue\": 7/\"issue\": 7, \"slice\": true}"
co="$(new_checkout collect-slice)"
collect "$co" "$scratch/out-slice"
check "collect: a design with slice true writes slice true to context.json" \
  '[ "$code" = 0 ] && [ "$(jq .slice "$scratch/out-slice/context.json")" = true ]'
setup_gh factory:ready "${good/\"issue\": 7/\"issue\": 7, \"slice\": \"yes\"}"
collect "$(new_checkout collect-slice-str)" "$scratch/out-slice-str"
check "collect: a non-boolean slice is NOT_READY" \
  '[ "$code" = 1 ] && grep -qF slice <<<"$out" && grep -q "COLLECT: status=NOT_READY" <<<"$out" && [ ! -e "$scratch/out-slice-str/context.json" ]'

# The design's done_when must fail before any change, or it proves nothing.
setup_gh factory:ready "${good/test -f fixed.txt/true}"
co="$(new_checkout collect-green)"
collect "$co" "$scratch/out-green"
check "collect: a done_when that already passes at base is not ready" \
  '[ "$code" = 1 ] && grep -q "COLLECT: status=NOT_READY reason=done_when already passes before any change" <<<"$out"'
check "collect: a rejected design leaves no branch and no context" \
  '! git -C "$co" rev-parse --verify --quiet refs/heads/factory/7 >/dev/null && [ ! -e "$scratch/out-green/context.json" ] && [ "$(git -C "$co" rev-parse --abbrev-ref HEAD)" = main ]'
setup_gh factory:ready "${good/test -f fixed.txt/no-such-command-xyz}"
collect "$(new_checkout collect-127)" "$scratch/out-127"
check "collect: a done_when that cannot run is not ready" \
  '[ "$code" = 1 ] && grep -q "COLLECT: status=NOT_READY reason=done_when cannot run (exit 127)" <<<"$out"'
setup_gh factory:ready "${good/test -f fixed.txt/touch junk.txt; test -f fixed.txt}"
co="$(new_checkout collect-junk)"
collect "$co" "$scratch/out-junk"
check "collect: the check leaves the checkout clean" \
  '[ "$code" = 0 ] && [ -z "$(git -C "$co" status --porcelain)" ] && grep -q "COLLECT: status=READY" <<<"$out"'
check "collect: a ready design reports the failing done_when it checked" \
  'grep -q "COLLECT: check=done_when status=RED exit=1" <<<"$out"'

# --- misconfiguration and portability ----------------------------------------

echo '{"factory": "test", "nodes": [{"id": "x", "kind": "code", "command": ["true"], "retry": "nope"}]}' >"$scratch/bad.json"
run "$(new_repo bad)" "$scratch/bad.json"
check "spec: an invalid spec exits 2 with MISCONFIGURED" '[ "$code" = 2 ] && grep -q "RUN: status=MISCONFIGURED" <<<"$out"'
echo '{"factory": "test", "nodes": [{"id": "x", "kind": "code", "command": ["true"], "readonly": true}]}' >"$scratch/typo.json"
run "$(new_repo typo)" "$scratch/typo.json"
check "spec: an unknown field (a misspelt guard) is rejected" '[ "$code" = 2 ] && grep -q "unknown field" <<<"$out"'
run "$(new_repo bad-id)" "$scratch/spec.json" --run-id ..
check "spec: run id .. is rejected" '[ "$code" = 2 ] && grep -q "run id must match" <<<"$out"'
repo="$(new_repo dirty)"
echo wip >>"$repo/README.md"
run "$repo" "$scratch/spec.json"
check "spec: a new run refuses a dirty target tree" '[ "$code" = 2 ] && grep -q "uncommitted changes" <<<"$out"'
check "portability: no laptop paths in the runner" '! grep -rnE "/home/|/Users/|~/" "$here/cmd" "$here/internal"'

# --- model -------------------------------------------------------------------

cat >"$scratch/spec-model.json" <<'EOF'
{"factory": "test", "nodes": [
  {"id": "fast", "kind": "agent", "prompt_file": "implement.md", "model": "sonnet"},
  {"id": "plain", "kind": "agent", "prompt_file": "implement.md"}
]}
EOF
: >"$FAKE_LOG"
run "$(new_repo model)" "$scratch/spec-model.json"
check "model: a node model reaches the engine and an unset model adds no flag" \
  '[ "$code" = 0 ] && grep "^ARGV:" "$FAKE_LOG" | sed -n 1p | grep -qF "[--no-session-persistence] [--model] [sonnet]" && [ "$(grep -c "^ARGV:" "$FAKE_LOG")" = 2 ] && ! grep "^ARGV:" "$FAKE_LOG" | sed -n 2p | grep -qF "[--model]"'
cat >"$scratch/spec-model-bad.json" <<'EOF'
{"factory": "test", "nodes": [
  {"id": "fast", "kind": "agent", "prompt_file": "implement.md", "model": "--dangerously-skip-permissions"}
]}
EOF
: >"$FAKE_LOG"
run "$(new_repo model-bad)" "$scratch/spec-model-bad.json"
check "model: an invalid model is a spec error" \
  '[ "$code" = 2 ] && grep -q "RUN: status=MISCONFIGURED" <<<"$out" && grep -q "agent node fast: model" <<<"$out" && ! grep -q "unknown field" <<<"$out" && [ ! -s "$FAKE_LOG" ]'

# --- otlp ---------------------------------------------------------------------

(cd "$here" && go build -o "$scratch/otlp-receiver" ./tests/otlp-receiver) || { printf 'FAIL go build otlp-receiver\n'; exit 1; }
start_receiver() { # start_receiver FILE -> sets receiver_port and receiver_pid
  local stdout="$scratch/receiver-$RANDOM.out"
  "$scratch/otlp-receiver" "$1" >"$stdout" 2>&1 &
  receiver_pid=$!
  receiver_pids+=("$receiver_pid")
  receiver_port=""
  for _ in $(seq 1 100); do
    receiver_port="$(sed -n 's/^LISTEN //p' "$stdout")"
    [ -n "$receiver_port" ] && return 0
    sleep 0.05
  done
  return 1
}
otlp_body() { cut -d' ' -f4- "$scratch/otlp.lines"; }
: >"$scratch/otlp.lines"
start_receiver "$scratch/otlp.lines" || { printf 'FAIL otlp receiver did not start\n'; exit 1; }

repo="$(new_repo otlp)"
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$receiver_port/" run "$repo" "$scratch/spec.json"
check "otlp: a run exports one trace with a span per node attempt" \
  '[ "$code" = 0 ] && grep -q "RUN: status=COMPLETE" <<<"$out" && ! grep -q "^OTLP:" <<<"$out" &&
   [ "$(wc -l <"$scratch/otlp.lines" | tr -d " ")" = 1 ] &&
   [ "$(cut -d" " -f1-3 "$scratch/otlp.lines")" = "POST /v1/traces application/json" ] &&
   [ "$(otlp_body | jq "[.resourceSpans[].scopeSpans[].spans[]] | length")" = 3 ] &&
   [ "$(otlp_body | jq -r "[.resourceSpans[].scopeSpans[].spans[] | select(has(\"parentSpanId\") | not) | .name] | join(\",\")")" = "invoke_workflow test" ] &&
   root="$(otlp_body | jq -r ".resourceSpans[].scopeSpans[].spans[] | select(has(\"parentSpanId\") | not) | .spanId")" &&
   [ "$(otlp_body | jq -r --arg r "$root" "[.resourceSpans[].scopeSpans[].spans[] | select(.parentSpanId == \$r) | .spanId] | join(\",\")")" = "$(receipt "$repo" 1 | jq -r .telemetry.span_id),$(receipt "$repo" 2 | jq -r .telemetry.span_id)" ] &&
   [ "$(otlp_body | jq -r "[.resourceSpans[].scopeSpans[].spans[] | .traceId] | unique | join(\",\")")" = "$(receipt "$repo" 1 | jq -r .telemetry.trace_id)" ]'

: >"$scratch/otlp.lines"
run "$(new_repo otlp-none)" "$scratch/spec.json"
check "otlp: no endpoint, no export" \
  '[ "$code" = 0 ] && grep -q "RUN: status=COMPLETE" <<<"$out" && ! grep -q "OTLP" <<<"$out" && [ ! -s "$scratch/otlp.lines" ]'

start_receiver "$scratch/otlp-closed.lines" || { printf 'FAIL otlp receiver did not start\n'; exit 1; }
closed_port="$receiver_port"
kill "$receiver_pid" 2>/dev/null; wait "$receiver_pid" 2>/dev/null
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$closed_port/" run "$(new_repo otlp-down)" "$scratch/spec.json"
check "otlp: endpoint down, the run completes with one warning" \
  '[ "$code" = 0 ] && grep -q "RUN: status=COMPLETE" <<<"$out" && [ "$(grep -c "^OTLP: export failed:" <<<"$out")" = 1 ]'

printf 'RESULT: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
