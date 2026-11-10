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

- T1 S4 — runner `collect` subcommand: gh issue + label + design comment → context.json, design.md, branch `factory/<issue>` — done, inline, d3e39f0
- T2 S1,S4 — runner: upstream handoff (`inputs` passes a node's full output to later prompts), `needs_decision` via a last line `DECISION:`, expected_files guard — done, inline, d3e39f0
- T3 S2 — rubric from merged bifrost PRs and history (in `layers/bifrost/review.md`, the reviewer's prompt), route inline — done, e74557b
- T4 S1 — `layers/bifrost/`: factory.json, plan/implement/review prompts, output node (push + `gh pr create --draft`) — done, inline, e74557b
- T5 S3 — end-to-end run on one real designed bifrost issue (agy `spawn bifrost ENOENT`) — done: FullFran/bifrost#5 (draft), run_567ea560-1ba4-4786-bf54-808741d0b4f6; runner fix 56de1eb

## Log

- L1 (2026-11-10, verbatim): «si! y mergeala y seguimos adelante» … «Vamos con el siguiente paso…»
- L2 (2026-11-10): No open dotfiles issue has a `factory-design:v1` comment or a `factory:ready` label (the label does not exist in FullFran/dotfiles yet), so T5 needs Fran's design first; T1-T4 can be built and tested with doubles meanwhile.
- L3 (2026-11-10, verbatim): «si! hazlo y asi probamos la fabrica», answering whether to point the factory at bifrost for the agy fix. Evidence: dotfiles #8 and #62 are already implemented, #29 needs Fran's decisions, #21's empty output does not reproduce (exit 0 in 51 s), but every agy subagent run from gentle-shell fails with `spawn bifrost ENOENT` (gentle-agents task session, even with an absolute BIFROST_BIN), because the gentle-shell supervisor runs Pi with a sanitized env (`PATH=/runtime/node/bin:/usr/bin:/bin`) and bifrost's `pi/runtime.mjs:10` spawns the bare name `bifrost`. The fix lives in FullFran/bifrost, so S1-S3 apply to a bifrost issue and the layer is `layers/bifrost/`; the runner stays repo-agnostic. Routes: all inline (one understood change per task; no parallel units).
- L4 (2026-11-10): T1-T4 GREEN. RED first: 26 new runner checks failed, then runner 71/71, layer 9/9, gates 28/28, schemas 23/23. Found while testing: a read_only node defaults to checker and re-runs after every commit, so the planner is `role: producer, read_only: true`. Agent notes are truncated to the last 2000 runes, so handoff reads the full answer from `<run_dir>/outputs/<node>.md`. Inside gentle-shell: PATH has no ~/.local/bin, HOME is redirected to gentle-shell's own home and BIFROST_BIN is dropped, so the bifrost fix must use os.userInfo().homedir. Design draft for bifrost#4 validates against the schema. Next: Fran approves the design, it is posted with label `factory:ready`, then collect + run on a fresh clone.
- L5 (2026-11-10): End to end on FullFran/bifrost#4 → draft PR FullFran/bifrost#5 with telemetry (run run_567ea560…, 3.45 USD list price on the claude.ai subscription; 6.62 USD across the 4 runs). Receipts kept in ~/.local/share/gentle-factory/runs. Runs 1 and 3 stopped on legitimate planner DECISIONs (hint in /bifrost too; ENOENT only), run 2 on a done_when bug in the design (node not on /usr/bin), each fixed in the design comment. Run 4: review caught a local path in the PR summary; runner bug found: a failed checker was reused after an answer-only producer retry (HEAD unchanged) until retries ran out; fixed in 56de1eb with a regression test, then the same run resumed from receipts to COMPLETE. Gaps seen: factory agents load the user's global CLAUDE.md and output style (Spanish text and a Risk line in the PR body); the reviewer reports Bash denied despite its git allowlist; the PR's "What" section shows the last implement answer (the feedback fix) before the full summary; the output node is missing from the telemetry table (its receipt is written after). Spans: FullFran/gentle-factory#13.
