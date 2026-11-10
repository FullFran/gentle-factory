#!/usr/bin/env bash
# Contract tests for the factory pipeline (pipeline/) with claude and gh doubles: nothing is spent or published.
# Needs bash, git, go and jq. Exit 77 when a tool is missing.
# shellcheck disable=SC2016
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layer="$here/pipeline"
for tool in git go jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP missing-tool:%s\n' "$tool"; exit 77; }
done
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gentle-factory-layer-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
factory="$scratch/factory"
(cd "$here" && go build -o "$factory" ./cmd/factory) || { printf 'FAIL go build\n'; exit 1; }
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); printf 'PASS %s\n' "$1"; else fail=$((fail + 1)); printf 'FAIL %s\n  %s\n  out: %s\n' "$1" "$2" "${out//$'\n'/ | }"; fi; }

mkdir -p "$scratch/bin" "$scratch/ctx"
cat >"$scratch/bin/claude" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
cat >/dev/null
jq -n '{type:"result",subtype:"success",is_error:false,result:"looked\nDECISION: which binary path should win?",num_turns:1,total_cost_usd:0.01,usage:{input_tokens:1,output_tokens:1}}'
EOS
cat >"$scratch/bin/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
case "$1 $2" in
  "pr list") cat "${FAKE_GH_EXISTING:-/dev/null}" ;;
  "pr create") for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$FAKE_GH_BODY"; prev="$a"; done
               echo "https://github.com/FullFran/bifrost/pull/99" ;;
esac
EOS
chmod +x "$scratch/bin/"*
export FACTORY_CLAUDE_BIN="$scratch/bin/claude" FACTORY_GH_BIN="$scratch/bin/gh"
export FAKE_GH_CALLS="$scratch/gh.calls" FAKE_GH_BODY="$scratch/body.md"

echo "# agy: spawn bifrost ENOENT" >"$scratch/ctx/issue.md"
echo "design" >"$scratch/ctx/design.md"
jq -n '{repository:"FullFran/bifrost",issue:{number:7,url:"https://github.com/FullFran/bifrost/issues/7"},
  design_comment:{id:3,url:"https://github.com/FullFran/bifrost/issues/7#issuecomment-3",sha256:"ab",updated_at:"2026-11-10T00:00:00Z"},
  done_when:"test -f fixed.txt",expected_files:["fixed.txt"],design_file:"design.md",issue_file:"issue.md"}' >"$scratch/ctx/context.json"
export FACTORY_CONTEXT_FILE="$scratch/ctx/context.json"

src="$scratch/src"; mkdir -p "$src"
git -C "$src" init -q -b main && echo base >"$src/README.md" && git -C "$src" add -A && git -C "$src" -c user.name=t -c user.email=t@t commit -qm base
git clone -q --bare "$src" "$scratch/origin.git" && git clone -q "$scratch/origin.git" "$scratch/co"
co="$scratch/co"
git -C "$co" switch -q -c factory/7

# The spec loads and its first node runs (the double asks a DECISION, so the run stops with 1, not 2).
out="$(cd "$co" && "$factory" run --spec "$layer/factory.json" --repo "$co" --context "$FACTORY_CONTEXT_FILE" --runs-dir "$scratch/runs" 2>&1)"; code=$?
check "spec: loads and runs plan first" '[ "$code" = 1 ] && grep -q "RUN: status=STOPPED node=plan reason=user_decision_required" <<<"$out"'

# check.sh: runs only the design's done_when, never repository-specific commands.
mkdir -p "$scratch/fakebin"
for b in node go npm make; do printf '#!/bin/sh\necho "%s ran" >>"%s"\n' "$b" "$scratch/repo-cmds" >"$scratch/fakebin/$b"; done
chmod +x "$scratch/fakebin/"*
out="$(cd "$co" && PATH="$scratch/fakebin:$PATH" bash "$layer/check.sh" 2>&1)"; code=$?
check "check: a failing done_when fails the node with FALLO" '[ "$code" = 1 ] && [ "$(tail -1 <<<"$out")" = "FALLO: done_when failed: test -f fixed.txt" ]'
touch "$co/fixed.txt"
out="$(cd "$co" && PATH="$scratch/fakebin:$PATH" bash "$layer/check.sh" 2>&1)"; code=$?
check "check: passes when done_when passes" '[ "$code" = 0 ] && grep -q "CHECK: done_when ok" <<<"$out"'
check "check: runs no repository-specific command of its own" '[ ! -e "$scratch/repo-cmds" ]'
jq '.done_when = ""' "$FACTORY_CONTEXT_FILE" >"$scratch/ctx/empty.json"
out="$(cd "$co" && FACTORY_CONTEXT_FILE="$scratch/ctx/empty.json" bash "$layer/check.sh" 2>&1)"; code=$?
check "check: a context without done_when is misconfigured, not a pass" '[ "$code" = 2 ] && grep -q "FACTORY_GATES: status=MISCONFIGURED" <<<"$out"'

