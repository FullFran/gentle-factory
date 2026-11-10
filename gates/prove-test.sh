#!/usr/bin/env bash
# Counterfactual test in a disposable worktree; the caller's tree is never edited.
set -uo pipefail
scratch=
proof_tree=
result=MISCONFIGURED
reason=unexpected-error
finish() {
  local cleanup_failed=0
  trap '' INT TERM HUP
  if [[ -n $proof_tree && -d $proof_tree ]]; then
    git -C "$root" worktree remove --force -- "$proof_tree" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ $cleanup_failed == 0 && -n $scratch ]]; then
    rm -rf -- "$scratch" || cleanup_failed=1
  fi
  if [[ $cleanup_failed != 0 ]]; then
    result=MISCONFIGURED; reason=cleanup-failed
    printf 'ERROR: scratch-retained:%s\n' "$scratch" >&2
  fi
  printf 'PROOF: status=%s reason=%s\n' "$result" "$reason"
  case $result in PROVEN) exit 0 ;; NOT_PROVEN) exit 1 ;; *) exit 2 ;; esac
}
fail() { reason=$1; exit 2; }
usage() {
  printf 'Usage: %s <base-ref> [--test-path <relative-path>]... [--fail-code <n>]... -- <test-command> [args...]\nRun from the target repository. Requires a clean committed tree, including no untracked files.\nDefault test paths: test/, tests/, __tests__/, *.test.*, *.spec.*, test_*, *_test.*, spec_*, *_spec.*.\nOnly the declared failure codes (default: 1) prove a regression; any other non-zero exit is a test error, not a proof.\nExit: 0 PROVEN, 1 NOT_PROVEN, 2 MISCONFIGURED.\n' "$0"
}
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
trap finish EXIT
trap 'reason=interrupted; exit 2' INT TERM HUP
[[ $# -ge 3 ]] || { usage >&2; fail invalid-arguments; }
base=$1
shift
test_paths=()
fail_codes=()
while [[ $# -gt 0 && $1 != -- ]]; do
  [[ $# -ge 2 && -n $2 ]] || fail invalid-arguments
  case $1 in
    --test-path)
      case /$2/ in //*|*/../*|*/./*) fail invalid-test-path ;; esac
      test_paths+=("${2%/}") ;;
    --fail-code)
      [[ $2 =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 125 && $2 != 77 )) || fail invalid-fail-code
      fail_codes+=("$((10#$2))") ;;
    *) fail invalid-arguments ;;
  esac
  shift 2
done
[[ $# -ge 2 && $1 == -- ]] || fail invalid-arguments
shift
for tool in git mktemp rm; do command -v "$tool" >/dev/null 2>&1 || fail missing-tool; done
root=$(git rev-parse --show-toplevel 2>/dev/null) || fail not-a-git-repository
cd -- "$root" || fail missing-repository-root
base=$(git rev-parse --verify --end-of-options "$base^{commit}" 2>/dev/null) || fail invalid-base-ref
head=$(git rev-parse HEAD) || fail invalid-head
state=$(git status --porcelain --untracked-files=all) || fail status-unavailable
[[ -z $state ]] || fail working-tree-not-clean
((${#fail_codes[@]})) || fail_codes=(1)
non_tests=()
mapfile -d '' -t changed < <(git diff --no-renames --name-only -z "$base" "$head" --)
wait "$!" || fail diff-unavailable
for path in "${changed[@]}"; do
  is_test=0
  if ((${#test_paths[@]})); then
    for test_path in "${test_paths[@]}"; do
      [[ $path == "$test_path" || $path == "$test_path/"* ]] && is_test=1
    done
  else
    case $path in
      test/*|tests/*|__tests__/*|*/test/*|*/tests/*|*/__tests__/*|*.test.*|*.spec.*|test_*|*/test_*|*_test.*|spec_*|*/spec_*|*_spec.*) is_test=1 ;;
    esac
  fi
  (( is_test )) || non_tests+=(":(literal)$path")
done
((${#non_tests[@]})) || fail no-non-test-change
# /tmp is deliberate: scratch must not land inside the target via TMPDIR.
scratch=$(mktemp -d /tmp/gentle-factory-proof.XXXXXX) || fail scratch-unavailable
proof_tree="$scratch/tree"
git worktree add --quiet --detach "$proof_tree" "$head" >/dev/null 2>&1 || fail worktree-unavailable
# Keep HEAD's tests, replace only non-test paths with their base versions.
git -C "$proof_tree" restore --source="$base" --worktree -- "${non_tests[@]}" || fail revert-failed
cd -- "$proof_tree" || fail missing-proof-tree
command -v "$1" >/dev/null 2>&1 || fail test-command-unavailable
"$@"; code=$?
cd -- "$root" || fail missing-repository-root
case $code in
  0) result=NOT_PROVEN; reason=test-passed-without-change ;;
  77|126|127) reason=test-command-unavailable ;;
  *)
    if (( code >= 128 )); then reason=test-interrupted
    elif [[ " ${fail_codes[*]} " == *" $code "* ]]; then result=PROVEN; reason=test-failed-without-change
    else reason=test-errored
    fi ;;
esac
exit 0
