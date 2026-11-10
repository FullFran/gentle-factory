#!/usr/bin/env bash
# Contract tests for runner/factory.py, through its public CLI.
# Agent nodes run against a claude double; no model is called and nothing is spent.
# Needs bash, git, python3 and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$here/runner/factory.py"
for tool in git python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
validator=()
if command -v check-jsonschema >/dev/null 2>&1; then validator=(check-jsonschema)
elif command -v uvx >/dev/null 2>&1; then validator=(uvx -q check-jsonschema); fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-runner-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
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
case "${FAKE_MODE:-edit}" in
  edit) echo "attempt $FACTORY_ATTEMPT" >impl.txt ;;
  noop) : ;;
  fallo) result=$'lo he intentado\nFALLO: el diseño no dice qué hacer con los symlinks' ;;
  protected) echo "tampered" >>gates/gate.sh ;;
  receipts) for f in "${FAKE_RUNS:?}"/*/receipts/*.json; do echo ' ' >>"$f"; done; echo x >impl.txt ;;
esac
jq -n --arg r "$result" '{type:"result",subtype:"success",is_error:false,result:$r,num_turns:3,
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
{"repository": "FullFran/dotfiles",
 "issue": {"number": 55, "url": "https://github.com/FullFran/dotfiles/issues/55"},
 "design_comment": {"id": 123, "url": "https://github.com/FullFran/dotfiles/issues/55#issuecomment-123",
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
  out="$(python3 "$runner" run --spec "$2" --repo "$1" --context "$scratch/context.json" "${@:3}" 2>&1)"
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
  'grep -q "\[-p\] \[--output-format\] \[json\] \[--max-turns\] \[5\] \[--max-budget-usd\] \[0.5\]" "$FAKE_LOG"'
check "success: allowlist passed" 'grep -q "\[--allowedTools\] \[Read\] \[Edit\] \[Write\] \[Bash\]" "$FAKE_LOG"'
check "success: deny list passed" \
  'grep -q "\[--disallowedTools\] \[Bash(git push:\*)\] \[Bash(git tag:\*)\] \[Bash(git reset:\*)\] \[Bash(gh:\*)\]" "$FAKE_LOG"'
run_id="$(receipt "$repo" 1 | jq -r .run_id)"
check "success: identity reaches the agent (factory#6 attributes)" \
  'grep -q "OTEL: .*service.name=factory-test,factory.name=test,run.id=$run_id,task.id=FullFran/dotfiles#55,agent.engine=claude-code" "$FAKE_LOG"'
check "success: trace context reaches the agent and the receipt" \
  'grep -q "TRACEPARENT: 00-$(receipt "$repo" 1 | jq -r .telemetry.trace_id)-" "$FAKE_LOG"'
check "success: agent telemetry recorded from the engine JSON" \
  '[ "$(receipt "$repo" 1 | jq -c "[.telemetry.total_cost_usd,.telemetry.num_turns,.telemetry.tokens.total_tokens,.telemetry.request_model]")" = "[0.25,3,120,\"claude-fake-1\"]" ]'
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

# --- summary and cost recorded once ------------------------------------------

repo="$(new_repo summary)"
PASS_AT=2 run "$repo" "$scratch/spec.json"
PASS_AT=9 run "$repo" "$scratch/spec.json"
summary_json="$(python3 "$runner" summary --repo "$repo" --json)"
check "summary: cost recorded once per agent attempt (5 attempts x 0.25)" \
  '[ "$(jq -r ".nodes.implement.cost_usd" <<<"$summary_json")" = 1.25 ] && [ "$(jq -r ".nodes.verify.cost_usd" <<<"$summary_json")" = 0.0 ]'
check "summary: counts runs, failures and retries" \
  '[ "$(jq -c "[.runs,.nodes.verify.failures,.nodes.implement.retries]" <<<"$summary_json")" = "[2,4,3]" ]'
summary_text="$(python3 "$runner" summary --repo "$repo")"
check "summary: names the step that fails, retries and costs the most" \
  'grep -qx "MOST: failures=verify retries=implement cost=implement" <<<"$summary_text"'

# --- misconfiguration and portability ----------------------------------------

echo '{"factory": "test", "nodes": [{"id": "x", "kind": "code", "command": ["true"], "retry": "nope"}]}' >"$scratch/bad.json"
run "$(new_repo bad)" "$scratch/bad.json"
check "spec: an invalid spec exits 2 with MISCONFIGURED" '[ "$code" = 2 ] && grep -q "RUN: status=MISCONFIGURED" <<<"$out"'
check "portability: no laptop paths in the runner" '! grep -nE "/home/|/Users/|~/" "$runner"'

printf 'RESULT: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
