#!/usr/bin/env bash
# Schema contract tests: documented examples must validate, contradictory documents must not.
# Needs jq, python3 and check-jsonschema (or uvx to run it). Exit 77 when a tool is missing.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRATCH=$(mktemp -d /tmp/gentle-factory-schemas.XXXXXX)
trap 'rm -rf -- "$SCRATCH"' EXIT
for tool in jq python3; do command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }; done
if command -v check-jsonschema >/dev/null 2>&1; then validator=(check-jsonschema)
elif command -v uvx >/dev/null 2>&1; then validator=(uvx -q check-jsonschema)
else printf 'SKIP missing-tool:check-jsonschema\n'; exit 77
fi
RECEIPT=$ROOT/schemas/receipt.schema.json
DESIGN=$ROOT/schemas/design-comment.schema.json
passed=0
failed=0
check() {
  local expect=$1 schema=$2 file=$3 name=$4 got
  if "${validator[@]}" --schemafile "$schema" "$file" >/dev/null 2>&1; then got=valid; else got=invalid; fi
  if [[ $got == "$expect" ]]; then printf 'PASS %s\n' "$name"; passed=$((passed + 1))
  else printf 'FAIL %s (expected %s, got %s)\n' "$name" "$expect" "$got"; failed=$((failed + 1))
  fi
}
# The four example receipts live in receipt-format.md; the fifth JSON block there is a CloudEvents envelope.
python3 - "$ROOT/docs/design/receipt-format.md" "$SCRATCH" <<'EOF'
import json, re, sys
blocks = re.findall(r'```json\n(.*?)```', open(sys.argv[1]).read(), re.S)
receipts = [b for b in blocks if json.loads(b).get('_type')]
assert len(receipts) == 4, f'expected 4 example receipts, found {len(receipts)}'
for i, b in enumerate(receipts):
    open(f'{sys.argv[2]}/receipt-{i}.json', 'w').write(b)
EOF
for i in 0 1 2 3; do check valid "$RECEIPT" "$SCRATCH/receipt-$i.json" "example-receipt-$i"; done
by_node() { jq -e --arg n "$1" --arg s "$2" '.predicate.step.node_id == $n and .predicate.outcome.status == $s' "$3" >/dev/null; }
for f in "$SCRATCH"/receipt-*.json; do
  by_node verify_gate success "$f" && green=$f
  by_node verify_gate failure "$f" && red=$f
done
jq '.predicate.outcome.exit_code = 1 | .predicate.gate.status = "RED"' "$green" > "$SCRATCH/success-red.json"
check invalid "$RECEIPT" "$SCRATCH/success-red.json" success-with-red-gate
jq '.predicate.gate.status = "RED"' "$green" > "$SCRATCH/success-red-gate.json"
check invalid "$RECEIPT" "$SCRATCH/success-red-gate.json" success-with-red-gate-only
jq 'del(.predicate.failure_signature)' "$red" > "$SCRATCH/failure-nosig.json"
check invalid "$RECEIPT" "$SCRATCH/failure-nosig.json" failure-without-signature
jq 'del(.predicate.references.vcs.head_commit)' "$green" > "$SCRATCH/code-nohead.json"
check invalid "$RECEIPT" "$SCRATCH/code-nohead.json" code-node-without-head-commit
design='{"schema_version":"1.0","issue":8,"ready_signal":"factory:ready","done_when":"bash scripts/tests/x-test.sh","expected_files":["scripts/update.sh","docs/*.md"],"gate_level":"standard","budget_cap_usd":3.0,"turn_cap":30}'
printf '%s\n' "$design" > "$SCRATCH/design.json"
check valid "$DESIGN" "$SCRATCH/design.json" design-comment-valid
n=0
for patch in '.done_when = ""' '.done_when = "  "' '.expected_files = ["../other/file"]' '.expected_files = ["a/../../x"]' \
  '.expected_files = ["/etc/passwd"]' '.expected_files = [".factory/gates.conf"]' '.expected_files = [".git/config"]' \
  '.expected_files = ["odd/runs/r1/receipt.json"]'; do
  jq "$patch" "$SCRATCH/design.json" > "$SCRATCH/design-$n.json"
  check invalid "$DESIGN" "$SCRATCH/design-$n.json" "design-comment-rejects:$patch"
  n=$((n + 1))
done
printf 'Tests: passed=%s failed=%s\n' "$passed" "$failed"
(( failed == 0 ))