# Read-only nodes can run the repository's checks: Bash is allowed, the read-only guard keeps the tree unchanged.
for n in plan review; do
  check "pipeline: $n is read-only and may run any command (Bash)" \
    "jq -e '.nodes[] | select(.id == \"$n\") | .read_only == true and (.tools | index(\"Bash\") != null)' \"\$layer/factory.json\" >/dev/null"
done

check "pipeline: plan and review get as long as implement (they may run the repository's checks)" \
  'jq -e "[.nodes[] | select(.id == \"plan\" or .id == \"review\" or .id == \"implement\") | .timeout_seconds] | unique == [1800]" "$layer/factory.json" >/dev/null'

# The pipeline is repository-agnostic: no file in it names a repository or its commands.
check "pipeline: names no repository or repository-specific command" \
  '! grep -rniE "bifrost|dotfiles|FullFran|node --test|go test|pi/" "$layer"'

# open-pr.sh
base="$(git -C "$co" rev-parse HEAD)"
run_dir="$scratch/runs/run_x"; mkdir -p "$run_dir/receipts" "$run_dir/outputs"
out="$(cd "$co" && bash "$layer/open-pr.sh" "$run_dir" "$base" 2>&1)"; code=$?
check "output: refuses to open a PR with no commits" '[ "$code" = 1 ] && grep -q "FALLO: no commits since" <<<"$out" && [ ! -s "$FAKE_GH_CALLS" ]'
git -C "$co" add fixed.txt && git -C "$co" -c user.name=t -c user.email=t@t commit -qm "fix(pi): resolve the bifrost binary"
echo "Resolved the binary." >"$run_dir/outputs/implement.md"; echo "APROBADO" >"$run_dir/outputs/review.md"
for n in plan implement; do
  jq -n --arg n "$n" '{predicate:{step:{node_id:$n},telemetry:{total_cost_usd:0.5,duration_ms:2000}}}' >"$run_dir/receipts/$n.json"
done
out="$(cd "$co" && bash "$layer/open-pr.sh" "$run_dir" "$base" 2>&1)"; code=$?
check "output: pushes factory/7 to origin" '[ "$code" = 0 ] && [ "$(git -C "$scratch/origin.git" rev-parse factory/7)" = "$(git -C "$co" rev-parse HEAD)" ]'
check "output: opens a draft PR against main titled by the fix commit" \
  'grep "^pr create" "$FAKE_GH_CALLS" | grep -q -- "--draft --base main --head factory/7 --title fix(pi): resolve the bifrost binary"'
check "output: the body closes the issue and carries summary, review and telemetry" \
  'grep -q "^Closes #7" "$FAKE_GH_BODY" && grep -q "Resolved the binary." "$FAKE_GH_BODY" && grep -q APROBADO "$FAKE_GH_BODY" && grep -q "| implement | 1 | 0.5 | 2 |" "$FAKE_GH_BODY" && grep -q "by gentle-factory (\`pipeline/\`)" "$FAKE_GH_BODY" && grep -q "Total cost: 1 USD" "$FAKE_GH_BODY"'
check "output: prints the PR url" 'grep -qx "PR: https://github.com/FullFran/bifrost/pull/99" <<<"$out"'
echo '[{"url":"https://github.com/FullFran/bifrost/pull/99"}]' >"$scratch/existing.json"
: >"$FAKE_GH_CALLS"
out="$(cd "$co" && FAKE_GH_EXISTING="$scratch/existing.json" bash "$layer/open-pr.sh" "$run_dir" "$base" 2>&1)"; code=$?
check "output: on resume an open PR is reused, not duplicated" '[ "$code" = 0 ] && ! grep -q "^pr create" "$FAKE_GH_CALLS" && grep -q "already open" <<<"$out"'

printf 'RESULT: passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
