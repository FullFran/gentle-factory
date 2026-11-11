#!/usr/bin/env bash
# Contract tests for `factory status [--json]`: it reads the status file written by start and
# watch and prints it as JSON or as a short summary, through the public CLI.
# Needs bash, go and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in go jq sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-status-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"   # never the real home
status_file="$XDG_STATE_HOME/gentle-factory/status.json"
mkdir -p "$scratch/install"
factory="$scratch/install/factory"   # built outside the repository
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; [ -n "${out:-}" ] && printf '  out: %s\n' "${out//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }

# validate FILE: no error from the schema subset validator; a jq failure is never taken as valid.
validate() { local errs; errs="$(jq -r --slurpfile schema "$here/schemas/factory-status.schema.json" -f "$here/tests/jsonschema-subset.jq" "$1")" && [ -z "$errs" ]; }
# run_status ARGS...: stdout in $out, stderr in $err, exit code in $code.
run_status() { out="$("$factory" status "$@" 2>"$scratch/stderr")"; code=$?; err="$(cat "$scratch/stderr")"; }
put() { mkdir -p "$(dirname "$status_file")"; cat >"$status_file"; }
rid() { printf 'run_00000000-0000-0000-0000-%012d' "$1"; }

# --- 1. missing file -----------------------------------------------------------

run_status
check "missing: exit 1, MISSING on stderr, nothing on stdout" \
  '[ "$code" = 1 ] && [ "$err" = "STATUS: status=MISSING reason=no status file" ] && [ -z "$out" ]'

# --- 2. invalid JSON -----------------------------------------------------------

printf '{not json' | put
run_status
check "invalid: bad JSON gives exit 1, INVALID on stderr, nothing on stdout" \
  '[ "$code" = 1 ] && [ "$err" = "STATUS: status=INVALID reason=unreadable or unknown status file" ] && [ -z "$out" ]'

# --- 3. wrong schema_version and unknown field -----------------------------------

minimal='{"schema_version":"1.0","updated_at":"2026-11-11T09:00:00Z","last_runs":[],"queue":[],"today":{"date":"","runs":0,"completed":0,"stopped":0,"total_cost_usd":0}}'
jq '.schema_version="9.9"' <<<"$minimal" | put
run_status
check "invalid: another schema_version gives INVALID" \
  '[ "$code" = 1 ] && [ "$err" = "STATUS: status=INVALID reason=unreadable or unknown status file" ] && [ -z "$out" ]'
jq '.prompt="secret"' <<<"$minimal" | put
run_status --json
check "invalid: an unknown field gives INVALID" \
  '[ "$code" = 1 ] && [ "$err" = "STATUS: status=INVALID reason=unreadable or unknown status file" ] && [ -z "$out" ]'

# --- 4. --json -------------------------------------------------------------------

jq -n --arg r1 "$(rid 1)" --arg r2 "$(rid 2)" '{
  schema_version: "1.0", updated_at: "2026-11-11T10:05:00Z",
  watcher: {started_at: "2026-11-11T10:00:00Z", last_pass_at: "2026-11-11T10:05:00Z", slots: 1, slots_busy: 1,
            repositories: ["FullFran/bifrost"]},
  current_run: {run_id: $r2, repository: "FullFran/bifrost", issue: 3, started_at: "2026-11-11T10:05:00Z",
                node_id: "implement", node_kind: "agent", attempt: 2},
  last_runs: [{run_id: $r1, repository: "FullFran/bifrost", issue: 7, started_at: "2026-11-11T10:01:00Z",
               finished_at: "2026-11-11T10:04:00Z", status: "COMPLETE", total_cost_usd: 1.25, duration_ms: 180000,
               retries: 1, pr_number: 12, request_model: "claude-opus-5-5"}],
  queue: [{repository: "FullFran/bifrost", issues: [3, 9]}],
  today: {date: "2026-11-11", runs: 1, completed: 1, stopped: 0, total_cost_usd: 1.25}}' | put
check "fixture: the full fixture validates against the schema" 'validate "$status_file"'
run_status --json
printf '%s\n' "$out" >"$scratch/out.json"
check "--json: exit 0, output validates against the schema" '[ "$code" = 0 ] && [ -z "$err" ] && validate "$scratch/out.json"'
check "--json: output equals the file (jq -S)" '[ "$(jq -S . "$scratch/out.json")" = "$(jq -S . "$status_file")" ]'
check "--json: two-space indentation and a trailing newline" \
  '[ "$(sed -n 2p "$scratch/out.json")" = "  \"schema_version\": \"1.0\"," ] && [ "$("$factory" status --json | tail -c 1 | od -An -c | tr -d " ")" = "\n" ]'

# --- 5. summary of the design example ----------------------------------------------

jq -n --arg r1 "$(rid 1)" '{
  schema_version: "1.0", updated_at: "2026-11-11T10:05:00Z",
  watcher: {started_at: "2026-11-11T10:00:00Z", last_pass_at: "2026-11-11T10:05:00Z", slots: 1, slots_busy: 0,
            repositories: ["FullFran/bifrost", "FullFran/other"]},
  last_runs: [{run_id: $r1, repository: "FullFran/bifrost", issue: 7, started_at: "2026-11-11T10:01:00Z",
               finished_at: "2026-11-11T10:04:00Z", status: "STOPPED", stop_code: "timeout", stop_detail: "node implement timed out",
               total_cost_usd: 0.42, duration_ms: 180000, retries: 0}],
  queue: [{repository: "FullFran/bifrost", issues: [3]}],
  today: {date: "2026-11-11", runs: 1, completed: 0, stopped: 1, total_cost_usd: 0.42}}' | put
