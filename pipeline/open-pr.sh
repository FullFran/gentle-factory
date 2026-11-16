#!/usr/bin/env bash
# output node (factory#3 step 6): push factory/<issue> and open a draft PR. Merge waits for a human.
# Usage: open-pr.sh RUN_DIR BASE_COMMIT. Runs in the target checkout. Idempotent on resume.
set -euo pipefail
run_dir="$1" base="$2"
ctx="${FACTORY_CONTEXT_FILE:?FACTORY_CONTEXT_FILE is not set}"
gh_bin="${FACTORY_GH_BIN:-gh}"
repo="$(jq -r .repository "$ctx")"
issue="$(jq -r .issue.number "$ctx")"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "factory/$issue" ] || { echo "FALLO: on branch $branch, expected factory/$issue"; exit 1; }
[ "$(git rev-list --count "$base"..HEAD)" -gt 0 ] || { echo "FALLO: no commits since $base, nothing to propose"; exit 1; }

git push -q -u origin "HEAD:refs/heads/$branch" 2>&1

existing="$("$gh_bin" pr list -R "$repo" --head "$branch" --state open --json url -q '.[0].url')"
if [ -n "$existing" ]; then echo "PR: $existing (already open)"; exit 0; fi

title="$(git log --reverse --format=%s "$base"..HEAD | grep -v '^chore(factory):' | head -1)"
[ -n "$title" ] || title="fix: $(sed -n '1s/^# //p' "$(dirname "$ctx")/$(jq -r '.issue_file // "issue.md"' "$ctx")")"
receipts="$run_dir/receipts"
telemetry="$(jq -rs '
  (map(.predicate) | group_by(.step.node_id) | map({n: .[0].step.node_id, a: length,
    c: (map(.telemetry.total_cost_usd // 0) | add), d: (map(.telemetry.duration_ms) | add)})) as $rows
  | "| node | attempts | cost (USD) | duration (s) |\n|---|---|---|---|\n"
  + ($rows | map("| \(.n) | \(.a) | \(.c * 10000 | round / 10000) | \(.d / 1000 | round) |") | join("\n"))
  + "\n\nTotal cost: \($rows | map(.c) | add * 10000 | round / 10000) USD"' "$receipts"/*.json)"
run_id="$(basename "$run_dir")"
base_branch="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || echo origin/main)"
base_branch="${base_branch#origin/}"
ref="Closes"  # a design that is only a slice of the issue must not close it on merge
[ "$(jq -r '.slice // false' "$ctx")" = true ] && ref="Part of"
# The implementer summary, cleaned: whatever precedes its first Markdown heading (chatter such as
# "done, not pushed") is dropped when it has one, and so is every line that would close an issue on
# merge (close/fix/resolve #N, any tense): the reference above is the only one, so a slice says
# "Part of" and never closes the issue.
summary_body() {
  [ -s "$1" ] || { echo "(no implementer summary)"; return; }
  awk -v has_heading="$(grep -cE '^#{1,6} ' "$1")" '
    !started && has_heading > 0 && $0 !~ /^#{1,6} / { next }
    { started = 1 }
    tolower($0) ~ /^[[:space:]]*(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+([a-z0-9_.-]+\/[a-z0-9_.-]+)?#[0-9]+/ { next }
    { print }' "$1"
}
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
{
  printf '%s #%s\n\n## What\n\n' "$ref" "$issue"
  summary_body "$run_dir/outputs/implement.md"
  printf '\n\n## Review\n\n'
  tail -n 40 "$run_dir/outputs/review.md" 2>/dev/null || echo "(no review output)"
  printf '\n\n## Run telemetry\n\nRun `%s` by gentle-factory (`pipeline/`). Design comment: %s\n\n%s\n' \
    "$run_id" "$(jq -r .design_comment.url "$ctx")" "$telemetry"
} >"$body"
url="$("$gh_bin" pr create -R "$repo" --draft --base "$base_branch" \
  --head "$branch" --title "$title" --body-file "$body")"
echo "PR: $url"
