# Design Comment Template Specification (gentle-factory)

| Field | Value |
| --- | --- |
| Status | draft |
| Version | 0.1.0-draft |
| Date | 2026-11-10 |
| Context | S3 (`factory-v1-night.md`), gentle-factory#1 |
| Replaces | None |

---

## 1. Purpose & Principles

The core operational thesis of `gentle-factory` is:
> *«el objetivo es conseguir un gentle-ai pero que la intervención humana solo esté en el diseño, se deje el diseño como comentario en issue y una vez se considera que tiene suficiente diseño que funcione solo hasta tener una pr en draft.»* (owner, 2026-11-10, design issue)

To achieve reliable autonomous execution without human micromanagement, human judgment is concentrated in the **Design Comment** posted on the GitHub issue. The factory consumes this design comment as its sole immutable specification.

### 1.1 The Golden Rule: Default Deny ("Silence in the Design Means Stop")

Autonomous agents fail catastrophically when they guess intent or invent missing specifications. In gentle-factory:
- **Default Deny**: Any architectural decision, contract change, dependency addition, or interface choice **not explicitly authorized** in the design comment is strictly forbidden.
- **Silence Means Stop**: If an agent node hits an ambiguity, unforeseen edge case, or trade-off not answered by the design comment, **it must stop immediately**. It emits `status="needs_decision"`, records the question on the issue (and Orca ask queue), and pauses the run. It is strictly forbidden from "doing what seems best" or inventing requirements.

---

## 2. Format & Anatomy

The design comment employs a dual-layer architecture:
1. **Machine-Readable Metadata Block**: An HTML comment block (`<!-- factory-design:v1 ... -->`) containing structured JSON validated against [schemas/design-comment.schema.json](../../schemas/design-comment.schema.json).
2. **Human-Readable Specification**: Standardized Markdown sections structured for clear human authoring and fast LLM comprehension.

```
┌──────────────────────────────────────────────────────────────┐
│ GitHub Issue Comment Body                                    │
│                                                              │
│  <!-- factory-design:v1                                      │
│  {                                                           │
│    "schema_version": "1.0",                                  │
│    "issue": 1,                                               │
│    "ready_signal": "factory:ready",                          │
│    "done_when": "bash tests/verify.sh",                      │
│    "expected_files": [ "src/...", "tests/..." ],             │
│    "gate_level": "standard"                                  │
│  }                                                           │
│  -->                                                         │
│                                                              │
│  # Feature Title & Summary                                   │
│  ## 1. Done When (Checkable Acceptance Criteria)             │
│  ## 2. Expected Files & Allowed Edit Surfaces                │
│  ## 3. Decisions Already Taken                               │
│  ## 4. Non-Goals & Prohibited Changes                        │
│  ## 5. Invariants & Fallback Guidance                        │
└──────────────────────────────────────────────────────────────┘
```

The optional JSON member `slice` (boolean, default `false`) is set to `true` when the design delivers only part of the issue: the draft PR then starts with `Part of #<issue>` instead of `Closes #<issue>`, so merging it does not close the issue.

---

## 3. Section Specifications

### 3.1 `done_when` (Machine-Checkable Acceptance Criteria)

A natural language goal (e.g. "make it work") cannot be verified deterministically. The design must provide a machine-checkable command or test script:
- Must execute locally without interactive prompts;
- Must exit with status code `0` on success and non-zero on failure;
- Must fail before the change: `collect` runs `done_when` with `bash -c` before any change and rejects exit `0`, exit `126`/`127` (command not found or not executable, which proves nothing) and a timeout. A `done_when` that runs a test file the change will add must first check that the file exists (`test -f tests/x.sh && bash tests/x.sh`). Run it on the default branch and confirm it fails with a status other than `126` or `127`;
- Examples:
  - `test -f tests/test_node_contract.sh && bash tests/test_node_contract.sh`
  - `pytest tests/test_receipt.py -k test_validation`
  - `cargo test --test gate_verification`

Before adding the ready signal, run `factory design check design.md --repo-dir DIR` on the comment body saved to a file, with `DIR` a clean checkout of the default branch: it applies the same block checks as `collect`, requires the closing ambiguity rule line and confirms that `done_when` fails there, without `gh`.

### 3.2 Expected Files (`files_expected`)

