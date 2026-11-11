#!/usr/bin/env bash
# Contract tests for the design caps (#51): budget_cap_usd, turn_cap and timeout_seconds
# from the design block lower each node's caps and never raise them.
# Agent nodes run against a claude double; no model is called and nothing is spent.
# Needs bash, git, go and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in git go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_HEADERS

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-design-caps-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
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
# claude double: records argv, edits impl.txt and reports success.
if [ "${1:-}" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
cat >/dev/null
{ printf 'ARGV:'; printf ' [%s]' "$@"; printf '\n'; } >>"${FAKE_LOG:?}"
echo "attempt $FACTORY_ATTEMPT" >impl.txt
printf '%s\n' '{"type":"system","subtype":"init"}'
jq -cn '{type:"result",subtype:"success",is_error:false,result:"done",num_turns:1,
  total_cost_usd:0.01,usage:{input_tokens:1,output_tokens:1}}'
EOF
chmod +x "$scratch/bin/claude"
export FACTORY_CLAUDE_BIN="$scratch/bin/claude"
export FAKE_LOG="$scratch/claude.log"
export FACTORY_KILL_GRACE=1

new_repo() { # new_repo NAME -> path of a clean repo with one commit
  local repo="$scratch/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  echo base >"$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
  printf '%s' "$repo"
}

write_context() { # write_context FILE EXTRA_JSON_FIELDS
  cat >"$1" <<EOF
{"repository": "example/repo",
 "issue": {"number": 51, "url": "https://github.com/example/repo/issues/51"},
 "design_comment": {"id": 1, "url": "https://github.com/example/repo/issues/51#issuecomment-1",
   "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
   "updated_at": "2026-11-10T01:15:30Z"}$2}
EOF
}

echo "Implement the change described in the issue." >"$scratch/implement.md"
cat >"$scratch/spec.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "implement", "kind": "agent", "prompt_file": "implement.md",
   "tools": ["Read", "Edit"], "max_turns": 5, "max_budget_usd": 0.5, "timeout_seconds": 600}]}
EOF
cat >"$scratch/spec-slow.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "slow", "kind": "code", "command": ["sleep", "30"], "timeout_seconds": 30}]}
EOF

run() { # run SPEC CONTEXT NAME -> sets out, code, repo
  repo="$(new_repo "$3")"
  : >"$FAKE_LOG"
  out="$("$factory" run --spec "$1" --repo "$repo" --context "$2" 2>&1)"
  code=$?
}
caps() { # caps -> execution.caps of the only receipt of the current repo
  jq -c .predicate.execution.caps "$(find "$repo/odd/runs" -path '*/receipts/*.json' | sort | head -n1)"
}
argv_has() { grep -q -- "$1" "$FAKE_LOG"; }

# --- 1. turn_cap below the node's max_turns ---------------------------------

write_context "$scratch/ctx-turns-low.json" ', "turn_cap": 3'
run "$scratch/spec.json" "$scratch/ctx-turns-low.json" turns-low
check "turn_cap below max_turns: claude gets --max-turns 3 and the receipt records 3" \
  '[ "$code" = 0 ] && argv_has "\[--max-turns\] \[3\] " && [ "$(caps | jq .max_turns)" = 3 ]'

# --- 2. turn_cap above the node's max_turns ---------------------------------

write_context "$scratch/ctx-turns-high.json" ', "turn_cap": 50'
run "$scratch/spec.json" "$scratch/ctx-turns-high.json" turns-high
check "turn_cap above max_turns: the node's 5 is kept" \
  '[ "$code" = 0 ] && argv_has "\[--max-turns\] \[5\] " && [ "$(caps | jq .max_turns)" = 5 ]'

# --- 3. budget_cap_usd below and above the node's max_budget_usd ------------

write_context "$scratch/ctx-budget-low.json" ', "budget_cap_usd": 0.2'
run "$scratch/spec.json" "$scratch/ctx-budget-low.json" budget-low
check "budget_cap_usd below max_budget_usd: claude gets --max-budget-usd 0.2 and the receipt records 0.2" \
  '[ "$code" = 0 ] && argv_has "\[--max-budget-usd\] \[0.2\] " && [ "$(caps | jq .max_budget_usd)" = 0.2 ]'
