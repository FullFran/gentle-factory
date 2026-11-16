# Research: Delivery Slicing and PR Strategies in Software Factories

| Field | Value |
| --- | --- |
| Status | Draft |
| Date | 2026-11-10 |
| Task | factory-v1-night T1 (S1) |
| Author | gentle-factory research worker |
| Edit Surface | `docs/research/delivery-slicing.md` |

## 1. Executive Summary

Autonomous software factories executing multi-issue runs face an inherent tradeoff: **generation velocity versus human review bandwidth**. Monolithic diffs cause review fatigue, superficial scrutiny, and uncaught regressions.

This research analyzes how reference factories turn multi-issue runs into pull requests (PRs), evaluating two core topologies:
- **Shape (a) — Feature Branch Rollup:** Work units accumulate on a feature branch, producing one consolidated draft PR into `main`.
- **Shape (b) — Stacked PRs to Main:** Sequential PRs target `main` directly, split by line budget or issue boundaries.

Below, we survey referents, document `gentle-ai` today, compare topologies, and recommend a design for `gentle-factory` v1.

---

## 2. Reference Factory Architectures

### 2.1 addyosmani/factory
- **Split Decision:** 1 issue = 1 PR on `claude/fq-<issue>` [VERIFIED: https://github.com/addyosmani/factory, SHA `8af1165`]. Charter stops if diff > 400 lines (`factory-implement`) [VERIFIED: gentle-factory#1 comment 6755717333]. Backpressure halts if > 3 PRs await review (`CHARTER.md:146-152`) [VERIFIED: gentle-factory#1 comment 6755717333].
- **Run State:** Git branches, run evidence files, and label queues with `factory-handoff:v1` comments (`QUEUE.md`) [VERIFIED: gentle-factory#1 comment 6755717333].
- **Chaining & Ordering:** None. Overage halts for manual decomposition [VERIFIED: CHARTER.md].
- **Human Review Gate:** Gate script emits `FACTORY_GATES: level=full status=RED|GREEN` [VERIFIED: `gates.sh:1-95`]. Verified draft PR opens for review; agents never auto-merge [VERIFIED: gentle-factory#1 comment 6755821982].

### 2.2 Cole Medin / ai-software-factory & Archon
- **Split Decision:** Batches 10–20 tickets with dependency mapping [VERIFIED: https://youtu.be/tNKmMhiOw9w; gentle-factory#1 comment 6755717274]. Routes by complexity: simple tasks skip heavy verification; complex tasks trigger deep decomposition [VERIFIED: https://youtu.be/YHKuUjicB3M; gentle-factory#1 comment 6755940618].
- **Run State:** External PostgreSQL (Neon) with DB branching for rewind/replay, webhooks, and outbox streaming [VERIFIED: gentle-factory#1 comment 6755940618]. Archon manages workflow state machines [VERIFIED: gentle-factory#1 comment 6755717185].
- **Chaining & Ordering:** Shape (a) variant: ticket loops generate PRs merging into a shared `staging` branch rather than directly into `main` [VERIFIED: gentle-factory#1 comment 6755717274].
- **Human Review Gate:** (1) "Owner Decisions" queue tab in Mission Control for ambiguous stops [VERIFIED: gentle-factory#1 comment 6755940618]; (2) Human verification on staging before production deployment [VERIFIED: gentle-factory#1 comment 6755717274].

### 2.3 DoorDash agentic-orchestrator
- **Split Decision:** Phased pipeline. Integrity gate rejects `SUCCESS` if unaddressed deferred work is uncited (`deferral_prompt.go:22-46`) [VERIFIED: gentle-factory#1 comment 6755717333; doordash-oss/agentic-orchestrator, SHA `ea4f920`].
- **Run State:** JSONL + OTel wide events via outbox. Harness writes completion receipts (`completion_protocol.go:14-40`) [VERIFIED: gentle-factory#1 comment 6755717333].
- **Chaining & Ordering:** Linear pipeline; approvals and test contracts bind to `run/phase/revision` (`testing_contract.go:22-37`) [VERIFIED: gentle-factory#1 comment 6755717333].
- **Human Review Gate:** Harness validates completion artifacts and contracts before human handoff [VERIFIED: gentle-factory#1 comment 6755717333].

### 2.4 Machinist (owainlewis/machinist)
- **Split Decision:** Sandboxed attempts in gVisor emit git bundles [VERIFIED: gentle-factory#1 comment 6755717333; owainlewis/machinist, SHA `4d7d776`].
- **Run State:** Local SQLite alongside workspace + publication holds. Agents never hold GitHub credentials [VERIFIED: gentle-factory#1 comment 6755717333].
- **Chaining & Ordering:** Trusted connector ingests git bundles and manages PR sequencing [INFERRED: bundle ingest].
- **Human Review Gate:** Review in credential-less worktree (`worker.go:264-323`). Approvals bind to `attempt + head SHA` [VERIFIED: gentle-factory#1 comment 6755717333].

### 2.5 Field Precedents (Stripe, Ramp, Symphony)
- **Stripe Minions:** Ephemeral devboxes (no internet); CI capped at 2 rounds [VERIFIED: gentle-factory#1 comment 6755717333].
- **Ramp Inspect:** Filesystem snapshots; separate read/write tokens; PRs open with requester identity [VERIFIED: gentle-factory#1 comment 6755717333].
- **OpenAI Symphony:** Issue tracker as control plane (`SPEC.md`); reconcile loop with concurrency slots [VERIFIED: gentle-factory#1 comment 6755717333; openai/symphony, SHA `be10a1b`].

---

## 3. Delivery Slicing in gentle-ai Today

`gentle-ai` implements delivery slicing within Organic Driven Development (ODD), governed by `work-unit-commits` and `chained-pr` skills [VERIFIED: `~/.claude/skills/chained-pr/SKILL.md`, `~/.claude/skills/work-unit-commits/SKILL.md`].

### 3.1 Work Units and Review Budget
- Slices represent deliverable behavior (code, tests, docs committed together) [VERIFIED: `work-unit-commits/SKILL.md:26-29`].
- Bounded to **~400 authored changed lines** (`additions + deletions`, excluding generated/vendor diffs) for ≤60-minute review [VERIFIED: `chained-pr/SKILL.md:16-19`]. Artificial code compression to fit budget is prohibited [VERIFIED: `work-unit-commits/SKILL.md:32`].

### 3.2 ODD Delivery Strategies
ODD tracks line counts across commits [VERIFIED: `gentle-ai-03-agent-routing-part2.md:27`]:
- `ask-on-risk` (Default): Prompts once for chain style (`stacked-to-main` vs. `feature-branch-chain`) when lines exceed ~400 or risk escalates.
- `auto-chain`: Slices automatically above 400 lines; prompts only if chain style is unconfigured.
- `single-pr`: Emits one PR, requiring maintainer waiver (`size:exception`).
- `exception-ok`: Delivers best split with overage rationale when clean splitting is impossible (e.g., migrations).

### 3.3 Chain Topologies and Rebase Mechanics
`gentle-ai` formalizes both topologies [VERIFIED: `chained-pr/references/chaining-details.md`]:
- **Shape (b) — Stacked PRs to main:** Sequential PRs target `main` directly (`main ← PR 1 ← PR 2`). Ships fast with per-PR rollback, but intermediate states land on `main`. Downstream PRs retarget as parents merge.
- **Shape (a) — Feature Branch Chain:** Draft tracker PR targets `main` (`main ← feat/tracker ← PR 1 ← PR 2`). Children merge into tracker; `main` merges atomically after full verification.
- **Chain Context:** Every chained PR appends a metadata table (position `N of total`, base, dependencies) and ASCII diagram marking `📍 This PR`.

### 3.4 Review Gate & Unattended Execution
Interactive sessions run risk-tiered reviews (`gentle-ai review assess`). Unattended headless runs execute via `gentle-ai review start --consent granted|declined|relay`, where pre-approved issues pass `--consent granted` deterministically [VERIFIED: gentle-factory#1 comment 6756111033].

---

## 4. Architecture Comparison

| System | Delivery Shape | Split Decision | Run State Store | Chaining / Ordering | Human Review Gate |
|---|---|---|---|---|---|
| **addyosmani** | Single PR / issue | 400-line charter cap | Git branches, run logs | None; stop on overage | `gates.sh` verdict; draft PR |
| **Cole Medin** | Shape (a) Staging Rollup | 10–20 ticket batches | External PostgreSQL (Neon) | Staging branch; ticket PRs | Mission Control queue; staging test |
| **DoorDash** | Gated Phased PRs | Pipeline phases | JSONL outbox, receipts | Bound to `run/phase/rev` | Contract verification before handoff |
| **Machinist** | Bundle-isolated PRs | Attempt boundaries | SQLite + publication hold | Connector ingests bundles | Credential-less worktree; SHA-bound |
| **gentle-ai** | Configurable (a & b) | ~400 lines; risk tier | Local task doc + Engram | `Chain Context`; retargeting | Review lenses; non-interactive consent |

---

## 5. Recommendations for gentle-factory v1

### 5.1 Default Delivery Topology: Shape (a) (Feature Branch Rollup)

**[REC-DELIVERY-001] Shape (a) MUST be the default delivery topology for gentle-factory runs.**

In Shape (a), a multi-issue run accumulates on `feat/factory-<run-id>`, opening one consolidated draft PR into `main`.

#### Rationale
1. **Protection of `main`:** Autonomous overnight runs must not leave `main` in half-finished states if later tasks fail or trip gates.
2. **Atomic Human Gate:** Fulfills the owner contract: "human designs in issue → factory runs autonomously → human reviews draft PR" [VERIFIED: gentle-factory#1 comment 6755821982]. The owner reviews one consolidated draft PR in the morning.
3. **Granular Work Units Preserved:** The runner commits each task as a reviewable work unit (≤400 lines, code + tests + docs) via Conventional Commits. Reviewers inspect individual commits or the aggregate diff.

### 5.2 Trigger for Shape (b) (Stacked PRs to Main)

**[REC-DELIVERY-002] Shape (b) SHALL only activate when explicitly triggered by decoupled issues.**

Shape (b) (`stacked-to-main`) activates **only** when all hold:
1. **Independent Scope:** Issues have disjoint edit surfaces and no shared runtime dependencies.
2. **Low Risk:** Touches no High-Risk items: Item 1 (migrations), Item 2 (security), or Item 3 (contracts) [VERIFIED: gentle-factory#1 comment 6756672669].
3. **Explicit Directive:** The design comment specifies `delivery_strategy: stacked-to-main` or `independent_prs: true`.
4. **Backpressure Limit:** Open PRs remain within limits (`STOP_IF > 3` PRs awaiting review).

### 5.3 Receipt Persistence Across PRs

In `gentle-factory`, node flow is receipt-driven: **the next node to run is the first without a harness-written receipt** [VERIFIED: gentle-factory#1 comment 6756334363]. Receipts reference issues; one run may span multiple issues.

#### Candidate Storage Options
1. **Feature Folder (`odd/runs/<run>/`):** On-branch; travels with git; zero dependencies. Tradeoff: Appears in PR diffs unless stripped.
2. **Dedicated Branch (`factory-runs`):** Isolates state from code diffs; survives container wipes. Tradeoff: Requires branch switching during execution.
3. **Store Outside Git (SQLite / DB):** Clean git history; fast transactions. Tradeoff: Ephemeral in disposable workboxes; lost on box destruction.

#### Recommended Strategy: Dual-Layer In-Git Receipts
- **Active Execution:** Runner writes completion receipts to `odd/runs/<run-id>/receipt-<node-id>.json` on the active feature branch. Resumption reads this folder directly: the runner executes the first node lacking a receipt.
- **V1 Publication Policy:** Retain `odd/runs/<run-id>/` on the feature branch. For internal repos (`FullFran/dotfiles`), receipts in the draft PR provide full transparency.
- **Future Clean Policy (v1.1+):** Push receipts to an orphan `factory-runs` branch upon draft PR publication, removing the folder from the code PR head.

---

## 6. References

- `addyosmani/factory`: SHA `8af1165`; `CHARTER.md:146-152`; `gates.sh:1-95` [VERIFIED].
- `Cole Medin / ai-software-factory`: SHA `f6d8f69`; YouTube transcripts `tNKmMhiOw9w`, `YHKuUjicB3M` [VERIFIED].
- `doordash-oss/agentic-orchestrator`: SHA `ea4f920`; `completion_protocol.go:14-40`; `testing_contract.go:22-37` [VERIFIED].
- `owainlewis/machinist`: SHA `4d7d776`; `internal/managedworker/worker.go:264-323` [VERIFIED].
- `FullFran/gentle-factory#1`: Comments 6755717274, 6755717333, 6755940618, 6756111033, 6756334363, 6756672669 [VERIFIED].
- `gentle-ai Skills`: `chained-pr/SKILL.md`; `work-unit-commits/SKILL.md`; `gentle-ai-03-agent-routing-part2.md` [VERIFIED].
