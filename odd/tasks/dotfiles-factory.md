# dotfiles-factory

Objective: the first factory (gentle-factory#3): a designed issue becomes a draft PR, run on the #2 runner (`cmd/factory`). First target changed from FullFran/dotfiles to FullFran/bifrost (L3).
Branch: feat/dotfiles-factory. Delivery: ask-on-risk. Test runner: bash contract tests through the CLI with engine and `gh` doubles (`tests/*-test.sh`).

## Specs

- S1 (issue #3 steps, verbatim): «1. Collect (code): issue, linked context, base commit, repo checkout in its own branch. 2. Plan (agent): plan against the issue's acceptance criteria. 3. Implement (agent, may commit on `factory/<issue>`). 4. Tests (code): the repo's own checks. 5. Review (agent, different from the implementer): against the rubric; returns, never fixes. 6. Prepare output (code): push the branch and open a **draft** PR. Merge waits for Fran.»
- S2 (issue #3 rubric, verbatim): «Built from merged dotfiles PRs (what Fran accepted), kept as the factory's "what is good" file.»
- S3 (issue #3 acceptance, verbatim): «One real dotfiles issue turned into a draft PR end to end, with the run's telemetry.» «Nothing leaves the box except the pushed branch and the draft PR.»
- S4 (design gate, docs/design/node-contract.md §6.1 and design-comment-template.md §4): the run starts only with label `factory:ready` and a `<!-- factory-design:v1 ... -->` comment valid against schemas/design-comment.schema.json; the runner pins its id, url, sha256 and updated_at into the context; `expected_files` are the allowed edit surfaces and an edit outside them trips a guard; silence in the design means stop (`needs_decision`).

Decided constraints carried over: v1 is Claude-only (factory-v1-night), so the reviewer is a separate claude node with fresh context and read-only tools, not a different model family (#3 comment); consent policy per gentle-factory#1.

## Tasks

- T1 S4 — runner `collect` subcommand: gh issue + label + design comment → context.json, design.md, branch `factory/<issue>` — pending
- T2 S1,S4 — runner: upstream handoff (`inputs` passes a node's notes to later prompts), `needs_decision` via a last line `DECISION:`, expected_files guard — pending
- T3 S2 — rubric from merged bifrost PRs and history (`layers/bifrost/rubric.md`), route inline — pending
- T4 S1 — `layers/bifrost/`: factory.json, plan/implement/review prompts, output node (push + `gh pr create --draft`) — pending
- T5 S3 — end-to-end run on one real designed bifrost issue (agy `spawn bifrost ENOENT`) — blocked: needs Fran's approval of the design comment and `factory:ready`

## Log

- L1 (2026-11-10, verbatim): «si! y mergeala y seguimos adelante» … «Vamos con el siguiente paso…»
- L2 (2026-11-10): No open dotfiles issue has a `factory-design:v1` comment or a `factory:ready` label (the label does not exist in FullFran/dotfiles yet), so T5 needs Fran's design first; T1-T4 can be built and tested with doubles meanwhile.
- L3 (2026-11-10, verbatim): «si! hazlo y asi probamos la fabrica», answering whether to point the factory at bifrost for the agy fix. Evidence: dotfiles #8 and #62 are already implemented, #29 needs Fran's decisions, #21's empty output does not reproduce (exit 0 in 51 s), but every agy subagent run from gentle-shell fails with `spawn bifrost ENOENT` (gentle-agents task session, even with an absolute BIFROST_BIN), because the gentle-shell supervisor runs Pi with a sanitized env (`PATH=/runtime/node/bin:/usr/bin:/bin`) and bifrost's `pi/runtime.mjs:10` spawns the bare name `bifrost`. The fix lives in FullFran/bifrost, so S1-S3 apply to a bifrost issue and the layer is `layers/bifrost/`; the runner stays repo-agnostic. Routes: all inline (one understood change per task; no parallel units).
