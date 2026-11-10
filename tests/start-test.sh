#!/usr/bin/env bash
# Contract tests for `factory start` and `factory watch` (clone, collect, run, archive, clean up),
# through the public CLI. claude and gh are doubles; origins are local bare repositories.
# Needs bash, git, go and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in git go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-start-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/install"
factory="$scratch/install/factory"   # built outside the repository: start must not need a checkout of it
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; [ -n "${out:-}" ] && printf '  out: %s\n' "${out//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }

# --- doubles ---------------------------------------------------------------

mkdir -p "$scratch/bin"
cat >"$scratch/bin/claude" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
cat >/dev/null
echo "$FACTORY_NODE_ID $(pwd)" >>"${FAKE_LOG:?}"
result="hecho"
case "${FAKE_MODE:-edit}" in
  edit) echo "attempt $FACTORY_ATTEMPT" >impl.txt ;;
  decision) result=$'no se\nDECISION: which one?' ;;
esac
jq -n --arg r "$result" '{type:"result",subtype:"success",is_error:false,result:$r,num_turns:1,
  total_cost_usd:0.1,usage:{input_tokens:1,output_tokens:1}}'
EOS
cat >"$scratch/bin/check.sh" <<'EOS'
#!/usr/bin/env bash
if grep -q '^attempt' impl.txt 2>/dev/null; then echo "all good"; exit 0; fi
echo "FALLO: impl.txt is wrong"; exit 1
EOS
# gh double: repos, issues, comments and issue lists live in $FAKE_GH_DIR, keyed by OWNER+NAME.
cat >"$scratch/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GH_DIR:?}/calls"
repo=""; prev=""
for a in "$@"; do [ "$prev" = -R ] && repo="$a"; prev="$a"; done
key="${repo//\//+}"
case "$1 $2" in
  "repo clone") git clone -q "$FAKE_GH_DIR/origins/${3//\//+}.git" "$4" ;;
  "issue view") cat "$FAKE_GH_DIR/issue-$key-$3.json" ;;
  "issue list") cat "$FAKE_GH_DIR/list-$key.json" ;;
  "api repos/"*)
    IFS=/ read -r _ owner name _ n _ <<<"$2"
    cat "$FAKE_GH_DIR/comments-$owner+$name-$n.json" ;;
  "pr list") case " $* " in *" --head "*) ;; *) cat "$FAKE_GH_DIR/prs-$key.json" 2>/dev/null || echo '[]' ;; esac ;;
  "issue comment") for a in "$@"; do [ "$prev2" = --body-file ] && cat "$a" >>"$FAKE_GH_DIR/report-bodies"; prev2="$a"; done ;;
  "issue edit"|"label create") ;;
  "pr create") echo "https://github.com/$repo/pull/99" ;;
  *) echo "gh double: unexpected $*" >&2; exit 1 ;;
esac
EOS
chmod +x "$scratch/bin/"*
export FACTORY_CLAUDE_BIN="$scratch/bin/claude" FACTORY_GH_BIN="$scratch/bin/gh"
export FAKE_LOG="$scratch/claude.log" FAKE_GH_DIR="$scratch/gh" FACTORY_KILL_GRACE=1
mkdir -p "$FAKE_GH_DIR/origins"
: >"$FAKE_LOG"

cat >"$scratch/spec.json" <<EOF
{"factory": "test", "nodes": [
  {"id": "implement", "kind": "agent", "prompt_file": "implement.md", "tools": ["Read", "Edit", "Write"]},
  {"id": "verify", "kind": "code", "command": ["bash", "$scratch/bin/check.sh"], "read_only": true}]}
EOF
echo "Implement the change." >"$scratch/implement.md"

