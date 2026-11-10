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
for test in proven not_proven dirty untracked missing_command command_error usage_error fail_code interrupt added_deleted; do
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
