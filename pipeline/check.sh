#!/usr/bin/env bash
# tests node: runs the design's done_when, which lists the repository's own checks.
# The factory knows no repository; what proves "done" comes from the design.
# Runs in the target checkout. The last line is the verdict the runner reads.
set -uo pipefail
ctx="${FACTORY_CONTEXT_FILE:?FACTORY_CONTEXT_FILE is not set}"
done_when="$(jq -r '.done_when // empty' "$ctx")"
if [ -z "$done_when" ]; then
  echo "FACTORY_GATES: status=MISCONFIGURED reason=the context has no done_when"
  exit 2
fi
printf '== done_when: %s\n' "$done_when"
if bash -c "$done_when"; then
  echo "CHECK: done_when ok"
  exit 0
fi
echo "CHECK: done_when failed"
printf 'FALLO: done_when failed: %s\n' "$done_when"
exit 1