new_origin() { # new_origin OWNER/NAME -> bare origin served by the gh double
  local key="${1//\//+}" src="$scratch/src-${1//\//+}"
  mkdir -p "$src/gates"
  git -C "$src" init -q -b main
  echo 'echo gate' >"$src/gates/gate.sh"; echo base >"$src/README.md"
  git -C "$src" add -A && git -C "$src" -c user.name=t -c user.email=t@t commit -qm base
  git clone -q --bare "$src" "$FAKE_GH_DIR/origins/$key.git"
}
mk_issue() { # mk_issue OWNER/NAME N LABEL DONE_WHEN -> an issue with a design comment
  local repo="$1" n="$2" key="${1//\//+}" block
  jq -n --argjson n "$n" --arg l "$3" --arg r "$repo" '{number:$n,url:("https://github.com/"+$r+"/issues/"+($n|tostring)),
    title:"an issue",body:"Do it.",labels:[{name:"bug"},{name:$l}]}' >"$FAKE_GH_DIR/issue-$key-$n.json"
  block="{\"schema_version\": \"1.0\", \"issue\": $n, \"ready_signal\": \"factory:ready\", \"done_when\": \"$4\", \"expected_files\": [\"impl.txt\"]}"
  jq -n --arg b "$(printf '<!-- factory-design:v1\n%s\n-->\n\n# Design\n' "$block")" \
    '[[{id:5,html_url:"u",updated_at:"2026-11-10T02:00:00Z",body:$b}]]' >"$FAKE_GH_DIR/comments-$key-$n.json"
}
mk_list() { # mk_list OWNER/NAME N... -> open issues labelled factory:ready
  local key="${1//\//+}"; shift
  printf '%s\n' "$@" | jq -s 'map({number:.})' >"$FAKE_GH_DIR/list-$key.json"
}
empty_dir() { [ -z "$(find "$1" -mindepth 1 2>/dev/null | head -1)" ]; }
starts() { grep -c "^implement " "$FAKE_LOG"; }

new_origin FullFran/bifrost
new_origin FullFran/other
mk_issue FullFran/bifrost 7 factory:ready "test -f impl.txt"
work="$scratch/work"; arch="$scratch/arch"

# --- start -------------------------------------------------------------------

out="$("$factory" start FullFran/bifrost#7 --work-root "$work" --archive "$arch" --spec "$scratch/spec.json" 2>&1)"; code=$?
last="$(tail -1 <<<"$out")"
run_id="$(sed -n 's/^START: .* run=\([^ ]*\) .*/\1/p' <<<"$last")"
check "start: completes a ready issue (exit 0, one START line last)" \
  '[ "$code" = 0 ] && grep -qE "^START: status=COMPLETE issue=FullFran/bifrost#7 run=run_[0-9a-f-]+ archive=$arch/run_[0-9a-f-]+\$" <<<"$last"'
check "start: receipts of the run are archived" \
  '[ -n "$run_id" ] && [ "$(find "$arch/$run_id/receipts" -name "*.json" | wc -l | tr -d " ")" = 2 ] && [ -s "$arch/$run_id/logs/verify-1.log" ]'
check "start: nothing of the run remains under the work root" 'empty_dir "$work"'
check "start: the agent worked inside a clone under the work root" 'grep -q "^implement $work/" "$FAKE_LOG"'
check "start: gh repo clone is how the repository was fetched" 'grep -q "^repo clone FullFran/bifrost " "$FAKE_GH_DIR/calls"'
check "start: reports how the run ended on the issue (#15)" \
  'grep -q "^issue comment 7 -R FullFran/bifrost" "$FAKE_GH_DIR/calls" && grep -q "factory-report:v1 run=run_.* state=complete" "$FAKE_GH_DIR/report-bodies"'
check "start: the report drops factory:ready" 'grep -q "^issue edit 7 -R FullFran/bifrost.*--remove-label factory:ready" "$FAKE_GH_DIR/calls"'

: >"$FAKE_LOG"; mkdir -p "$scratch/kept"
out="$("$factory" start FullFran/bifrost#7 --work-root "$scratch/kept" --archive "$arch" --spec "$scratch/spec.json" --keep 2>&1)"; code=$?
kept="$(find "$scratch/kept" -name .git -maxdepth 3 | head -1)"
check "start: --keep leaves the clone (with its factory/7 branch) in place" \
  '[ "$code" = 0 ] && [ -n "$kept" ] && git -C "$(dirname "$kept")" rev-parse --verify -q factory/7 >/dev/null'