check "fixture: the example validates against the schema" 'validate "$status_file"'
want='updated 2026-11-11T10:05:00Z
watcher: started 2026-11-11T10:00:00Z, last pass 2026-11-11T10:05:00Z, slots 0/1, repos FullFran/bifrost FullFran/other
current: none
queue: FullFran/bifrost#3
today 2026-11-11: 1 runs, 0 complete, 1 stopped, $0.42
last runs:
  2026-11-11T10:04:00Z FullFran/bifrost#7 STOPPED timeout $0.42'
run_status
check "summary: the design example, exactly" '[ "$code" = 0 ] && [ -z "$err" ] && [ "$out" = "$want" ]'
check "summary: never shows the stop detail" '! grep -q "timed out" <<<"$out"'

# --- 6. minimal file ------------------------------------------------------------------

printf '%s\n' "$minimal" | put
want='updated 2026-11-11T09:00:00Z
watcher: not running
current: none
queue: empty
today -: 0 runs, 0 complete, 0 stopped, $0.00
last runs: none'
run_status
check "summary: minimal file gives the not running, none, empty and - forms" '[ "$code" = 0 ] && [ "$out" = "$want" ]'

# --- 7. current run without node, and a watcher without a pass ----------------------------

jq --arg r "$(rid 5)" '.watcher={started_at:"2026-11-11T09:00:00Z",slots:2,slots_busy:1,repositories:["FullFran/bifrost"]}
  | .current_run={run_id:$r,repository:"FullFran/bifrost",issue:4,started_at:"2026-11-11T09:00:00Z"}' <<<"$minimal" | put
run_status
check "summary: last pass - when the watcher has not passed yet" \
  '[ "$code" = 0 ] && grep -qxF "watcher: started 2026-11-11T09:00:00Z, last pass -, slots 1/2, repos FullFran/bifrost" <<<"$out"'
check "summary: current run without node or attempt prints -" \
  'grep -qxF "current: FullFran/bifrost#4 run $(rid 5) node - (-) attempt -" <<<"$out"'
jq '.current_run+={node_id:"verify",node_kind:"code",attempt:3}' "$status_file" >"$scratch/cur.json" && put <"$scratch/cur.json"
run_status
check "summary: current run with node, kind and attempt" \
  'grep -qxF "current: FullFran/bifrost#4 run $(rid 5) node verify (code) attempt 3" <<<"$out"'

# --- 8 and 9. at most 5 last runs, PR number --------------------------------------------

jq -n --argjson base "$minimal" '$base | .last_runs=[range(1;8) as $i | {
    run_id: ("run_00000000-0000-0000-0000-" + ("00000000000" + ($i|tostring))), repository: "FullFran/bifrost", issue: $i,
    started_at: "2026-11-11T08:00:00Z", finished_at: ("2026-11-11T08:0" + ($i|tostring) + ":00Z"),
    status: "COMPLETE", total_cost_usd: 1, duration_ms: 1000, retries: 0} + (if $i == 1 then {pr_number: 12} else {} end)]
  | .queue=[{repository:"FullFran/bifrost",issues:[3,9]},{repository:"FullFran/other",issues:[1]}]
  | .today.date="2026-11-11"' | put
check "fixture: seven runs validate against the schema" 'validate "$status_file"'
run_status
runs_lines="$(sed -n '/^last runs:$/,$p' <<<"$out" | tail -n +2)"
check "summary: only the first 5 last runs, newest (first in file) first" \
  '[ "$(wc -l <<<"$runs_lines" | tr -d " ")" = 5 ] && [ "$(head -1 <<<"$runs_lines")" = "  2026-11-11T08:01:00Z FullFran/bifrost#1 COMPLETE \$1.00 PR #12" ] && [ "$(tail -1 <<<"$runs_lines")" = "  2026-11-11T08:05:00Z FullFran/bifrost#5 COMPLETE \$1.00" ]'
check "summary: PR #n only when a pull request was opened" '[ "$(grep -c "PR #" <<<"$runs_lines")" = 1 ]'
check "summary: queue lists every issue of every repository in file order" \
  'grep -qxF "queue: FullFran/bifrost#3 FullFran/bifrost#9 FullFran/other#1" <<<"$out"'

# --- 10 and 11. usage ---------------------------------------------------------------------

run_status extra
check "usage: a positional argument exits 2 with STATUS: status=MISCONFIGURED" \
  '[ "$code" = 2 ] && grep -q "^STATUS: status=MISCONFIGURED" <<<"$err" && [ -z "$out" ]'
run_status --bogus
check "usage: an unknown flag exits 2 with STATUS: status=MISCONFIGURED" \
  '[ "$code" = 2 ] && grep -q "^STATUS: status=MISCONFIGURED" <<<"$err" && [ -z "$out" ]'
run_status -h
check "usage: -h exits 0 with the flag help" '[ "$code" = 0 ] && grep -q -- "-json" <<<"$err"'
check "usage: the usage text lists factory status" '"$factory" help | grep -qF "factory status [--json]"'

# --- 12. read only ------------------------------------------------------------------------

before="$(sha256sum "$status_file")"
"$factory" status >/dev/null 2>&1; "$factory" status --json >/dev/null 2>&1
check "read only: the file is unchanged and nothing else is written" \
  '[ "$(sha256sum "$status_file")" = "$before" ] && [ "$(find "$XDG_STATE_HOME" -type f | wc -l | tr -d " ")" = 1 ]'

printf 'RESULT: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
