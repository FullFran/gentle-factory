# factory-v1-night

Objective: overnight design drafts and the first gate for gentle-factory v1 (Claude-only, issue → draft PR for FullFran/dotfiles). Branches: one per task, PRs as drafts, never merged.
Delivery: one draft PR per task. Test runner: bash scripts with plain assertions (`tests/*.sh`).

## Specs

- S1 (delivery slicing research). User (2026-11-10): «acaba en una pr resultado de varias pr anteriores que se mergearon en ella o varias pr a criterio de como de grande es el cambio (gentle ai lo maneja un poco pero mira como lo hacen las fabricas mejor)»
- S2 (node contract, receipt and handoff format draft). User (2026-11-10): «si ahora dejalo en borrador pero mismo criterio que hcs: lo más standard inspirado en cosas que ya se usan y funcionan un "qué haría la linux fundation"»
- S3 (design comment template draft). The issue design comment the factory consumes: a checkable `done_when`, expected files, decisions taken. User (2026-11-10): «si perfecto.» (accepting the proposed template draft)
- S4 (dotfiles gate). A gate script ending in a parseable verdict line `FACTORY_GATES: status=GREEN|RED|MISCONFIGURED`, where a gate that cannot run is MISCONFIGURED, plus a prove-test script that reverts the non-test part of a change and requires the new test to fail. Accepted by the user as the v1 recommendation on 2026-11-10.
- S5 (final deck). User (2026-11-10): «quiero que al final me dejes unas diapositivas explicando todo el diseño arquitectura y demas de la fabrica. y todo lo que se ha hecho a poder ser con el qué y el por qué explicado para tontitos»

Decided constraints (all 2026-11-10, recorded in FullFran/gentle-factory#1):
- The flow between nodes is driven by HCS receipts: the next node is the first one without a receipt. LangGraph was rejected. Orca is transport only.
- Issues are the source of truth for what to do. Receipts reference issues (and the design comment version used) and never copy them. One run may span several issues.
- v1 is Claude-only.
- Review consent policy: medium or high risk always grants. Item 3 (contracts) grants and marks the PR `contract-change`. Items 1 and 2 (data, security) grant, then stop before the PR and notify.
- The repo will be public (gentle-hub). No private data (owner prompts, transcripts, Engram content) in it.

## Tasks

- T1 S1 — Orca worker (antigravity), worktree delivery-slicing, dispatch ctx_1c1484741ced — done, PR #9 merged (commit c2185f5 squashed)
- T2 S2+S3 — Orca worker (antigravity), worktree node-contract, dispatch ctx_2bb01109bab7 — done, PR #8 merged; 4 example receipts validate against schemas/receipt.schema.json
- T3 S4 — Orca worker (pi), worktree dotfiles-gate, dispatch ctx_c847ba841158 (retry; first start hit the Pi trust prompt, then the collapsed-paste issue) — done, PR #7 merged; tests/gates-test.sh 21/21 PASS and gates.sh GREEN against a real dotfiles checkout
- T4 S5 — parent — done: deck ~/Descargas/conocimiento/gentle-factory-diseno.{html,pdf} (local, 24 slides)

## Log

- L1 (2026-11-10, verbatim): «1 acaba en una pr resultado de varias pr anteriores que se mergearon en ella o varias pr a criterio de como de grande es el cambio (gentle ai lo maneja un poco pero mira como lo hacen las fabricas mejor) 2 si ahora dejalo en borrador pero mismo criterio que hcs: lo más standard inspirado en cosas que ya se usan y funcionan un "qué haría la linux fundation" 3 si perfecto. y quiero que al final me dejes unas diapositivas explicando todo el diseño arquitectura y demas de la fabrica. y todo lo que se ha hecho a poder ser con el qué y el por qué explicado para tontitos»
- L2: Route evidence: three independent units with disjoint edit surfaces (docs/research, docs/design + schemas, gates + tests), each several files of work, so they run as parallel Orca workers; the user asked for agy and Pi workers in Orca worktrees.
- L3 (2026-11-10): Run run_b912fc746597 started. A private prompt-intervention classification runs as a Claude subagent with output only under ~/Descargas/conocimiento/privado/, outside every repo, as the user authorized.
- L4 (2026-11-10, verbatim): «deja qeu hagan push y pr y mergead todo en una rama integradora que es la que revisaré yo mañana». Branch integration/factory-v1-night created from main (d217515). Workers push and open PRs with that base; the parent spot-checks and merges them there. main is never touched.
- L5 (2026-11-10): T1-T3 verified by the parent and squash-merged into integration/factory-v1-night. The private intervention classification finished (output outside every repo).
- L6 (2026-11-10): Deck delivered locally. Open items found in review: the runner must reject agent edits under odd/runs/ (not yet in the drafts); predicateType uses the domain gentle-ai.net, whose ownership is unverified; default caps are uncalibrated; `--consent granted` is untested in a box.
