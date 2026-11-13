#!/usr/bin/env bash
# Contract tests for `factory watch --repos-file` (#58) and the deploy/ launcher, repository list
# and systemd user unit. gh and the factory binary (for the launcher) are doubles; systemd is
# never called. Needs bash, go and jq. Exit 77 when a tool is missing.
# Assertions are single-quoted strings evaluated by check(), so expansion happens there.
# shellcheck disable=SC2016,SC2034
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-watch-repos-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"   # the status file never goes to the real home
status_file="$XDG_STATE_HOME/gentle-factory/status.json"
mkdir -p "$scratch/install"
factory="$scratch/install/factory"   # built outside the repository
(cd "$here" && CGO_ENABLED=0 go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; [ -n "${out:-}" ] && printf '  out: %s\n' "${out//$'\n'/ | }"; }
check() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }

# --- doubles ---------------------------------------------------------------

mkdir -p "$scratch/bin"
# gh double: records every call; no issue and no pull request anywhere.
cat >"$scratch/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GH_CALLS:?}"
case "${1:-} ${2:-}" in
  "issue list"|"pr list") echo '[]' ;;
  "auth status") exit "${FAKE_GH_AUTH:-0}" ;;
  *) echo "gh double: unexpected $*" >&2; exit 1 ;;
esac
EOS
# factory double for the launcher: prints its arguments and the two exported variables.
cat >"$scratch/bin/factory" <<'EOS'
#!/usr/bin/env bash
printf 'ARGS: %s\n' "$*"
printf 'CLAUDE: %s\n' "${FACTORY_CLAUDE_BIN:-}"
printf 'MODEL: %s\n' "${ANTHROPIC_MODEL:-}"
EOS
chmod +x "$scratch/bin/"*
export FACTORY_GH_BIN="$scratch/bin/gh" FAKE_GH_CALLS="$scratch/calls"
work="$scratch/work"; arch="$scratch/arch"

watch() { : >"$FAKE_GH_CALLS"; rm -f "$status_file"
  out="$("$factory" watch --once --work-root "$work" --archive "$arch" "$@" 2>&1)"; code=$?; }
listed() { sed -n 's/^issue list -R \([^ ]*\) .*/\1/p' "$FAKE_GH_CALLS" | tr '\n' ' '; }
repos_json() { jq -c '.watcher.repositories' "$status_file" 2>/dev/null; }

# --- factory watch --repos-file ---------------------------------------------

cat >"$scratch/a.txt" <<'EOF'
# watched repositories

  FullFran/one
FullFran/two   # a trailing comment
	# an indented comment
FullFran/three
EOF
watch --repos-file "$scratch/a.txt"
check "repos-file: comments, blank lines and trailing comments are ignored; repos are listed in file order" \
  '[ "$code" = 0 ] && [ "$(listed)" = "FullFran/one FullFran/two FullFran/three " ]'

watch --repos-file "$scratch/a.txt" --repo FullFran/extra --repo FullFran/two
check "repos-file + --repo: file entries first, then --repo, a repeated repo watched once" \
  '[ "$code" = 0 ] && [ "$(listed)" = "FullFran/one FullFran/two FullFran/three FullFran/extra " ]'
check "repos-file + --repo: status.json watcher.repositories is the combined list" \
  '[ "$(repos_json)" = "[\"FullFran/one\",\"FullFran/two\",\"FullFran/three\",\"FullFran/extra\"]" ]'

watch --repo FullFran/solo --repo FullFran/duo
check "repo only: unchanged behavior" \
  '[ "$code" = 0 ] && [ "$(listed)" = "FullFran/solo FullFran/duo " ] && [ "$(repos_json)" = "[\"FullFran/solo\",\"FullFran/duo\"]" ]'

printf 'FullFran/four\nFullFran/one\n' >"$scratch/b.txt"
watch --repos-file "$scratch/b.txt" --repos-file "$scratch/a.txt"
check "repos-file twice: files are read in flag order" \
  '[ "$code" = 0 ] && [ "$(listed)" = "FullFran/four FullFran/one FullFran/two FullFran/three " ]'

