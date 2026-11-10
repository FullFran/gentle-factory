#!/usr/bin/env bash
# Public-interface contract tests. All fixtures and command output stay in /tmp.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRATCH=$(mktemp -d /tmp/gentle-factory-tests.XXXXXX)
trap 'rm -rf -- "$SCRATCH"' EXIT
REAL_PATH=$PATH
passed=0
failed=0

new_repo() {
  repo="$SCRATCH/repo-$((++serial))"
  mkdir -p "$repo/scripts/tests" "$repo/bin"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Factory test'
  git -C "$repo" config user.email 'factory@example.invalid'
  printf 'old\n' > "$repo/value"
  printf '#!/bin/bash\nexit 0\n' > "$repo/scripts/tests/smoke-test.sh"
  # Dependency doubles keep the harness tests independent of local packages.
  for tool in zsh tmux jq; do
    printf '#!/bin/bash\nexit 0\n' > "$repo/bin/$tool"
    chmod +x "$repo/bin/$tool"
  done
  git -C "$repo" add .
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
}
commit() { git -C "$repo" add -A; git -C "$repo" commit -qm change; }
invoke() {
  rc=0
  (cd "$repo" && PATH="$repo/bin:$REAL_PATH" bash "$@") > "$SCRATCH/out" 2> "$SCRATCH/err" || rc=$?
}
verdict() {
  local expected=$1 code=$2
  [[ $rc == "$code" ]] || { printf 'exit: expected %s got %s\n' "$code" "$rc"; return 1; }
  [[ $(tail -n 1 "$SCRATCH/out") == "$expected" ]] || { more_output; return 1; }
  [[ $(grep -c '^FACTORY_GATES: status=' "$SCRATCH/out" || :) == 1 ]]
}
more_output() { printf '%s\n' '--- stdout'; while IFS= read -r l; do printf '%s\n' "$l"; done < "$SCRATCH/out"; printf '%s\n' '--- stderr'; while IFS= read -r l; do printf '%s\n' "$l"; done < "$SCRATCH/err"; }
gate() { invoke "$ROOT/gates/gates.sh" "$repo" "$base"; }
proof() { invoke "$ROOT/gates/prove-test.sh" "$base" -- bash scripts/tests/proof-test.sh; }
proof_verdict() { [[ $rc == "$2" ]] && grep -Eq "^PROOF: status=$1 reason=[a-z0-9-]+$" "$SCRATCH/out" && [[ $(grep -c '^PROOF:' "$SCRATCH/out") == 1 ]]; }
restored() {
  [[ -z $(git -C "$repo" status --porcelain --untracked-files=all) ]] &&
  [[ $(< "$repo/value") == fixed ]] &&
  [[ $(git -C "$repo" worktree list --porcelain | grep -c '^worktree ') == 1 ]]
}
proof_fixture() {
  new_repo
  printf 'fixed\n' > "$repo/value"
  printf '#!/bin/bash\n[[ $(< value) == fixed ]]\n' > "$repo/scripts/tests/proof-test.sh"
  commit
}
t_green() {
  new_repo; gate
  verdict 'FACTORY_GATES: status=GREEN' 0
  for name in shell-syntax blob-size scripts-tests; do
    grep -Eq "^GATE: name=$name status=GREEN duration_ms=[0-9]+$" "$SCRATCH/out" || return 1
  done
}
t_red() { new_repo; printf 'exit 1\n' > "$repo/scripts/tests/smoke-test.sh"; commit; gate; verdict 'FACTORY_GATES: status=RED' 1; }
t_missing_directory() { new_repo; rm -rf "$repo/scripts/tests"; commit; gate; verdict 'FACTORY_GATES: status=MISCONFIGURED' 2; }
t_missing_tool() {
  new_repo; rm "$repo/bin/zsh"
  # zsh is absent in this test runner; use an isolated PATH to make this deterministic everywhere.
  mkdir "$repo/only-bin"
  for tool in bash git date stat head tr; do ln -s "$(command -v "$tool")" "$repo/only-bin/$tool"; done
  for tool in tmux jq; do ln -s "$repo/bin/$tool" "$repo/only-bin/$tool"; done
  rc=0
  PATH="$repo/only-bin" /bin/bash "$ROOT/gates/gates.sh" "$repo" "$base" > "$SCRATCH/out" 2> "$SCRATCH/err" || rc=$?
  verdict 'FACTORY_GATES: status=MISCONFIGURED' 2
}
t_skipped() { new_repo; printf 'exit 77\n' > "$repo/scripts/tests/smoke-test.sh"; commit; gate; verdict 'FACTORY_GATES: status=MISCONFIGURED' 2; }
t_syntax() { new_repo; printf '#!/bin/bash\nif then\n' > "$repo/bad script.sh"; commit; gate; verdict 'FACTORY_GATES: status=RED' 1; }
t_zsh_selection() {
  new_repo; printf '#!/usr/bin/env zsh\n' > "$repo/extensionless"
  printf '#!/bin/bash\n[[ $1 == -n && $2 == extensionless ]] || exit 9\nexit 1\n' > "$repo/bin/zsh"
  commit; gate; verdict 'FACTORY_GATES: status=RED' 1
}
t_unchanged_syntax() {
  new_repo; printf 'if then\n' > "$repo/old.sh"; commit; base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed\n' > "$repo/value"; commit; gate; verdict 'FACTORY_GATES: status=GREEN' 0
}
t_shebang_token() { new_repo; printf '#!/usr/bin/env wish\nif then\n' > "$repo/tcl-tool"; commit; gate; verdict 'FACTORY_GATES: status=GREEN' 0; }
t_sh_shebang() { new_repo; printf '#!/bin/sh\nif then\n' > "$repo/extensionless"; commit; gate; verdict 'FACTORY_GATES: status=RED' 1; }
t_ls_files_failure() {
  new_repo
  printf '#!/bin/bash\n[[ $1 == ls-files ]] && exit 128\nexec %q "$@"\n' "$(command -v git)" > "$repo/bin/git"; chmod +x "$repo/bin/git"
  gate; verdict 'FACTORY_GATES: status=MISCONFIGURED' 2
  grep -Eq '^GATE: name=blob-size status=MISCONFIGURED ' "$SCRATCH/out"
}
t_blob() { new_repo; head -c 1048577 /dev/zero > "$repo/blob"; commit; gate; verdict 'FACTORY_GATES: status=RED' 1; }
t_blob_boundary() { new_repo; head -c 1048576 /dev/zero > "$repo/blob"; commit; gate; verdict 'FACTORY_GATES: status=GREEN' 0; }
t_all_tests() {
  new_repo; printf 'exit 1\n' > "$repo/scripts/tests/a-test.sh"
  printf 'printf "second-test-ran\\n"\n' > "$repo/scripts/tests/z-test.sh"
  commit; gate; verdict 'FACTORY_GATES: status=RED' 1; grep -q '^second-test-ran$' "$SCRATCH/out"
}
t_empty_suite() { new_repo; rm "$repo/scripts/tests/smoke-test.sh"; gate; verdict 'FACTORY_GATES: status=MISCONFIGURED' 2; }
t_invalid_ref() { new_repo; base=does-not-exist; gate; verdict 'FACTORY_GATES: status=MISCONFIGURED' 2; }
t_proven() { proof_fixture; proof; proof_verdict PROVEN 0; restored; }
t_not_proven() { proof_fixture; printf 'exit 0\n' > "$repo/scripts/tests/proof-test.sh"; commit; proof; proof_verdict NOT_PROVEN 1; restored; }
t_dirty() {
  proof_fixture; printf 'dirty\n' > "$repo/value"; before=$(git -C "$repo" diff)
  proof; proof_verdict MISCONFIGURED 2; [[ $(git -C "$repo" diff) == "$before" ]]
}
t_untracked() { proof_fixture; printf 'untouched\n' > "$repo/untracked"; proof; proof_verdict MISCONFIGURED 2; [[ $(< "$repo/untracked") == untouched ]]; }
t_missing_command() { proof_fixture; invoke "$ROOT/gates/prove-test.sh" "$base" -- factory-command-does-not-exist; proof_verdict MISCONFIGURED 2; restored; }
t_command_error() { proof_fixture; printf 'printf modified > value\nexit 127\n' > "$repo/scripts/tests/proof-test.sh"; commit; proof; proof_verdict MISCONFIGURED 2; restored; }
t_usage_error() { proof_fixture; printf 'exit 4\n' > "$repo/scripts/tests/proof-test.sh"; commit; proof; proof_verdict MISCONFIGURED 2; grep -q 'reason=test-errored$' "$SCRATCH/out"; restored; }
t_fail_code() {
  proof_fixture; printf '[[ $(< value) == fixed ]] || exit 4\n' > "$repo/scripts/tests/proof-test.sh"; commit
  invoke "$ROOT/gates/prove-test.sh" "$base" --fail-code 4 -- bash scripts/tests/proof-test.sh; proof_verdict PROVEN 0; restored
}
t_interrupt() { proof_fixture; printf 'kill -TERM "$PPID"\n' > "$repo/scripts/tests/proof-test.sh"; commit; proof; proof_verdict MISCONFIGURED 2; restored; }
t_added_deleted() {
  proof_fixture; rm "$repo/value"; printf 'new\n' > "$repo/added"
  printf '[[ -f value && ! -e added ]] || exit 0\nexit 1\n' > "$repo/scripts/tests/proof-test.sh"; commit
  proof; proof_verdict PROVEN 0
  [[ ! -e "$repo/value" && $(< "$repo/added") == new && -z $(git -C "$repo" status --porcelain) ]]
}
serial=0
for test in green red missing_directory missing_tool skipped syntax zsh_selection shebang_token sh_shebang ls_files_failure unchanged_syntax blob blob_boundary all_tests empty_suite invalid_ref proven not_proven dirty untracked missing_command command_error usage_error fail_code interrupt added_deleted; do
  # A separate process preserves errexit inside test functions and isolates fixtures.
  set +e
  (set -e; "t_$test")
  result=$?
  set -e
  if (( result == 0 )); then
    printf 'PASS %s\n' "$test"; passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$test"; failed=$((failed + 1))
  fi
  serial=$((serial + 1))
done
printf 'Tests: passed=%s failed=%s\n' "$passed" "$failed"
(( failed == 0 ))
