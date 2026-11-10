# runner

Objective: the generic node runner every factory step runs on (gentle-factory#2), receipt-driven per docs/design/node-contract.md §5.
Branch: feat/runner. Delivery: one PR to main (ask-on-risk). Test runner: bash scripts through the public CLI (`tests/runner-test.sh`, builds `cmd/factory`), with engine doubles.

## Specs

- S1 (issue #2, verbatim): «Run a step as code or as a non-interactive agent (`claude -p --output-format json` first), with its own tool allowlist and a deny list (`git push`, `git tag`, `git reset`, `gh`).»
- S2 (issue #2, verbatim): «Telemetry per run and step: log, duration, result, retries, decisions (agent notes), cost from the agent JSON. Each metric written by one place, preferably code. Run, factory and task identity propagate as in FullFran/factory#6.» (#6: `OTEL_RESOURCE_ATTRIBUTES` with `service.name=factory-<name>`, `factory.name`, `run.id`, `task.id`, `agent.engine`.)
- S3 (issue #2, verbatim): «`git status --porcelain` guard: a step declared read-only fails if the target repo changed.» Plus node contract §4.2: after every agent node the runner fails it with `terminal_reason=protected_path_modified` if any path under `odd/runs/`, `.factory/` or the gate scripts changed; receipts are written by the runner only.
- S4 (issue #2, verbatim): «Bounded return loop: a failing test or review step writes its reason to a file, the implementer step retries with it, at most N extra attempts, then the run stops with that reason.» Plus node contract §5.3: two consecutive failures with the same `failure_signature` halt early.
- S5 (issue #2, verbatim): «A summary command: which step fails, retries or costs the most across runs.»
- S6 (node contract §5.1-5.2): next node is the first one without a current success receipt; checking-node receipts are stale when their `head_commit` differs from the current HEAD; producer receipts stay current; resume skips completed nodes. Receipts validate against schemas/receipt.schema.json.
- S7 (issue #2 acceptance, verbatim): «Tests through the public CLI cover: step success, step failure via last line `FALLO:`, guard trip, retry exhaustion, cost recorded once.» «Runs in a workbox with no laptop paths.»

Assumptions (marked, not user-stated):
- A1: v1 runs nodes as local subprocesses behind a run-adapter seam (`code`, `claude`); the Orca transport and the pi/codex/agy adapters from the #2 scope-change comment are later work. Rationale: node contract says v1 is Claude-only and deterministic nodes run as plain code.
- A2: Go standard library, one static binary (was Python until L6).
- A3: issue and design-comment references come from a `--context` JSON file (the design gate of #3 produces it); the runner never fetches GitHub.

## Tasks

- T1 S1,S2,S6,S7 — inline — runner core: spec loading, code and claude adapters, receipts, telemetry, identity env, resume/staleness — done (tests/runner-test.sh)
- T2 S3,S4 — inline — guards and bounded return loop — done (tests/runner-test.sh)
- T3 S5 — inline — summary command, docs — done (tests/runner-test.sh, README "Node runner")

Route evidence: one behavior chain where each task depends on the previous one, so no parallel units and no writer reason; parent writes inline.

## Log

- L1 (2026-11-10, verbatim): «he hecho checkout a main para ahora seguir trabajando a ver falta el runer no?» … «pues vamos a ello! hazlo!»
- L2 (2026-11-10): Tests were written after the code, so no RED was observed first. Instead 8 deliberate mutations of runner/factory.py (deny list, read-only guard, protected guard, retry bound, double cost, agent FALLO, staleness, resume path) each made at least one test fail. runner-test 38/38, gates-test 28/28, schemas-test 23/23, shellcheck and pyflakes clean.
- L3 (2026-11-10): Real `claude` 2.1.322 smoke run in a scratch repo: flags accepted, the agent wrote the file, the run stopped with budget_exceeded because one turn cost $0.42 against a $0.10 cap (the cap is checked between turns, and the laptop's user config inflates the first turn). Top-level `usage` was all zeros on that error result; token counts come from `modelUsage`, so the runner now sums them there and the double mirrors that shape.
- L4: One work-unit commit: T1-T3 are one dependent behavior chain (runner, its guards, its summary) with its tests and docs; splitting it would cut a single behavior. Open: workbox run (S7 second half) not done here; Orca transport and other engines (A1); default caps uncalibrated; consider `--setting-sources`/`--strict-mcp-config` so a box's agent does not load user config.
- L5 (2026-11-10): Independent verifier (risk item 2, guards): S1, S2, S4-S7 met, S3 partial with 3 blockers. B1 protected guard blind to gitignored paths; B2 blind to rewrites of files already untracked; B3 a read-only trip was retried and the next producer commit absorbed the violation. One correction batch: protected paths and the store are snapshotted from the filesystem (files, symlinks, directories), guard trips are final (no retry, resume stops again), a new run needs a clean tree, run ids must start alphanumeric, store subdirectories are recreated before writes, protected entries are normalized. 5 new tests fail on d871070 and pass after; runner-test 43/43.
- L6 (2026-11-10, verbatim): «por qué python y no go?» … «porta a go anda». Ported to Go (cmd/factory, internal/runner); the black-box suite is the contract: 43/43 on the Go binary unchanged except the build step and one numeric JSON comparison. Eight mutations of the Go code each fail at least one test. New: spec and context reject unknown fields (one test). Not repeated: the paid real-claude smoke run; the argv shape is pinned by the double's tests.