write_context "$scratch/ctx-budget-high.json" ', "budget_cap_usd": 9.0'
run "$scratch/spec.json" "$scratch/ctx-budget-high.json" budget-high
check "budget_cap_usd above max_budget_usd: the node's 0.5 is kept" \
  '[ "$code" = 0 ] && argv_has "\[--max-budget-usd\] \[0.5\] " && [ "$(caps | jq .max_budget_usd)" = 0.5 ]'

# --- 4. timeout_seconds below a code node's timeout -------------------------

write_context "$scratch/ctx-timeout.json" ', "timeout_seconds": 1'
start=$SECONDS
run "$scratch/spec-slow.json" "$scratch/ctx-timeout.json" timeout-low
check "timeout_seconds below the node's: the code node stops as timeout and the receipt records 1" \
  '[ "$code" = 1 ] && grep -q "node=slow reason=timeout" <<<"$out" && [ $((SECONDS - start)) -lt 10 ] && [ "$(caps | jq .timeout_seconds)" = 1 ]'
write_context "$scratch/ctx-timeout-agent.json" ', "timeout_seconds": 60'
run "$scratch/spec.json" "$scratch/ctx-timeout-agent.json" timeout-agent
check "timeout_seconds below an agent node's: the receipt records 60" \
  '[ "$code" = 0 ] && [ "$(caps | jq .timeout_seconds)" = 60 ]'

# --- 5. no caps: previous behaviour pinned -----------------------------------

write_context "$scratch/ctx-none.json" ''
run "$scratch/spec.json" "$scratch/ctx-none.json" no-caps
check "no caps: arguments and receipt caps are the node's" \
  '[ "$code" = 0 ] && argv_has "\[--max-turns\] \[5\] \[--max-budget-usd\] \[0.5\] " && [ "$(caps)" = "{\"max_turns\":5,\"max_budget_usd\":0.5,\"timeout_seconds\":600}" ]'

# --- 6. collect copies the caps into context.json ---------------------------

cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh double: serves issue 7 of example/repo from $FAKE_GH_DIR.
case "$1 $2" in
  "issue view") cat "$FAKE_GH_DIR/issue.json" ;;
  "api repos/example/repo/issues/7/comments") cat "$FAKE_GH_DIR/comments.json" ;;
  *) echo "gh double: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$scratch/bin/gh"
export FACTORY_GH_BIN="$scratch/bin/gh"
export FAKE_GH_DIR="$scratch/gh"
mkdir -p "$FAKE_GH_DIR"
design='{"schema_version": "1.0", "issue": 7, "ready_signal": "factory:ready", "done_when": "test -f fixed.txt",
 "expected_files": ["a.txt"], "budget_cap_usd": 1.25, "turn_cap": 12, "timeout_seconds": 300}'
jq -n '{number:7,url:"https://github.com/example/repo/issues/7",title:"a title",body:"a body",
  labels:[{name:"factory:ready"}]}' >"$FAKE_GH_DIR/issue.json"
jq -n --arg b "$(printf '<!-- factory-design:v1\n%s\n-->\n\n# Design\n' "$design")" \
  '[[{id:3,html_url:"https://github.com/example/repo/issues/7#issuecomment-3",updated_at:"2026-11-10T02:00:00Z",body:$b}]]' \
  >"$FAKE_GH_DIR/comments.json"
src="$(new_repo collect-src)"
git clone -q --bare "$src" "$scratch/collect-origin.git" && git clone -q "$scratch/collect-origin.git" "$scratch/collect"
out="$("$factory" collect --repo example/repo --issue 7 --checkout "$scratch/collect" --out "$scratch/collect-out" 2>&1)"
code=$?
check "collect: copies budget_cap_usd, turn_cap and timeout_seconds into context.json" \
  '[ "$code" = 0 ] && [ "$(jq -c "[.budget_cap_usd,.turn_cap,.timeout_seconds]" "$scratch/collect-out/context.json")" = "[1.25,12,300]" ]'

printf 'RESULT: passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
