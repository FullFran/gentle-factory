# gentle-factory

A software factory built from [gentle-ai](https://github.com/Gentleman-Programming/gentle-ai) pieces, packaged as composable [HCS](https://github.com/FullFran/hcs) packages: nodes, run adapters and gates. A human designs the work in an issue; once the design is marked ready, the factory runs alone up to a draft PR. The factory knows no repository: it is a harness plus input (a designed issue), output (a draft PR) and observability. Everything specific to a repository comes from the issue's design and from the repository itself, read at run time. It is assembled and run by the [metaharness](https://github.com/FullFran/metaharness).

The long-term goal is to list it on gentlehub so the gentle-ai community can use it.

Design: [#1](https://github.com/FullFran/gentle-factory/issues/1) (moved from FullFran/metaharness).

## Direction

- **Own harness, no external workflow engine.** Pieces are HCS packages; a factory is a composition of them.
- **Several engines on different nodes:** Claude Code, Codex or Pi, and agy, each reached through a run adapter.
- **Orca** carries work between nodes where an agent or a human must be watched or reached remotely; deterministic nodes run as plain code.
- **Engram** is the shared memory between nodes.
- **Runs in a disposable workbox** from [FullFran/infra](https://github.com/FullFran/infra).
- **The harness closes a node, not the agent:** a node completes only when the harness has checked its outputs and written a receipt.

## Layout

This repository is an HCS catalog root in the metaharness layout, composed with `metaharness ... --source <this repo>`:

| Path | Contents |
|---|---|
| `catalog/` | generated HCS-0001 catalog |
| `packages/` | one folder per package (node, run adapter, gate) |
| `pipeline/` | the one repository-agnostic pipeline: spec, prompts and code nodes |

## Prove a regression test

`gates/prove-test.sh` is the factory's repository-agnostic proof that a new test catches
the bug: it runs the test without the non-test changes, in a disposable worktree, and
expects it to fail.

```bash
bash tests/prove-test-test.sh
bash tests/schemas-test.sh   # needs jq, python3 and check-jsonschema (or uvx); exits 77 if missing
```


Commit the implementation and its tests, leave the target tree clean (including
no untracked files), then run from the target repository:

```bash
bash /path/to/gentle-factory/gates/prove-test.sh <base-ref> -- bash scripts/tests/example-test.sh
# Override test-path detection when needed (repeat --test-path for multiple paths):
bash /path/to/gentle-factory/gates/prove-test.sh <base-ref> --test-path checks -- bash checks/regression.sh
# Declare which exit codes mean "test failed" when the runner does not use 1:
bash /path/to/gentle-factory/gates/prove-test.sh <base-ref> --fail-code 101 -- cargo test
```

The proof creates a detached worktree under `/tmp`, keeps HEAD's tests, restores
non-test paths to the base, and runs the command there. Use repository-relative
test commands: absolute paths back into the original checkout bypass the proof.
Default test detection covers `test/`, `tests/`, `__tests__/`, and conventional
`*.test.*`, `*.spec.*`, `test_*`, `*_test.*`, `spec_*`, and `*_spec.*` names.
An explicit `--test-path` replaces those defaults. This is a base-to-HEAD
comparison, not a merge-base comparison.

The final line is `PROOF: status=PROVEN|NOT_PROVEN|MISCONFIGURED reason=...`
(with one concrete status and reason). Only a declared failure code proves the
counterfactual: `1` by default, or the codes given with `--fail-code <n>` (repeatable,
for example `--fail-code 101` for `cargo test`). Any other nonzero exit, such as a
pytest usage error (4) or "no tests collected" (5), is MISCONFIGURED with
`reason=test-errored`, because no regression test actually ran. Known limit: an exit code cannot tell a failing assertion from a crash that uses the same code (for example a Python import error also exits 1), so read the test output of a PROVEN result; parsing a runner's report (JUnit XML) is the stronger check. A passing test is
NOT_PROVEN. Missing commands, skipped tests, signals, dirty trees and absent
non-test changes are MISCONFIGURED. Exit codes
are respectively `0`, `1`, and `2`. Run the full gate separately to establish
that the fixed version passes: proof alone does not establish correctness.
The caller's tree and index are never edited. The temporary worktree is removed
on exit, command error, or catchable interrupt; cleanup failure reports its path.
SIGKILL or host failure cannot run cleanup and may leave a `/tmp/gentle-factory-proof.*`
worktree requiring manual removal with `git worktree remove --force <path>`.

### Evidence and limits

- **VERIFIED:** the [upstream proof script](https://github.com/addyosmani/factory/blob/main/template/.factory/scripts/prove-test.sh) separates tests from non-test changes and requires the test to fail without the fix. This implementation uses a disposable worktree instead of reverse-applying a patch to the caller's checkout.
- The contract tests use throwaway Git repositories; scratch directories are created outside the checkout in `/tmp` and removed by the tests.

## Node runner (#2)

`cmd/factory` (Go, standard library only) runs the nodes of a factory against a target
repository and writes one receipt per node attempt ([receipt format](docs/design/receipt-format.md)).
It builds to one static binary; at run time it needs Git, and agent nodes also need `claude`.

```bash
go build -o bin/factory ./cmd/factory
bin/factory collect --repo OWNER/NAME --issue N --checkout /path/to/target --out /path/to/ctx
bin/factory run --spec factory.json --repo /path/to/target --context context.json
bin/factory run ... --run-id <id>        # resume: completed nodes are skipped
bin/factory summary --repo /path/to/target [--json]
bash tests/runner-test.sh                # builds the binary, uses claude and gh doubles, spends nothing
bash tests/pipeline-test.sh              # the pipeline's code nodes, with doubles
```

The spec lists nodes in order; unknown fields are rejected, so a misspelt key
cannot silently drop a guard. Paths in it are relative to the spec file; code
commands run from the target root and may use `{repo}`, `{base_commit}`,
`{run_dir}`, `{spec_dir}` and `{feedback_file}`.

```json
{"factory": "example", "max_retries": 2,
 "protected_paths": ["odd/runs/", ".factory/", "gates/"],
 "nodes": [
  {"id": "implement", "kind": "agent", "prompt_file": "prompts/implement.md",
   "tools": ["Read", "Edit", "Write", "Bash"], "max_turns": 30, "max_budget_usd": 3.0, "timeout_seconds": 1800},
  {"id": "verify", "kind": "code", "command": ["bash", "-c", "make test"],
   "read_only": true, "retry": "implement", "timeout_seconds": 600}
 ]}
```

The context file holds the references every receipt carries and the runner never fetches:
`repository`, `issue` (`number`, `url`), `design_comment` (`id`, `url`, `sha256`, `updated_at`)
and an optional `task_id` (default `<repository>#<issue>`). `collect` also writes
`done_when`, `expected_files`, `design_file` and `issue_file` (paths relative to the context file).

**Collect (design gate, #3):** `collect` reads the issue with `gh`, requires the
`factory:ready` label and the latest comment with a `<!-- factory-design:v1 {...} -->`
block valid against [the design schema](schemas/design-comment.schema.json), pins that
comment's id, url, sha256 and `updated_at`, writes `context.json`, `design.md` and
`issue.md` to `--out`, and creates branch `factory/<issue>` from origin's default branch
in a clean `--checkout`. Before writing anything it runs the design's `done_when` on that
branch: it must fail (a `done_when` that already passes, cannot run or times out proves
nothing), and the checkout is restored afterwards. An issue that is not ready prints `COLLECT: status=NOT_READY
reason=...` and exits 1. `FACTORY_GH_BIN` overrides `gh`.

Behavior:

- **Agent nodes** run `claude -p --output-format json` with the prompt on stdin, the
  node's `tools` as `--allowedTools`, and `--disallowedTools` for `git push`, `git tag`,
  `git reset`, `gh` plus the node's `deny`. A `read_only` agent also loses `Edit`,
  `Write`, `NotebookEdit` and `git commit`. Cost, turns, tokens and model come from
  the engine JSON; the agent's final text is the receipt's `notes`.
  `FACTORY_CLAUDE_BIN` overrides the binary. The prompt gets the issue and the design
  (from the context) and, for each node in the node's `inputs`, its full final answer
  (`## Output of <node>`, kept in `<run_dir>/outputs/`).
- **Decisions:** an agent whose last line starts with `DECISION:` stops the run with
  status `needs_decision` (`user_decision_required`): silence in the design means stop.
  Resuming stops again until HEAD changes.
- **Failure:** a nonzero exit, a gate verdict other than GREEN, or a last output line
  starting with `FALLO:` (for agents, the last line of the result text). A
  `FACTORY_GATES: status=MISCONFIGURED` verdict, or exit 126/127, stops the run
  without retry. Steps past `timeout_seconds` get SIGTERM, then SIGKILL after
  `FACTORY_KILL_GRACE` seconds (default 30).
- **Guards:** a `read_only` node fails with `read_only_modified` if `git status
  --porcelain`, the working diff, untracked files or HEAD changed. An agent node fails
  with `protected_path_modified` if any file, symlink or directory under a protected
  path or the receipt store changed; both are read from the filesystem, so gitignored
  and untracked files count. A producer agent fails with `unexpected_path_modified` if
  it changed a path the context's `expected_files` does not cover (exact path, glob, or
  `dir/**`). Guards run before the receipt is written, and a guard
  trip is final: it is never retried, and resuming stops again.
- **Clean start:** a new run refuses a target with uncommitted changes (exit 2), so
  everything the runner commits comes from the run's own nodes.
- **The harness closes the node:** leftover edits of a successful producer node are
  committed by the runner, so every receipt binds the exact commit it saw.
- **Return loop:** when a node with `retry: <producer>` fails, its reason goes to
  `<run_dir>/feedback/<producer>.txt` and into the producer's prompt, and the producer
  runs again (`FACTORY_FEEDBACK_FILE` points at that file). After `max_retries`
  extra producer attempts, or two consecutive failures with the same
  `failure_signature`, the run stops with that reason.
- **Receipts drive the flow:** the next node is the first one without a current
  success receipt. A checker receipt (code and `read_only` nodes) is stale once HEAD
  moves; a producer receipt stays current, so a planner is `"role": "producer",
  "read_only": true` (otherwise it re-runs after every commit).
- **Identity:** every node gets `FACTORY_NAME`, `FACTORY_RUN_ID`, `FACTORY_TASK_ID`,
  `FACTORY_NODE_ID`, `FACTORY_ATTEMPT`, `FACTORY_CONTEXT_FILE`, a W3C `TRACEPARENT` (one trace per run), and
  `OTEL_RESOURCE_ATTRIBUTES` with `service.name=factory-<name>`, `factory.name`,
  `run.id`, `task.id` and `agent.engine` (#6).

The store is `<repo>/odd/runs/<run_id>/` (`receipts/`, `logs/`, `feedback/`, `outputs/`), or `--runs-dir`.
The runner adds it to `.git/info/exclude`, so it never shows up in `git status` and
is never committed. Output lines are `NODE: ...`, `RETRY: ...` and one final
`RUN: status=COMPLETE|STOPPED ...`. Exit codes: `0` complete, `1` stopped, `2` invalid
spec, context or repository (`RUN: status=MISCONFIGURED`). `summary` prints attempts,
failures, retries, cost and duration per node across runs, and a
`MOST: failures=<node> retries=<node> cost=<node>` line.

Not yet: Orca transport and the pi, codex and agy adapters (#2 scope comment), the
stale-output reaper and stuck guard from the node contract §4.3, and the design's
`gate_level`, `budget_cap_usd`, `turn_cap` and `timeout_seconds` (accepted, not yet applied).

## Pipeline (#3)

`pipeline/` is the same for every repository (decision in #1: no per-repository layers):
`plan` (read-only) → `implement` (gets the plan) → `tests` (runs the design's `done_when`) →
`review` (read-only, a separate claude; `FALLO:` sends the change back) → `output` (pushes
`factory/<issue>` and opens a **draft** PR with the run's telemetry). Merge waits for Fran.

Where repository knowledge comes from:

- **The design comment:** `done_when` lists every check that proves the issue done, including
  the repository's own test commands; `expected_files` bounds the edits.
- **The repository, at run time:** the planner, implementer and reviewer read its agent and
  contributor instructions (`AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`), its CI and scripts,
  and the reviewer judges against the last merged changes in its history.

```bash
bin/factory collect --repo OWNER/NAME --issue N --checkout "$co" --out "$ctx"
bin/factory run --spec pipeline/factory.json --repo "$co" --context "$ctx/context.json"
```

Not yet (#14): `factory start` cloning into a work directory, running, and deleting the clone.