Defines the **allowed edit surfaces** for the factory.
- Prevents scope creep and accidental edits to shared infrastructure;
- The factory enforces that any modification outside these paths trips a policy guard;
- Gate scripts and security configurations (e.g. `.factory/gates.conf`) are protected and must never be listed in expected files.
- Paths must be normalized and repository-relative. The schema rejects absolute paths, `.` and `..` segments, empty segments (`//`) and the protected paths `.factory/`, `.git/`, `odd/runs/` and `gates/`. A glob that happens to match a protected path still grants nothing: the runner's protected-path guard always wins.
- `done_when` must be a non-empty command; an empty command would always "pass".

### 3.3 Decisions Already Taken

Explicitly records technical choices, library versions, data structures, naming conventions, and trade-offs already settled by the human maintainer. Agents must implement these decisions directly rather than debating alternatives.

### 3.4 Non-Goals

Explicitly lists what the factory **must not do**. Examples:
- "Do not introduce external npm dependencies."
- "Do not refactor existing database schemas."
- "Do not modify the public API exported by `index.ts`."

### 3.5 Invariants & Fallback Guidance

Names existing helper functions, shared state parsers, or normalizers that must be reused. Reiterates that any unaddressed ambiguity triggers an immediate stop.

### 3.6 A design is self-contained

Agent nodes read the issue body and the design comment only. They cannot read other issue comments, linked issues or the network. Anything the change must quote (a decision record, a list of answers) is copied into the design.

---

## 4. The Human Ready Signal & Version Pinning

### 4.1 The Ready Signal (`factory:ready`)

To prevent the factory from acting on incomplete drafts, the run will not begin until an authorized maintainer applies the **`factory:ready`** label to the issue.

### 4.2 Cryptographic Version Pinning

1. When the `design_gate` node executes, it locates the latest comment with the `factory-design:v1` block.
2. It computes the SHA-256 digest of the entire comment body (`sha256(comment.body)`).
3. The runner records `design_comment.id`, `design_comment.sha256`, and `design_comment.updated_at` in the initial gate receipt.
4. If a human edits the comment while the factory is running, the hash changes. Downstream nodes verify the hash against the initial receipt; if a mismatch is detected, the run aborts immediately to prevent operating on drifting requirements.

### 4.3 Automated Review Consent Interaction

