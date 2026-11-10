#!/usr/bin/env bash
# Contract tests for `factory panel` (gentle-factory#15), through its public CLI and JSON API.
# Receipts are minimal in-toto statements; the panel serves them on a loopback port picked by
# the kernel and must never write to a runs dir.
# Needs bash, go, curl and jq. Exit 77 when a tool is missing.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in go jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-panel-test.XXXXXX")"
panel_pid=""
cleanup() { [ -n "$panel_pid" ] && kill "$panel_pid" 2>/dev/null; rm -rf "$scratch"; }
trap cleanup EXIT
factory="$scratch/factory"
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${out:-}" ] && printf '  out: %s\n' "${out//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

add_receipt() { # add_receipt RUNS RUN NODE ATTEMPT STATUS TERMINAL_REASON COST NOTES [SIGNATURE]
  local dir="$1/$2/receipts"
  mkdir -p "$dir" "$1/$2/logs" "$1/$2/feedback"
  local n=$(($(ls "$dir" | wc -l) + 1))
  jq -n --arg run "$2" --arg id "$3" --argjson att "$4" --arg st "$5" --arg tr "$6" --argjson cost "$7" \
    --arg notes "$8" --arg sig "${9:-}" \
    '{_type:"https://in-toto.io/Statement/v1",subject:[],predicateType:"x",predicate:{version:"0.1.0",run_id:$run,
      step:{node_id:$id,node_kind:"agent",attempt:$att},
      references:{repository:"FullFran/dotfiles",issue:{number:55,url:"https://github.com/FullFran/dotfiles/issues/55"},
        vcs:{base_commit:"aaaa",head_commit:"bbbb"}},
      execution:{engine:"claude-code",tools_allowed:[],caps:{timeout_seconds:1}},
      telemetry:{total_cost_usd:$cost,duration_ms:1000,num_turns:3,request_model:"claude-fake-1",
        tokens:{input_tokens:40,output_tokens:20,total_tokens:60}},
      outcome:{status:$st,terminal_reason:$tr},notes:$notes,failure_signature:$sig}}' \
    >"$dir/$(printf '%04d' "$n")-$3-$4.json"
}

runs="$scratch/runs"
other="$scratch/other-runs"
# complete, with one tests -> implement retry and a PR
add_receipt "$runs" rc plan 1 success completed 0.25 ""
add_receipt "$runs" rc implement 1 success completed 0.5 ""
add_receipt "$runs" rc tests 1 failure step_failed 0 $'reason: FACTORY_GATES: status=RED\nmore' sig1
add_receipt "$runs" rc implement 2 success completed 0.5 ""
add_receipt "$runs" rc tests 2 success completed 0 ""
add_receipt "$runs" rc review 1 success completed 0.25 ""
add_receipt "$runs" rc output 1 success completed 0 ""
printf 'noise\nPR: https://github.com/FullFran/dotfiles/pull/60\n' >"$runs/rc/logs/output-1.log"
printf 'implement attempt 2 log\n' >"$runs/rc/logs/implement-2.log"
mkdir -p "$runs/rc/outputs"
printf 'IMPLEMENT ANSWER\n' >"$runs/rc/outputs/implement.md"
printf 'FACTORY_GATES: status=RED\n' >"$runs/rc/feedback/implement.txt"
# parked on a question
add_receipt "$runs" rd plan 1 needs_decision user_decision_required 0.1 $'reason: Which database should it use?\nraw'
# stopped: implement has no retry edge
add_receipt "$runs" rs plan 1 success completed 0.1 ""
add_receipt "$runs" rs implement 1 failure max_turns 0.4 $'reason: ran out of turns'
# running: no terminal state yet
add_receipt "$other" rr plan 1 success completed 0.1 ""
add_receipt "$other" rr implement 1 success completed 0.2 ""
# running: tests failed and its retry of implement has not started yet
add_receipt "$other" rw plan 1 success completed 0.1 ""
add_receipt "$other" rw implement 1 success completed 0.2 ""
add_receipt "$other" rw tests 1 failure step_failed 0 $'reason: red' sigA
# stopped: tests failed twice the same way, as the runner stops it
add_receipt "$other" rx plan 1 success completed 0.1 ""
add_receipt "$other" rx implement 1 success completed 0.2 ""
add_receipt "$other" rx tests 1 failure step_failed 0 $'reason: red' sigA
add_receipt "$other" rx implement 2 success completed 0.2 ""
add_receipt "$other" rx tests 2 failure step_failed 0 $'reason: red' sigA

fingerprint() { (cd "$scratch" && find runs other-runs -printf '%p %s %T@ %m\n' | sort && find runs other-runs -type f -exec sha256sum {} + | sort); }
before="$(fingerprint)"

# --- refusals ----------------------------------------------------------------
out="$("$factory" panel --addr 0.0.0.0:0 --runs-dir "$runs" 2>&1)"; code=$?
check "non-loopback address is refused with exit 2" '[ "$code" = 2 ] && grep -q "PANEL: status=MISCONFIGURED" <<<"$out" && grep -q "allow-remote" <<<"$out"'
out="$("$factory" panel --addr :0 --runs-dir "$runs" 2>&1)"; code=$?
check "an address on every interface is refused with exit 2" '[ "$code" = 2 ] && grep -q "allow-remote" <<<"$out"'
out="$("$factory" panel --runs-dir "$scratch/missing" --addr 127.0.0.1:0 2>&1)"; code=$?
check "a missing runs dir is refused with exit 2" '[ "$code" = 2 ] && grep -q "PANEL: status=MISCONFIGURED" <<<"$out"'
out="$("$factory" help 2>&1)"
check "help documents the panel command" 'grep -q "factory panel" <<<"$out"'

