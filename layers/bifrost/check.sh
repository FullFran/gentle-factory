#!/usr/bin/env bash
# tests node (factory#3 step 4): the repository's own checks plus the design's done_when.
# Runs in the target checkout. The last line is the verdict the runner reads.
set -uo pipefail
ctx="${FACTORY_CONTEXT_FILE:?FACTORY_CONTEXT_FILE is not set}"
failed=()
run() { # run NAME CMD...
  printf '\n== %s\n' "$1"
  if "${@:2}"; then printf 'CHECK: %s ok\n' "$1"; else failed+=("$1"); printf 'CHECK: %s failed\n' "$1"; fi
}
run "node --test pi/bifrost.test.mjs" node --test pi/bifrost.test.mjs
run "go test ./..." go test ./...
done_when="$(jq -r '.done_when // empty' "$ctx")"
[ -n "$done_when" ] && run "done_when: $done_when" bash -c "$done_when"
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'FALLO: failed checks: %s\n' "$(IFS=';'; echo "${failed[*]}")"
  exit 1
fi
echo "all checks passed"
