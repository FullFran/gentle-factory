#!/usr/bin/env bash
# Contract tests for `factory design check` (#57): verify a design comment saved in a
# local file before factory:ready, without gh and without the network.
# Needs bash, git, go and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in git go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-design-check-test.XXXXXX")"
trap 'chmod -R u+rwX "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT
factory="$scratch/factory"
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf "FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "  %s\n" "$2"; [ -n "${out:-}" ] && printf "  out: %s\n" "${out//$'\n'/ | }"; [ -n "${err:-}" ] && printf "  err: %s\n" "${err//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }

# --- gh double: records any call and fails -----------------------------------

mkdir -p "$scratch/bin"
cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
{ printf 'ARGV:'; printf ' [%s]' "$@"; printf '\n'; } >>"${GH_LOG:?}"
exit 1
EOF
chmod +x "$scratch/bin/gh"
export GH_LOG="$scratch/gh.log"
: >"$GH_LOG"
export PATH="$scratch/bin:$PATH"
export FACTORY_GH_BIN="$scratch/bin/gh"

rule='Rule on ambiguity: silence in this design means STOP. If an unexpected decision arises, end with `DECISION: <question>`.'

# design FILE DONE_WHEN EXPECTED_FILES_JSON [EXTRA_FIELDS] -> a design body with the rule last
design() {
  cat >"$1" <<EOF
# Design

<!-- factory-design:v1
{
  "schema_version": "1.0",
  "ready_signal": "factory:ready",
  "done_when": $(jq -cn --arg d "$2" '$d'),
  "expected_files": $3${4:-}
}
-->

## 1. Goal
Something to do.

$rule
EOF
}

new_repo() { # new_repo NAME -> path of a clean repo with one commit
  local repo="$scratch/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  echo base >"$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
  printf '%s' "$repo"
}

dc() { # dc ARGS... -> sets out (stdout), err (stderr), code, last
  out="$("$factory" design check "$@" 2>"$scratch/stderr")"
  code=$?
  err="$(cat "$scratch/stderr")"
  last="$(printf '%s\n' "$out" | tail -n 1)"
}

# --- valid design without --repo-dir -------------------------------------------

design "$scratch/valid.md" "exit 3" '["a.go", "docs/b.md"]'
dc "$scratch/valid.md"
check "valid: exit 0" '[ "$code" = 0 ]'
check "valid: last line VALID, UNCHECKED, count" \
  '[ "$last" = "DESIGN: status=VALID file=$scratch/valid.md expected_files=2 done_when=UNCHECKED" ]'

# --- valid design with --repo-dir: done_when exits 3 ----------------------------

repo="$(new_repo red)"
branches_before="$(git -C "$repo" branch --list)"
dc "$scratch/valid.md" --repo-dir "$repo"
check "red: exit 0" '[ "$code" = 0 ]'
check "red: RED line" 'printf "%s\n" "$out" | grep -qx "DESIGN: check=done_when status=RED exit=3"'
check "red: last line done_when=RED" \
  '[ "$last" = "DESIGN: status=VALID file=$scratch/valid.md expected_files=2 done_when=RED" ]'
check "red: tree clean" '[ -z "$(git -C "$repo" status --porcelain)" ]'
check "red: no new branch" '[ "$(git -C "$repo" branch --list)" = "$branches_before" ]'

# --- done_when that writes files is cleaned up ----------------------------------

design "$scratch/writes.md" "echo x >new.txt; echo y >README.md; mkdir -p d && touch d/f; exit 4" '["a.go"]'
dc "$scratch/writes.md" --repo-dir "$repo"
check "writes: exit 0" '[ "$code" = 0 ]'
check "writes: RED exit=4" 'printf "%s\n" "$out" | grep -qx "DESIGN: check=done_when status=RED exit=4"'
check "writes: tree clean afterwards" '[ -z "$(git -C "$repo" status --porcelain)" ] && [ ! -e "$repo/new.txt" ] && [ ! -e "$repo/d" ]'
check "writes: tracked file restored" '[ "$(cat "$repo/README.md")" = base ]'

# --- done_when exits 0 or 127 ----------------------------------------------------

design "$scratch/green.md" "true" '["a.go"]'
dc "$scratch/green.md" --repo-dir "$repo"
check "green: exit 1" '[ "$code" = 1 ]'
check "green: INVALID already passes" '[[ "$last" == "DESIGN: status=INVALID reason="*"already passes"* ]]'

design "$scratch/missing-cmd.md" "no-such-command-xyz" '["a.go"]'
dc "$scratch/missing-cmd.md" --repo-dir "$repo"
check "127: exit 1" '[ "$code" = 1 ]'
check "127: INVALID cannot run" '[[ "$last" == "DESIGN: status=INVALID reason="*"cannot run"* ]]'
check "127: tree clean" '[ -z "$(git -C "$repo" status --porcelain)" ]'

# --- block problems --------------------------------------------------------------

printf '# Design\n\nNo block here.\n\n%s\n' "$rule" >"$scratch/noblock.md"
dc "$scratch/noblock.md"
check "no block: exit 1" '[ "$code" = 1 ]'
check "no block: INVALID" '[[ "$last" == "DESIGN: status=INVALID reason="*"no factory-design:v1 block"* ]]'

design "$scratch/unknown.md" "exit 3" '["a.go"]' ', "surprise": 1'
dc "$scratch/unknown.md"
check "unknown field: exit 1" '[ "$code" = 1 ]'
check "unknown field: INVALID" '[[ "$last" == "DESIGN: status=INVALID reason="*"unknown field"* ]]'

for entry in /etc/passwd a/../b.go .factory/x gates/x; do
  design "$scratch/bad-path.md" "exit 3" "[\"a.go\", \"$entry\"]"
  dc "$scratch/bad-path.md"
  check "expected_files $entry: exit 1" '[ "$code" = 1 ]'
  check "expected_files $entry: INVALID" '[[ "$last" == "DESIGN: status=INVALID reason=design block: "* ]]'
done

# --- issue handling --------------------------------------------------------------

design "$scratch/issue7.md" "exit 3" '["a.go"]' ', "issue": 7'
dc "$scratch/issue7.md" --issue 8
check "issue 7 vs --issue 8: exit 1" '[ "$code" = 1 ]'
check "issue 7 vs --issue 8: INVALID" '[[ "$last" == "DESIGN: status=INVALID reason="*"issue 7"* ]]'
dc "$scratch/issue7.md" --issue 7
check "issue 7 vs --issue 7: exit 0" '[ "$code" = 0 ]'
dc "$scratch/issue7.md"
check "issue 7 without --issue: exit 0" '[ "$code" = 0 ]'

design "$scratch/issue0.md" "exit 3" '["a.go"]' ', "issue": 0'
dc "$scratch/issue0.md"
check "issue 0: exit 1" '[ "$code" = 1 ]'
check "issue 0: INVALID at least 1" '[ "$last" = "DESIGN: status=INVALID reason=design block: issue must be at least 1" ]'

# --- ambiguity line --------------------------------------------------------------

design "$scratch/norule.md" "exit 3" '["a.go"]'
sed -i '$d' "$scratch/norule.md"
echo "Some other closing line." >>"$scratch/norule.md"
dc "$scratch/norule.md"
check "no rule: exit 1" '[ "$code" = 1 ]'
check "no rule: reason" '[ "$last" = "DESIGN: status=INVALID reason=last line must be the exact ambiguity rule" ]'

design "$scratch/after.md" "exit 3" '["a.go"]'
echo "Extra text after the rule." >>"$scratch/after.md"
dc "$scratch/after.md"
check "text after rule: exit 1" '[ "$code" = 1 ]'
check "text after rule: reason" '[ "$last" = "DESIGN: status=INVALID reason=last line must be the exact ambiguity rule" ]'

design "$scratch/blank.md" "exit 3" '["a.go"]'
printf '\n\n   \n' >>"$scratch/blank.md"
dc "$scratch/blank.md"
check "trailing blank lines: exit 0" '[ "$code" = 0 ]'

# --- argument order --------------------------------------------------------------

dc --issue 7 "$scratch/issue7.md"
check "flags before FILE: exit 0" '[ "$code" = 0 ] && [[ "$last" == "DESIGN: status=VALID file=$scratch/issue7.md "* ]]'
dc --repo-dir "$repo" "$scratch/valid.md" --issue 1
check "flags around FILE: exit 0" '[ "$code" = 0 ] && [[ "$last" == *"done_when=RED" ]]'
dc "$scratch/valid.md" "$scratch/valid.md"
check "two positionals: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'

# --- usage and environment problems ----------------------------------------------

dc
check "missing FILE: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'
dc "$scratch/does-not-exist.md"
check "unreadable file: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'
mkdir -p "$scratch/notrepo"
dc "$scratch/valid.md" --repo-dir "$scratch/notrepo"
check "non-repo: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'
dirty="$(new_repo dirty)"
echo change >>"$dirty/README.md"
dc "$scratch/valid.md" --repo-dir "$dirty"
check "dirty repo: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'
check "dirty repo: change kept" '[ -n "$(git -C "$dirty" status --porcelain)" ]'

out="$("$factory" design 2>"$scratch/stderr")"; code=$?; err="$(cat "$scratch/stderr")"
check "design without subcommand: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'
out="$("$factory" design lint "$scratch/valid.md" 2>"$scratch/stderr")"; code=$?; err="$(cat "$scratch/stderr")"
check "design unknown subcommand: exit 2" '[ "$code" = 2 ] && [[ "$err" == "DESIGN: status=MISCONFIGURED"* ]]'

out="$("$factory" --help 2>&1)"; code=$?; err=""
check "--help mentions design check" '[ "$code" = 0 ] && [[ "$out" == *"design check"* ]]'
out=""

check "gh was never called" '[ ! -s "$GH_LOG" ]'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