Under the gentle-factory consent policy (decided 2026-11-10 in gentle-factory#1), the presence of the `factory:ready` signal pre-grants unattended review consent:
- **Medium or High risk**: Automatically granted (outside-in audit).
- **Item 3 (Contract change)**: Granted, and flags the generated draft PR with the `contract-change` label for human attention.
- **Item 1 (Data mutation) or Item 2 (Security change)**: Granted for evaluation, but the runner stops before opening the PR and notifies the human maintainer.

---

## 5. Blank Template

Maintainers copy and paste this template into a new issue comment when ready to define a feature:

```markdown
<!-- factory-design:v1
{
  "schema_version": "1.0",
  "issue": <ISSUE_NUMBER>,
  "ready_signal": "factory:ready",
  "done_when": "<CHECKABLE_COMMAND_E.G._tests/test_x.sh>",
  "expected_files": [
    "<path/to/file1>",
    "<path/to/file2>"
  ],
  "gate_level": "standard",
  "budget_cap_usd": 3.0,
  "turn_cap": 30
}
-->

<!-- Caps: each of `budget_cap_usd`, `turn_cap` and `timeout_seconds` lowers the spec's per-node cap; a value above the spec has no effect; `budget_cap_usd` is per agent node, not a total for the run. -->

## 1. Goal & Context
<!-- One or two sentences describing what is being built and why. -->

## 2. Done When (Checkable Acceptance Criteria)
- [ ] Command `<CHECKABLE_COMMAND>` passes with exit code 0.
- [ ] Outputs match the specified contract exactly.

## 3. Expected Files & Allowed Edit Surfaces
- `<path/to/file1>`: <What changes here>
- `<path/to/file2>`: <What changes here>

## 4. Decisions Already Taken
- **Architecture**: <e.g. In-toto attestation format over custom JSON>
- **Libraries/Tools**: <e.g. Use standard python json library, no third-party network calls>
- **Error Handling**: <e.g. Return error codes rather than raising uncaught exceptions>

## 5. Non-Goals
- <What this task does NOT cover>
- <Files or subsystems that must NOT be touched>

## 6. Invariants & Fallback Guidance
- **Existing helpers to reuse**: `<function_or_module_name>`
- **Rule on ambiguity**: Silence in this design means STOP. If an unexpected decision arises, halt with status `needs_decision` and post the question on the issue.
```

---

## 6. Concrete Worked Example

Below is the design comment defining the node contract task itself:

```markdown
<!-- factory-design:v1
{
  "schema_version": "1.0",
  "issue": 1,
  "ready_signal": "factory:ready",
  "done_when": "bash tests/test_node_contract.sh",
  "expected_files": [
    "docs/design/node-contract.md",
    "docs/design/receipt-format.md",
    "docs/design/design-comment-template.md",
    "schemas/receipt.schema.json",
    "schemas/design-comment.schema.json",
    "schemas/cloudevents-envelope.schema.json"
  ],
  "gate_level": "standard",
  "budget_cap_usd": 3.0,
  "turn_cap": 30,
  "timeout_seconds": 1800
}
-->

## 1. Goal & Context
Draft the foundational node contract, receipt format, and issue design comment template for gentle-factory v1 (Claude-only, issue to draft PR). All artifacts are drafts for owner approval.

## 2. Done When (Checkable Acceptance Criteria)
- [ ] `bash tests/test_node_contract.sh` passes with exit code 0.
- [ ] `schemas/receipt.schema.json`, `schemas/design-comment.schema.json`, and `schemas/cloudevents-envelope.schema.json` validate strictly under JSON Schema Draft 2020-12.
- [ ] Example receipts in `docs/design/receipt-format.md` validate strictly against `schemas/receipt.schema.json`.

## 3. Expected Files & Allowed Edit Surfaces
- `docs/design/node-contract.md`: Node kinds (code, agent, human gate), inputs/outputs, engine caps, receipt-driven runner.
- `docs/design/receipt-format.md`: in-toto Statement v1.0 receipt schema, OTel GenAI telemetry, failure signatures, 3+ examples.
- `docs/design/design-comment-template.md`: Dual-layer specification, `done_when`, default-deny rule, template.
- `schemas/*.schema.json`: Formal JSON Schema 2020-12 contract schemas.

## 4. Decisions Already Taken
- **Flow driven by receipts**: No LangGraph; the next node is the first without a completion receipt (gentle-factory#1).
- **Standards philosophy**: "What would the Linux Foundation do": in-toto Statement v1.0, CloudEvents v1.0.2, OpenTelemetry GenAI conventions, JSON Schema 2020-12.
- **Reference, never copy**: Receipts reference issue numbers, comment SHA-256 hashes, and commit SHAs; they never duplicate full texts.
- **Unattended consent policy**: Medium/high risk grants automatically; item 3 marks PR `contract-change`; items 1/2 stop and alert.

## 5. Non-Goals
- Do not implement the runner runtime execution code (owned by FullFran/factory#2).
- Do not implement receipt storage backend (handled by storage research worker).
- Do not modify existing main branch code.

## 6. Invariants & Fallback Guidance
- **Reuse**: Follow HCS specification style (`HCS-0000..0008`) for document layout and schema conventions.
- **Rule on ambiguity**: Silence in this design means STOP. If an edge case is encountered, halt with `needs_decision` rather than guessing.
```

---

## 7. External References & Verification Status

| Reference | Scope / Feature Cited | Verification Status | Citation / Evidence |
|---|---|---|---|
| **addyosmani/factory** | `factory-handoff:v1` HTML comment metadata block | VERIFIED | `QUEUE.md:12-45` (repo commit `8af1165`) |
| **addyosmani/factory** | Disposition labels (`factory:<disposition>`) | VERIFIED | `QUEUE.md:46-60` |
| **Cole Medin (ai-software-factory)** | Vague specs cause edge-case failures | VERIFIED | `docs/incidents.md` incidents 10-12, 10-21 (repo commit `f6d8f69`) |
| **Cole Medin (Video 2)** | "Owner Decisions" queue for agent ambiguity | VERIFIED | YouTube caption track at 01:43, 08:46 (`youtu.be/YHKuUjicB3M`) |
| **design issue** | Decision: human intervention only in design | VERIFIED | Owner verbatim quote in the design issue (2026-11-10) |
| **gentle-factory#1** | Decision: unattended review consent policy | VERIFIED | gentle-factory#1 issue comment (2026-11-10) |