mk_issue FullFran/bifrost 8 other "test -f impl.txt"
: >"$FAKE_LOG"
out="$("$factory" start FullFran/bifrost#8 --work-root "$work" --archive "$arch" --spec "$scratch/spec.json" 2>&1)"; code=$?
check "start: a not-ready issue exits 1 with NOT_READY and runs nothing" \
  '[ "$code" = 1 ] && grep -qE "^START: status=NOT_READY issue=FullFran/bifrost#8 run=- archive=-\$" <<<"$out" && [ ! -s "$FAKE_LOG" ]'
check "start: a not-ready issue leaves nothing under the work root" 'empty_dir "$work"'

mk_issue FullFran/bifrost 9 factory:ready "test -f impl.txt"
git -C "$FAKE_GH_DIR/origins/FullFran+bifrost.git" branch factory/9 main
before="$(git -C "$FAKE_GH_DIR/origins/FullFran+bifrost.git" rev-parse factory/9)"
: >"$FAKE_LOG"
out="$("$factory" start FullFran/bifrost#9 --work-root "$work" --archive "$arch" --spec "$scratch/spec.json" 2>&1)"; code=$?
check "start: an existing remote factory/9 stops before running (exit 1, STOPPED, says why)" \
  '[ "$code" = 1 ] && grep -q "factory/9 already exists on origin" <<<"$out" && grep -qE "^START: status=STOPPED issue=FullFran/bifrost#9 run=- " <<<"$out" && [ ! -s "$FAKE_LOG" ]'
check "start: the existing remote branch is untouched and the work root is clean" \
  '[ "$(git -C "$FAKE_GH_DIR/origins/FullFran+bifrost.git" rev-parse factory/9)" = "$before" ] && empty_dir "$work"'

out="$("$factory" start FullFran/bifrost --work-root "$work" 2>&1)"; code=$?
check "start: a malformed target is MISCONFIGURED (exit 2)" '[ "$code" = 2 ] && grep -qE "^START: status=MISCONFIGURED " <<<"$out"'

# Installed binary, no --spec, default directories from XDG variables: the embedded pipeline runs.
mk_issue FullFran/bifrost 10 factory:ready "test -f impl.txt"
: >"$FAKE_LOG"
out="$(cd "$scratch/install" && XDG_CACHE_HOME="$scratch/xdg-cache" XDG_DATA_HOME="$scratch/xdg-data" FAKE_MODE=decision \
  "$factory" start FullFran/bifrost#10 2>&1)"; code=$?
check "start: the embedded pipeline runs without --spec (stops at the planner's DECISION)" \
  '[ "$code" = 1 ] && grep -q "RUN: status=STOPPED node=plan reason=user_decision_required" <<<"$out" && grep -qE "^START: status=STOPPED issue=FullFran/bifrost#10 run=run_" <<<"$out"'
check "start: a stopped run is still archived under the XDG data default" \
  '[ "$(find "$scratch/xdg-data/gentle-factory/runs" -path "*/receipts/*.json" | wc -l | tr -d " ")" = 1 ]'
check "start: the work root default is under XDG_CACHE_HOME and ends empty" \
  'empty_dir "$scratch/xdg-cache/gentle-factory/work"'

# --- watch -------------------------------------------------------------------

mk_list FullFran/bifrost 7
wwork="$scratch/wwork"; warch="$scratch/warch"
watch() { out="$("$factory" watch --once --work-root "$wwork" --archive "$warch" --spec "$scratch/spec.json" "$@" 2>&1)"; code=$?; }
: >"$FAKE_LOG"
# Back-pressure (#16): no new run while too many factory draft PRs await review.
jq -n '[range(3) | {headRefName: "factory/\(. + 1)", isDraft: true}] + [{headRefName: "feature/x", isDraft: true}, {headRefName: "factory/9", isDraft: false}]' \
  >"$FAKE_GH_DIR/prs-FullFran+bifrost.json"
watch --repo FullFran/bifrost
check "watch: starts nothing while 3 factory draft PRs await review (default --max-open-prs 3)" \
  '[ "$code" = 0 ] && [ "$(starts)" = 0 ] && grep -q "WATCH: issue=FullFran/bifrost#7 skip reason=backpressure open_factory_prs=3" <<<"$out"'