printf 'FullFran/one\n# fine\nnot-a-repo\n' >"$scratch/bad.txt"
watch --repos-file "$scratch/bad.txt"
check "repos-file: a bad line exits 2 with FILE:LINE and no gh call" \
  '[ "$code" = 2 ] && grep -qF "$scratch/bad.txt:3" <<<"$out" && [ ! -s "$FAKE_GH_CALLS" ]'

watch --repos-file "$scratch/missing.txt"
check "repos-file: a missing file exits 2 (cannot read repos file)" \
  '[ "$code" = 2 ] && grep -q "cannot read repos file" <<<"$out" && [ ! -s "$FAKE_GH_CALLS" ]'

printf '# nothing here\n\n' >"$scratch/empty.txt"
watch --repos-file "$scratch/empty.txt"
check "repos-file: only comments and no --repo exits 2" \
  '[ "$code" = 2 ] && grep -q "at least one --repo or --repos-file" <<<"$out"'

# --- deploy/factory-watch.sh ---------------------------------------------------

launcher="$here/deploy/factory-watch.sh"
launch() { : >"$FAKE_GH_CALLS"
  out="$(env -u FACTORY_CLAUDE_BIN -u ANTHROPIC_MODEL FACTORY_BIN="$scratch/bin/factory" \
    FACTORY_REPOS_FILE="$scratch/a.txt" "$@" bash "$launcher" 2>&1)"; code=$?; }
launch
check "launcher: runs factory watch --repos-file FILE --interval 120" \
  '[ "$code" = 0 ] && grep -qxF "ARGS: watch --repos-file $scratch/a.txt --interval 120" <<<"$out"'
check "launcher: defaults FACTORY_CLAUDE_BIN=claude-factory and ANTHROPIC_MODEL=claude-opus-5-5" \
  'grep -qx "CLAUDE: claude-factory" <<<"$out" && grep -qx "MODEL: claude-opus-5-5" <<<"$out"'
launch FACTORY_CLAUDE_BIN=my-claude ANTHROPIC_MODEL=my-model
check "launcher: caller-set FACTORY_CLAUDE_BIN and ANTHROPIC_MODEL are kept" \
  '[ "$code" = 0 ] && grep -qx "CLAUDE: my-claude" <<<"$out" && grep -qx "MODEL: my-model" <<<"$out"'
launch FAKE_GH_AUTH=1
check "launcher: gh not authenticated exits 1 without running factory" \
  '[ "$code" = 1 ] && grep -q "gh is not authenticated" <<<"$out" && ! grep -q "^ARGS:" <<<"$out"'
launch FACTORY_REPOS_FILE="$scratch/missing.txt"
check "launcher: a missing repos file exits 1 without running factory" \
  '[ "$code" = 1 ] && grep -q "repos file not found" <<<"$out" && ! grep -q "^ARGS:" <<<"$out"'
check "launcher: is executable in git" '[ -x "$launcher" ]'

# --- deploy/watched-repos.example.txt -----------------------------------------

example="example-org/service-api example-org/web-app "
watch --repos-file "$here/deploy/watched-repos.example.txt"
check "watched-repos.example.txt: factory watch reads exactly the example repositories" \
  '[ "$code" = 0 ] && [ "$(listed)" = "$example" ]'
check "deploy/watched-repos.txt is not versioned (the real list is deployment configuration)" \
  '[ ! -e "$here/deploy/watched-repos.txt" ]'

# --- deploy/systemd/gentle-factory-watch.service --------------------------------

unit="$here/deploy/systemd/gentle-factory-watch.service"
check "unit: Restart=always, RestartSec=30, WantedBy=default.target" \
  'grep -qx "Restart=always" "$unit" && grep -qx "RestartSec=30" "$unit" && grep -qx "WantedBy=default.target" "$unit"'
check "unit: ExecStart runs the installed launcher" 'grep -qx "ExecStart=%h/.local/bin/factory-watch" "$unit"'
check "unit: no ExecStart line uses timeout" '[ -f "$unit" ] && ! grep "^ExecStart=" "$unit" | grep -q timeout'

printf 'RESULT: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
