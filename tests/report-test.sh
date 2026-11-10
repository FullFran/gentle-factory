#!/usr/bin/env bash
# Contract tests for `factory report` (gentle-factory#15), through its public CLI.
# Receipts are written as minimal in-toto statements; gh is a double that records its calls.
# Needs bash, go and jq. Exit 77 when a tool is missing.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-report-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
factory="$scratch/factory"
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${out:-}" ] && printf '  out: %s\n' "${out//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

# gh double: records every call; `issue comment` stores the body and makes it visible to later
# comment listings, so a second report sees the first one.
mkdir -p "$scratch/bin"
cat >"$scratch/bin/gh" <<'EOF2'
#!/usr/bin/env bash
d="${FAKE_GH_DIR:?}"
printf '%s\n' "$*" >>"$d/calls"
case "$1 $2" in
  "api repos/FullFran/dotfiles/issues/55/comments") cat "$d/comments.json" ;;
  "issue comment")
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && body="$2"; shift; done
    cp "$body" "$d/posted-$(ls "$d" | grep -c '^posted-').md"
    jq --rawfile b "$body" '.[0] += [{body:$b}]' "$d/comments.json" >"$d/c.tmp" && mv "$d/c.tmp" "$d/comments.json" ;;
  "issue edit"|"label create") ;;
  *) echo "gh double: unexpected $*" >&2; exit 1 ;;
esac
EOF2
chmod +x "$scratch/bin/gh"
export FACTORY_GH_BIN="$scratch/bin/gh"
unset FACTORY_NOTIFY_CMD

cat >"$scratch/context.json" <<'EOF2'
{"repository": "FullFran/dotfiles",
 "issue": {"number": 55, "url": "https://github.com/FullFran/dotfiles/issues/55"},
 "design_comment": {"id": 123, "url": "https://github.com/FullFran/dotfiles/issues/55#issuecomment-123",
   "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
   "updated_at": "2026-11-10T01:15:30Z"}}
EOF2

setup() { # setup NAME -> fresh runs dir $runs and gh double dir
  runs="$scratch/$1-runs"; mkdir -p "$runs/r1/receipts" "$runs/r1/logs"
  export FAKE_GH_DIR="$scratch/$1-gh"; mkdir -p "$FAKE_GH_DIR"
  echo '[[]]' >"$FAKE_GH_DIR/comments.json"
  n=0
}
add_receipt() { # add_receipt NODE ATTEMPT STATUS TERMINAL_REASON COST NOTES
  n=$((n + 1))
  jq -n --arg node "$2" --arg id "$1" --argjson att "$2" --arg st "$3" --arg tr "$4" --argjson cost "$5" --arg notes "$6" \
    '{_type:"https://in-toto.io/Statement/v1",subject:[],predicateType:"x",predicate:{version:"0.1.0",run_id:"r1",
      step:{node_id:$id,node_kind:"agent",attempt:$att},
      execution:{engine:"claude-code",command:["/home/someone/bin/claude","-p"],tools_allowed:[],caps:{timeout_seconds:1}},
      telemetry:{total_cost_usd:$cost,duration_ms:1},outcome:{status:$st,terminal_reason:$tr},notes:$notes}}' \
    | jq --arg id "$1" --argjson att "$2" '.predicate.step.node_id=$id | .predicate.step.attempt=$att' \
    >"$runs/r1/receipts/$(printf '%04d' "$n")-$1-$2.json"
}
report() { # report [context] -> sets out, code
  out="$("$factory" report --runs-dir "$runs" --run-id r1 --context "${1:-$scratch/context.json}" 2>&1)"
  code=$?
}
posted() { cat "$FAKE_GH_DIR/posted-0.md" 2>/dev/null; }
count_posts() { ls "$FAKE_GH_DIR" | grep -c '^posted-'; }

# --- complete ---------------------------------------------------------------
setup complete
add_receipt plan 1 success completed 0.25 "wrote /home/someone/work/plan.md"
add_receipt implement 1 failure step_failed 0.5 $'reason: tests red\nsee /home/someone/work/log'
add_receipt implement 2 success completed 0.25 ""
printf 'noise\nPR: https://github.com/FullFran/dotfiles/pull/60\n' >"$runs/r1/logs/output-1.log"
report
check "complete: exit 0 and REPORT line" '[ "$code" = 0 ] && grep -q "^REPORT: status=posted state=complete issue=FullFran/dotfiles#55$" <<<"$out"'
check "complete: one comment with the hidden marker" '[ "$(count_posts)" = 1 ] && grep -qF "<!-- factory-report:v1 run=r1 state=complete -->" <<<"$(posted)"'
check "complete: PR link, attempts and cost are present" 'grep -q "pull/60" <<<"$(posted)" && grep -q "Attempts: 3" <<<"$(posted)" && grep -q "1.00" <<<"$(posted)"'
check "complete: factory:ready is removed, nothing added" \
  'grep -q "^issue edit 55 .*--remove-label factory:ready" "$FAKE_GH_DIR/calls" && ! grep -q "add-label" "$FAKE_GH_DIR/calls"'

