#!/usr/bin/env bash
# Dotfiles v1 gate. Exit 0=GREEN, 1=RED, 2=MISCONFIGURED.
set -uo pipefail
status=GREEN
finish() {
  printf 'FACTORY_GATES: status=%s\n' "$status"
  case $status in GREEN) exit 0 ;; RED) exit 1 ;; *) exit 2 ;; esac
}
misconfigured() { printf 'ERROR: %s\n' "$*" >&2; status=MISCONFIGURED; finish; }
if [[ ${1:-} == --help ]]; then
  printf 'Usage: %s <target-repo> <base-ref>\nRuns changed-shell syntax, tracked blob size, and scripts/tests/*-test.sh.\nExit: 0 GREEN, 1 RED, 2 MISCONFIGURED.\n' "$0"
  exit 0
fi
[[ $# == 2 ]] || misconfigured 'usage: gates.sh <target-repo> <base-ref>'
for tool in git bash date stat head tr; do
  command -v "$tool" >/dev/null 2>&1 || misconfigured "missing-tool:$tool"
done
cd -- "$1" || misconfigured 'missing-target-directory'
root=$(git rev-parse --show-toplevel 2>/dev/null) || misconfigured 'not-a-git-repository'
cd -- "$root" || misconfigured 'missing-repository-root'
base=$(git rev-parse --verify --end-of-options "$2^{commit}" 2>/dev/null) || misconfigured 'invalid-base-ref'
git diff --name-only "$base" -- >/dev/null 2>&1 || misconfigured 'diff-unavailable'
run_gate() {
  local name=$1 start end code result
  shift
  start=$(date +%s%3N)
  "$@"; code=$?
  end=$(date +%s%3N)
  case $code in
    0) result=GREEN ;;
    2) result=MISCONFIGURED; status=MISCONFIGURED ;;
    *) result=RED; [[ $status == MISCONFIGURED ]] || status=RED ;;
  esac
  printf 'GATE: name=%s status=%s duration_ms=%s\n' "$name" "$result" "$((end - start))"
}
shell_syntax() {
  local path shebang checker interpreter result=0
  local -a paths
  # Read the list first and check git's exit code: a failed listing must not look like an empty one.
  mapfile -d '' -t paths < <(git diff --name-only --diff-filter=ACMRT -z "$base" --)
  wait "$!" || { printf 'ERROR: diff-unavailable\n' >&2; return 2; }
  for path in "${paths[@]}"; do
    [[ -f $path && ! -L $path ]] || continue
    shebang=$(head -c 128 -- "$path" | tr -d '\0')
    shebang=${shebang%%$'\n'*}
    checker=
    # Match the interpreter as a whole word: "#!/usr/bin/env wish" is not a shell.
    if [[ $shebang =~ ^'#!'[[:space:]]*([^[:space:]]+)([[:space:]]+([^[:space:]]+))? ]]; then
      interpreter=${BASH_REMATCH[1]##*/}
      [[ $interpreter == env ]] && interpreter=${BASH_REMATCH[3]##*/}
      case $interpreter in
        zsh) checker=zsh ;;
        sh|bash|dash|ksh) checker=bash ;;
      esac
    fi
    if [[ -z $checker ]]; then
      case $path in
        *.zsh) checker=zsh ;;
        *.sh|*.bash) checker=bash ;;
        *) continue ;;
      esac
    fi
    if ! command -v "$checker" >/dev/null 2>&1; then
      printf 'ERROR: missing-tool:%s\n' "$checker" >&2; result=2
    elif ! "$checker" -n -- "$path"; then
      printf 'ERROR: syntax:%s checker=%s\n' "$path" "$checker" >&2
      [[ $result == 2 ]] || result=1
    fi
  done
  return "$result"
}
blob_size() {
  local path size result=0
  local -a paths
  mapfile -d '' -t paths < <(git ls-files -z)
  wait "$!" || { printf 'ERROR: ls-files-unavailable\n' >&2; return 2; }
  for path in "${paths[@]}"; do
    [[ -f $path && ! -L $path ]] || continue
    size=$(stat -c %s -- "$path") || return 2
    if (( size > 1048576 )); then
      printf 'ERROR: blob-too-large:%s bytes=%s\n' "$path" "$size" >&2
      result=1
    fi
  done
  return "$result"
}
script_tests() {
  local tool test code result=0
  local -a tests
  for tool in zsh tmux jq; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'ERROR: missing-tool:%s\n' "$tool" >&2; return 2; }
  done
  [[ -d scripts/tests ]] || { printf 'ERROR: missing-directory:scripts/tests\n' >&2; return 2; }
  shopt -s nullglob
  tests=(scripts/tests/*-test.sh)
  ((${#tests[@]})) || { printf 'ERROR: empty-test-suite\n' >&2; return 2; }
  for test in "${tests[@]}"; do
    bash "$test"; code=$?
    printf 'TEST: path=%s exit=%s\n' "$test" "$code"
    case $code in
      0) ;;
      77|126|127) result=2 ;;
      *) [[ $result == 2 ]] || result=1 ;;
    esac
  done
  return "$result"
}
run_gate shell-syntax shell_syntax
run_gate blob-size blob_size
run_gate scripts-tests script_tests
finish