check "watch: back-pressure leaves the design unrecorded, so it starts later" '[ ! -e "$wwork/watch-state.json" ] || ! grep -q "bifrost#7" "$wwork/watch-state.json"'
watch --repo FullFran/bifrost --max-open-prs 4
check "watch: --max-open-prs raises the limit" '[ "$code" = 0 ] && [ "$(starts)" = 1 ]'
rm -rf "$wwork" "$warch" "$FAKE_GH_DIR/prs-FullFran+bifrost.json"; : >"$FAKE_LOG"
watch --repo FullFran/bifrost
check "watch --once: starts a ready labelled issue" '[ "$code" = 0 ] && [ "$(starts)" = 1 ] && grep -q "^START: status=COMPLETE issue=FullFran/bifrost#7" <<<"$out"'
check "watch: lists open factory:ready issues with gh" 'grep -q "^issue list -R FullFran/bifrost .*factory:ready" "$FAKE_GH_DIR/calls"'
check "watch: records the started design sha256 in a state file under the work root" \
  'jq -e ".\"FullFran/bifrost#7\" | test(\"^[0-9a-f]{64}\$\")" "$wwork/watch-state.json" >/dev/null'
watch --repo FullFran/bifrost
check "watch: the same design is not started twice" '[ "$code" = 0 ] && [ "$(starts)" = 1 ] && grep -q "same_design" <<<"$out"'
mk_issue FullFran/bifrost 7 factory:ready "test -f impl.txt && true"
watch --repo FullFran/bifrost
check "watch: a changed design (new sha256) is started again" '[ "$code" = 0 ] && [ "$(starts)" = 2 ]'
check "watch: no lock or clone remains, only the state file" \
  '[ "$(find "$wwork" -mindepth 1 | sort | tr "\n" " ")" = "$wwork/watch-state.json " ]'

mk_issue FullFran/bifrost 11 factory:ready "test -f impl.txt"
mk_issue FullFran/other 3 factory:ready "test -f impl.txt"
mk_list FullFran/bifrost 11
mk_list FullFran/other 3
: >"$FAKE_LOG"; rm -rf "$wwork"
watch --repo FullFran/bifrost --repo FullFran/other
check "watch: --slots defaults to 1, so one issue starts per pass" '[ "$(starts)" = 1 ] && grep -q "slots_full" <<<"$out"'
watch --repo FullFran/bifrost --repo FullFran/other
check "watch: the next pass starts the issue that waited" '[ "$(starts)" = 2 ]'
: >"$FAKE_LOG"; rm -rf "$wwork"
watch --repo FullFran/bifrost --repo FullFran/other --slots 2
check "watch: --slots 2 starts both in one pass" '[ "$(starts)" = 2 ]'

: >"$FAKE_LOG"; rm -rf "$wwork"; mkdir -p "$wwork/locks"
echo $$ >"$wwork/locks/FullFran+bifrost+11.lock"
watch --repo FullFran/bifrost
check "watch: an issue locked by a live process is skipped" '[ "$code" = 0 ] && [ "$(starts)" = 0 ] && grep -q "locked" <<<"$out"'
out="$("$factory" start FullFran/bifrost#11 --work-root "$wwork" --archive "$warch" --spec "$scratch/spec.json" 2>&1)"; code=$?
check "start: two runs of one issue are refused while the lock is held" \
  '[ "$code" = 1 ] && grep -q "locked" <<<"$out" && [ "$(starts)" = 0 ]'
echo 999999 >"$wwork/locks/FullFran+bifrost+11.lock"   # a pid that does not exist: stale lock
watch --repo FullFran/bifrost
check "watch: a stale lock (dead pid) is taken over" '[ "$(starts)" = 1 ]'
echo $$ >"$wwork/watch.lock"
watch --repo FullFran/bifrost
check "watch: a second watcher is refused by the watch lock" '[ "$code" = 1 ] && grep -q "another watcher" <<<"$out"'

# --- hygiene -----------------------------------------------------------------

check "portability: no laptop paths in the runner" '! grep -rnE "/home/|/Users/|~/" "$here/cmd" "$here/internal" "$here/pipeline"/*.go'
check "gofmt: clean" '[ -z "$(cd "$here" && gofmt -l cmd internal pipeline)" ]'

printf 'RESULT: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