# --- idempotency ------------------------------------------------------------
: >"$FAKE_GH_DIR/calls"
report
check "idempotent: second report posts nothing" \
  '[ "$code" = 0 ] && grep -q "^REPORT: status=already-posted state=complete" <<<"$out" && [ "$(count_posts)" = 1 ] && ! grep -q "issue comment\|issue edit" "$FAKE_GH_DIR/calls"'

# --- needs_decision ---------------------------------------------------------
setup decision
add_receipt plan 1 needs_decision user_decision_required 0.25 $'reason: follow /home/someone/repo/link or copy it?\nraw'
export FACTORY_NOTIFY_CMD="$scratch/bin/notify"
cat >"$scratch/bin/notify" <<'EOF2'
#!/usr/bin/env bash
{ printf 'ARGS: %s\n' "$#"; cat; } >>"${NOTIFY_LOG:?}"
EOF2
chmod +x "$scratch/bin/notify"
export NOTIFY_LOG="$scratch/notify.log"; : >"$NOTIFY_LOG"
report
check "decision: exit 0 and state needs_decision" '[ "$code" = 0 ] && grep -q "state=needs_decision issue=FullFran/dotfiles#55" <<<"$out"'
check "decision: comment has node, question and the how-to-answer note" \
  'grep -q "plan" <<<"$(posted)" && grep -q "or copy it?" <<<"$(posted)" && grep -q "factory:ready" <<<"$(posted)"'
check "decision: label swap, label created if missing" \
  'grep -q "^label create factory:needs-decision -R FullFran/dotfiles" "$FAKE_GH_DIR/calls" && grep -q "^issue edit 55 -R FullFran/dotfiles --remove-label factory:ready --add-label factory:needs-decision" "$FAKE_GH_DIR/calls"'
check "decision: notify command ran once with the message on stdin and no arguments" \
  '[ "$(grep -c "^ARGS: 0" "$NOTIFY_LOG")" = 1 ] && grep -q "needs_decision" "$NOTIFY_LOG" && grep -q "FullFran/dotfiles#55" "$NOTIFY_LOG"'
check "decision: no absolute path in the comment or the notification" \
  '! grep -q "/home/" <<<"$(posted)" && ! grep -q "/home/" "$NOTIFY_LOG"'
unset FACTORY_NOTIFY_CMD

# --- stopped ----------------------------------------------------------------
setup stopped
add_receipt implement 1 failure step_failed 0.5 $'reason: gate red in /home/someone/work/x.go\nmore'
add_receipt implement 2 failure max_turns 0.5 $'reason: ran out at /home/someone/work/x.go:3\ncommand /home/someone/bin/claude'
report
check "stopped: state, node, terminal reason and reason" \
  '[ "$code" = 0 ] && grep -q "state=stopped" <<<"$out" && grep -q "implement" <<<"$(posted)" && grep -q "max_turns" <<<"$(posted)" && grep -q "ran out at" <<<"$(posted)"'
check "stopped: no absolute path, command or receipt content in the comment" \
  '! grep -q "/home/\|claude\|command" <<<"$(posted)"'
check "stopped: factory:ready removed, needs-decision not added" \
  'grep -q "remove-label factory:ready" "$FAKE_GH_DIR/calls" && ! grep -q "needs-decision" "$FAKE_GH_DIR/calls"'
check "no FACTORY_NOTIFY_CMD: report still succeeds" '[ "$code" = 0 ]'

# --- misconfiguration ---------------------------------------------------------
report "$scratch/missing.json"
check "missing context: exit 2" '[ "$code" = 2 ] && grep -q "REPORT: status=MISCONFIGURED" <<<"$out"'
out="$("$factory" report --runs-dir "$scratch/nothing" --run-id r1 --context "$scratch/context.json" 2>&1)"; code=$?
check "missing receipts: exit 2" '[ "$code" = 2 ]'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
