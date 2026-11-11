# gentle-factory

A software factory built from [gentle-ai](https://github.com/Gentleman-Programming/gentle-ai) pieces, packaged as composable [HCS](https://github.com/FullFran/hcs) packages: nodes, run adapters and gates. A human designs the work in an issue; once the design is marked ready, the factory runs alone up to a draft PR. The factory knows no repository: it is a harness plus input (a designed issue), output (a draft PR) and observability. Everything specific to a repository comes from the issue's design and from the repository itself, read at run time. It is assembled and run by the [metaharness](https://github.com/FullFran/metaharness).

The long-term goal is to list it on gentlehub so the gentle-ai community can use it.

Design: [#1](https://github.com/FullFran/gentle-factory/issues/1) (moved from FullFran/metaharness).

Architecture, flow, components and lifecycles in detail: [docs/architecture.md](docs/architecture.md).

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
| `catalog/` | generated HCS-0001 catalog of the embedded pipeline |
| `packages/` | not yet: one folder per package (node, run adapter, gate) |
| `pipeline/` | the one repository-agnostic pipeline: spec, prompts and code nodes |

Build and check the catalog with `go run ./cmd/catalog build|check`: see [catalog/README.md](catalog/README.md).

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
bash tests/start-test.sh                 # start and watch: clone, run, archive, clean up
bash tests/status-test.sh                # factory status: JSON and summary from a status file
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
`done_when`, `expected_files`, `design_file` and `issue_file` (paths relative to the context file),
and `slice` (the design's value, or `false`); when `slice` is `true` the output node's draft PR
says `Part of #<issue>` instead of `Closes #<issue>`, so merging it does not close the issue.

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

- **Agent nodes** run `claude -p --output-format stream-json --verbose` with the prompt on stdin, the
  node's `tools` as `--allowedTools`, and `--disallowedTools` for `git push`, `git tag`,
  `git reset`, `gh` plus the node's `deny`. A `read_only` agent also loses `Edit`,
  `Write`, `NotebookEdit` and `git commit`. An optional `model` member, allowed on agent
  nodes only, is passed to the engine as is as `--model <value>`; unset means the engine's
  default model. A `model` on a non-agent node or one that does not match
  `^[A-Za-z0-9][A-Za-z0-9._\[\]:-]*$` is a spec error. Cost, turns, tokens and model come from
  the stream's final `result` event; the agent's final text is the receipt's `notes`. The node
  log keeps the whole stream, so a node stopped by `timeout_seconds` still shows what the agent
  did, and its receipt notes name the number of turns and the last tool call (#30).
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
  `run.id`, `task.id` and `agent.engine` (#6). Existing `OTEL_RESOURCE_ATTRIBUTES`
  entries (for example `user.name`) are kept; the factory keys replace any value of
  the same key. `agent.engine` is `claude-code` for agent nodes and `code` for code nodes.
- **Engines without OTLP:** agent nodes only run Claude Code, which reads
  `OTEL_RESOURCE_ATTRIBUTES` itself. Another engine (pi, codex, agy) runs today as a
  code node that wraps its CLI, and it receives the same variables with
  `agent.engine=code`. An engine that exports OTLP with the standard SDK picks them up
  unchanged. An engine that ignores the OTEL variables degrades in two steps: the
  wrapper can pass the plain `FACTORY_*` variables and `TRACEPARENT` to the engine's
  own logging or flags, and the runner always records `run_id`, `step.node_id`,
  `execution.engine` (the wrapped command's name), the issue and
  `telemetry.trace_id` in the node's receipt, so the run stays attributable from
  receipts even with no telemetry from the engine itself.
- **Trace export (#13):** with `OTEL_EXPORTER_OTLP_ENDPOINT` set (a base URL),
  `factory run` posts the attempts it executed as one OTLP/HTTP JSON trace to
  `<endpoint>/v1/traces` when it ends, whatever the run status: an
  `invoke_workflow <factory>` root and one `invoke_agent <node>` or
  `execute_tool <node>` span per attempt, with the receipt's span ids, tokens, cost
  and outcome (OpenTelemetry GenAI conventions; pin and mapping in
  `docs/design/receipt-format.md` §5.1). No prompts, outputs, commands or paths are
  exported. With the endpoint unset or empty nothing is sent and the output is
  unchanged. `OTEL_EXPORTER_OTLP_PROTOCOL` other than `http/json` skips the export
  with one stderr line `OTLP: export skipped: only http/json is supported`. An
  unreachable endpoint or a non-2xx answer prints one stderr line
  `OTLP: export failed: ...`; the exit code and `RUN:` lines do not change.

The store is `<repo>/odd/runs/<run_id>/` (`receipts/`, `logs/`, `feedback/`, `outputs/`), or `--runs-dir`.
The runner adds it to `.git/info/exclude`, so it never shows up in `git status` and
is never committed. Output lines are `NODE: ...`, `RETRY: ...` and one final
`RUN: status=COMPLETE|STOPPED ...`. Exit codes: `0` complete, `1` stopped, `2` invalid
spec, context or repository (`RUN: status=MISCONFIGURED`). `summary` prints attempts,
failures, design decisions, retries, cost and duration per node across runs, and a
`MOST: failures=<node> retries=<node> cost=<node>` line.

Not yet: Orca transport and the pi, codex and agy adapters (#2 scope comment), the
stale-output reaper and stuck guard from the node contract §4.3, and the design's
`gate_level` (accepted, not yet applied). The design's `budget_cap_usd`, `turn_cap` and
`timeout_seconds` are applied as ceilings: each node runs with the smaller of its own cap and
the design's, so a design never raises a cap above the spec's.

### Report a run (#15)

```bash
factory report --runs-dir DIR --run-id ID --context context.json
```

Derives the terminal state of a run from its receipts (the last receipt decides) and tells the owner:

- **One issue comment** with a hidden `<!-- factory-report:v1 run=ID receipt=N state=STATE -->` marker
  (`N` is the position of the terminal receipt in the run): `complete`
  (with the draft PR link from the output node's `PR: <url>` log line), `needs_decision` (node and the
  `DECISION:` question) or `stopped` (node, terminal reason and reason), plus attempts and total list-price
  cost. If a comment with the same marker exists, nothing is posted, no label changes and no notification runs
  (`REPORT: status=already-posted`). A run resumed with `--run-id` that ends again has a new terminal
  receipt, so it gets its own comment.
- **Labels:** `needs_decision` removes `factory:ready` and adds `factory:needs-decision` (created when the
  repository lacks it); `complete` and `stopped` remove `factory:ready`.
- **Notification:** when `FACTORY_NOTIFY_CMD` is set it runs once, split on spaces without a shell, with a
  one-line message on stdin. Unset means no notification; a failing command only warns.
- Answering a decision: edit the design comment and put `factory:ready` back; the watcher (#14) starts a new run.

The comment is deliberately minimal because target repositories can be public: it never includes receipts,
logs, commands or absolute paths (paths in quoted text become `<path>`, text is capped). Run artifacts stay in
the receipt store, where `factory panel` shows them. Output is `REPORT: status=posted|already-posted state=...
issue=OWNER/NAME#N`; exit `0` on success, `2` on missing receipts or context. Test: `bash tests/report-test.sh`.

### Factory panel (#15)

```bash
factory panel [--addr 127.0.0.1:8787] [--runs-dir DIR ...] [--spec FILE] [--allow-remote]
```

A local, read-only web UI and JSON API over one or more receipt stores (`--runs-dir` repeats; the default is
the archive `factory start` copies runs to, `${XDG_DATA_HOME:-$HOME/.local/share}/gentle-factory/runs`). The
first line it prints is `PANEL: url=http://HOST:PORT/` (`--addr 127.0.0.1:0` picks a free port).

- **Runs:** repository#issue, run id, status, last node, cost, duration, attempts and last update, refreshed
  every few seconds. Status comes from the receipts with the runner's own stop rules: `complete` (the last
  spec node succeeded), `needs_decision`, `stopped` (a failure the runner does not retry: no retry edge, a
  guard, the same failure signature twice, or retries exhausted) and `running` (no terminal state yet). A
  running run with no file change for longer than the longest node timeout is flagged `silent`: its runner
  may have died.
- **Run view:** an SVG graph of the spec (`--spec`, default the pipeline embedded in the binary): one box
  per node with its attempts as numbered chips colored by status, the last node outlined, and the retry
  edges (`tests`/`review` → `implement`) solid and counted when they happened. Clicking an attempt shows its
  receipt (status, reason, tokens, cost, turns, model, duration, commits, trace), the node's output
  (`outputs/<node>.md`, the last successful answer), its log and the feedback that sent it back.
- **Decisions:** every run parked on a `DECISION:` question, oldest first, with its issue and age, so the
  owner does not have to find them in GitHub notifications.
- **Nodes:** the `factory summary` numbers (attempts, failures, decisions, retries, cost, duration) per node
  across every runs dir shown; the same totals head the runs list and each run.

API: `GET /api/runs`, `/api/runs/{dir}/{run_id}`, `/api/runs/{dir}/{run_id}/attempts/{node}/{attempt}` and
`/api/decisions` (`{dir}` is the index of the `--runs-dir`). The panel only reads: it never writes to a
runs dir. It binds loopback; any other address (including `:8787`, every interface) exits `2` unless
`--allow-remote`, because logs and notes hold machine paths. The UI is static HTML, CSS and JavaScript
embedded in the binary: no build step, no CDN. Test: `bash tests/panel-test.sh`.

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

### Start and watch (#14)

`factory start` owns the whole lifecycle of one issue, so nothing is cloned by hand:

```bash
bin/factory start OWNER/NAME#N [--work-root DIR] [--archive DIR] [--spec FILE] [--keep]
bin/factory watch --repo OWNER/NAME [--repo ...] [--interval SECONDS] [--slots N] [--max-open-prs N] [--once]
```

1. Lock the issue (a second run of the same issue is refused) and `gh repo clone` the
   repository into a fresh directory under the work root
   (default `${XDG_CACHE_HOME:-$HOME/.cache}/gentle-factory/work`).
2. If `factory/N` already exists on origin (a previous attempt, for example one that
   stopped before a design edit), keep it: it is renamed on origin, in one atomic push,
   to a run-scoped `factory/N-<run_id>` (the run named by its `chore(factory)` commits,
   or `factory/N-<tip sha>` when none does), and the new run starts from a fresh
   `factory/N`. Nothing is deleted, and the rename is printed as
   `START: kept factory/N as factory/N-<id> on origin`. If an open pull request uses
   `factory/N`, stop without running or changing anything; merge or close it first.
3. `collect`, then `run` the pipeline. By default it is the `pipeline/` embedded in the
   binary, so an installed `factory` needs no checkout of this repository; `--spec FILE`
   uses another spec instead.
4. Whatever the outcome, copy `<clone>/odd/runs/<run_id>` to
   `<archive>/<run_id>` (default `${XDG_DATA_HOME:-$HOME/.local/share}/gentle-factory/runs`),
   then delete the clone. `--keep` leaves the clone for debugging. If the receipts cannot
   be archived the clone is kept so they are not lost.
5. Report how the run ended on the issue with `factory report` (comment, label swap,
   `FACTORY_NOTIFY_CMD`); a failed report is printed and never changes the run's outcome.

Nothing of a run remains under the work root once it ends. The last line is
`START: status=COMPLETE|STOPPED|NOT_READY|MISCONFIGURED issue=OWNER/NAME#N run=<id> archive=<dir>`
(`run=-` and `archive=-` when nothing ran); exit 0 complete, 1 stopped or not ready, 2 misconfigured.

`watch` lists open issues labelled `factory:ready`, in order, and starts each one like
`start` while slots remain in the pass (`--slots`, default 1; runs are sequential;
`--interval` defaults to 60 s; `--once` does one pass and exits). Back-pressure (#16): while
`--max-open-prs` (default 3) open draft PRs from `factory/` branches await review in a
repository, none of its issues starts (`skip reason=backpressure`), and the design is not
recorded, so it starts once a PR is merged or closed. The sha256 of the
design comment started for each issue is kept in `<work-root>/watch-state.json`, so the
same design never starts twice and an edited design starts again. A `watch.lock` keeps
two watchers apart. Stop a running watcher with Ctrl-C; it exits between passes. The state file is the only
thing `watch` leaves in the work root. Locks hold the pid of their owner and are taken over when it is dead.

**Status file (#43).** `start` and `watch` keep one small JSON file for the panel at
`${XDG_STATE_HOME:-$HOME/.local/state}/gentle-factory/status.json` (mode 0644, directory 0755).
It is rewritten atomically (temporary file, then rename) when a watcher starts, on every pass,
when a run starts, on every node transition and when a run ends. It holds the watcher
(`started_at`, `last_pass_at`, `slots`, `slots_busy`, repositories), the run in progress (run id,
issue, node, kind, attempt), the newest 20 runs (status, a stop code and at most 200 characters
of stop reason, cost, duration, retries, pull request number, model), the open `factory:ready`
issue numbers per repository and the totals of the current UTC day. Each write starts from the
previous file, so the runs and the day totals survive a watcher restart; an unreadable file is
replaced. It never holds prompts, outputs, feedback, logs, tokens, issue titles or paths. A
failed write prints `STATUS: write failed reason=...` and never changes a run. Its JSON Schema is
`schemas/factory-status.schema.json`. `factory run` alone, `report`, `summary` and `panel` never
write it.

`factory status [--json]` reads that one file and prints it: with `--json` as indented JSON that
validates against the same schema, otherwise as a short summary (update time, watcher, run in
progress, queue, today's totals and the newest 5 runs). It never reads receipts and never
writes. It exits 0 when it printed the file and 1 with `STATUS: status=MISSING` or
`STATUS: status=INVALID` on stderr when the file is missing, unreadable, not strictly valid or of
another `schema_version`. An unknown flag or a positional argument exits 2 with
`STATUS: status=MISCONFIGURED`.

`bash tests/start-test.sh` covers both with a local bare origin and `gh` and `claude` doubles.