# --- serve -------------------------------------------------------------------
"$factory" panel --addr 127.0.0.1:0 --runs-dir "$runs" --runs-dir "$other" >"$scratch/panel.out" 2>&1 &
panel_pid=$!
url=""
for _ in $(seq 1 50); do
  url="$(sed -n 's/^PANEL: url=\(http[^ ]*\).*/\1/p' "$scratch/panel.out")"
  [ -n "$url" ] && break
  sleep 0.1
done
check "panel prints its loopback url" '[[ "$url" == http://127.0.0.1:* ]]'
api() { curl -fsS "${url%/}$1"; }

out="$(api /api/runs)"
status_of() { jq -r --arg id "$1" '.runs[] | select(.run_id==$id) | .status' <<<"$out"; }
check "runs: every run of both runs dirs is listed" '[ "$(jq ".runs | length" <<<"$out")" = 6 ]'
check "runs: complete, needs_decision, stopped and running" \
  '[ "$(status_of rc)" = complete ] && [ "$(status_of rd)" = needs_decision ] && [ "$(status_of rs)" = stopped ] && [ "$(status_of rr)" = running ]'
check "runs: repository, issue, attempts and cost" \
  '[ "$(jq -c ".runs[] | select(.run_id==\"rc\") | [.repository,.issue.number,.attempts,.cost_usd]" <<<"$out")" = "[\"FullFran/dotfiles\",55,7,1.5]" ]'
check "runs: totals across runs reuse the summary numbers" \
  '[ "$(jq -c "[.totals.runs,.totals.attempts,.totals.failures,.totals.decisions,.totals.retries]" <<<"$out")" = "[6,20,5,1,4]" ]'
check "runs: a checker failure with its retry pending is running, the same failure twice is stopped" \
  '[ "$(status_of rw)" = running ] && [ "$(status_of rx)" = stopped ] &&
   [ "$(jq -r ".runs[] | select(.run_id==\"rx\") | .terminal_reason" <<<"$out")" = same_failure_signature ]'

rc_path="$(jq -r '.runs[] | select(.run_id=="rc") | .path' <<<"$out")"
out="$(api "/api/runs/$rc_path")"
check "run: graph follows the spec order" '[ "$(jq -c "[.graph.nodes[].id]" <<<"$out")" = "[\"plan\",\"implement\",\"tests\",\"review\",\"output\"]" ]'
check "run: the tests -> implement retry edge happened once" \
  '[ "$(jq ".graph.edges[] | select(.kind==\"retry\" and .from==\"tests\" and .to==\"implement\") | .taken" <<<"$out")" = 1 ]'
check "run: the review -> implement retry edge exists but was not taken" \
  '[ "$(jq ".graph.edges[] | select(.kind==\"retry\" and .from==\"review\" and .to==\"implement\") | .taken" <<<"$out")" = 0 ]'
check "run: implement shows two attempts and the last node is marked" \
  '[ "$(jq ".graph.nodes[] | select(.id==\"implement\") | .attempts | length" <<<"$out")" = 2 ] && [ "$(jq -r .graph.current <<<"$out")" = output ]'
check "run: PR link and per-node totals" \
  '[ "$(jq -r .run.pr_url <<<"$out")" = https://github.com/FullFran/dotfiles/pull/60 ] && [ "$(jq .nodes.implement.retries <<<"$out")" = 1 ]'

out="$(api "/api/runs/$rc_path/attempts/implement/2")"
check "attempt: receipt, output, log and the feedback that sent it back" \
  '[ "$(jq -r .receipt.telemetry.request_model <<<"$out")" = claude-fake-1 ] && grep -q "IMPLEMENT ANSWER" <<<"$(jq -r .output <<<"$out")" &&
   grep -q "attempt 2 log" <<<"$(jq -r .log <<<"$out")" && [ "$(jq -r .sent_back_by.node <<<"$out")" = tests ] &&
   grep -q "status=RED" <<<"$(jq -r .feedback <<<"$out")"'

out="$(api /api/decisions)"
check "decisions: the parked run with its question and issue" \
  '[ "$(jq ".decisions | length" <<<"$out")" = 1 ] && [ "$(jq -r ".decisions[0].run_id" <<<"$out")" = rd ] &&
   [ "$(jq -r ".decisions[0].question" <<<"$out")" = "Which database should it use?" ] && [ "$(jq ".decisions[0].issue.number" <<<"$out")" = 55 ] &&
   [ "$(jq ".decisions[0].age_seconds >= 0" <<<"$out")" = true ]'

code="$(curl -s -o /dev/null -w '%{http_code}' "${url%/}/api/runs/0/nope")"
check "an unknown run is a 404" '[ "$code" = 404 ]'
code="$(curl -s -o /dev/null -w '%{http_code}' "${url%/}/api/runs/0/rc/attempts/..%2F..%2Fetc/1")"
check "a node id outside [a-z0-9_-] is refused" '[ "$code" = 404 ] || [ "$code" = 400 ]'
out="$(curl -fsS "$url")"
check "the UI is served from the binary" 'grep -q "gentle-factory" <<<"$out" && grep -q "app.js" <<<"$out"'
out="$(curl -fsS "${url%/}/app.js")"
check "the UI script is served" 'grep -q "/api/decisions" <<<"$out"'

kill "$panel_pid" 2>/dev/null; wait "$panel_pid" 2>/dev/null; panel_pid=""
check "nothing was written to the runs dirs" '[ "$before" = "$(fingerprint)" ]'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
