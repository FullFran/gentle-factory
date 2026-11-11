# Receipt & Handoff Format Specification (gentle-factory)

| Field | Value |
| --- | --- |
| Status | draft |
| Version | 0.1.0-draft |
| Date | 2026-11-10 |
| Context | S2 (`factory-v1-night.md`), gentle-factory#1 |
| Replaces | None |

---

## 1. Architectural Philosophy: "What Would the Linux Foundation Do?"

The user design directive for `gentle-factory` establishes:
> *«lo más standard inspirado en cosas que ya se usan y funcionan un "qué haría la linux fundation"»*

When building verifiable software supply chains, continuous delivery pipelines, and event-driven architectures, the Linux Foundation, OpenSSF, and Cloud Native Computing Foundation (CNCF) do not invent bespoke, proprietary formats. Instead, they combine established specifications:

```
┌────────────────────────────────────────────────────────────────────────┐
│ CloudEvents v1.0.2 (CNCF) — Event Transport Envelope (Optional)       │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ in-toto Statement v1.0 (Linux Foundation / CNCF)                 │  │
│  │   _type: "https://in-toto.io/Statement/v1"                       │  │
│  │   subject: [ { name: "git:commit", digest: { gitCommit: ... } } ] │  │
│  │   predicateType: "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md"        │  │
│  │  ┌────────────────────────────────────────────────────────────┐  │  │
│  │  │ gentle-factory Predicate (JSON Schema 2020-12)             │  │  │
│  │  │   - References (Issue, Design Comment SHA, Commits, PR)    │  │  │
│  │  │   - OpenTelemetry GenAI Telemetry (Cost, Turns, Model)     │  │  │
│  │  │   - Outcome, Gate Verdict Line & Failure Signature         │  │  │
│  │  │   - in-toto Materials & Products                           │  │  │
│  │  └────────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Standards Evaluation

| Candidate Standard | Governing Body | Evaluation & Verdict |
|---|---|---|
| **in-toto Attestation Framework v1.0** | Linux Foundation / CNCF | **ADOPTED (Envelope & Subject model)**. in-toto is the industry standard for verifying software supply chain steps. Its `Statement/v1` envelope binds cryptographic subjects (git commits, diffs) to typed step predicates. Link metadata (`materials`, `products`, `command`, `environment`) maps directly to factory step handoffs. |
| **SLSA Provenance v1.0** | OpenSSF / Linux Foundation | **INCORPORATED (Design Patterns)**. SLSA focuses strictly on build and compilation provenance (`buildDefinition` and `runDetails`). While too narrow for generative agent reasoning and human approval gates, SLSA's separation of external parameters from resolved dependencies is incorporated into our predicate structure. |
| **OpenTelemetry GenAI Semantic Conventions** | CNCF / Linux Foundation | **ADOPTED (Telemetry model)**. OpenTelemetry defines standardized attributes for generative AI (`gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.*`) and distributed tracing (`trace_id`, `span_id`, W3C `traceparent`). Claude Code headless natively honors `TRACEPARENT`. Used directly for all cost, turn, and token measurements. |
| **CloudEvents v1.0.2** | CNCF | **ADOPTED (Transport Envelope)**. CloudEvents provides a vendor-neutral envelope (`specversion`, `id`, `source`, `type`, `time`, `data`) for routing events across message buses, webhooks, or Orca task coordination channels. |
| **JSON Schema 2020-12** | Open Standard | **ADOPTED (Contract Schema)**. Schemas are defined using Draft 2020-12 under `schemas/`, aligned with HCS schema standards (`$schema`, URN `$id`). |

---

## 2. Receipt Specification

### 2.1 The Core Invariant: Reference, Never Copy

To avoid synchronization drift, context explosion, and data leakage, receipts **must reference, never copy**:
1. **GitHub Issues**: Stored as `{ "number": <N>, "url": "..." }`. No issue bodies, descriptions, or comment threads are copied into receipts.
2. **Design Comment Version**: Stored as `{ "id": <ID>, "url": "...", "sha256": "<hash>", "updated_at": "..." }`. The body text is not copied; the cryptographic SHA-256 hash guarantees tamper detection and version freezing.
3. **VCS Commits and Pull Requests**: Stored as `{ "base_commit": "...", "head_commit": "...", "branch": "...", "pull_request": { "number": <M>, "url": "..." } }`. No full patches or raw diffs are stored inside the receipt.

### 2.2 Envelope Fields (`in-toto Statement v1.0`)

| Field | Type | Description |
|---|---|---|
| `_type` | `string` | Must be `"https://in-toto.io/Statement/v1"`. |
| `subject` | `array` | List of target artifacts produced or verified. Each item has `name` (e.g. `git:commit`) and a `digest` object (e.g. `{"gitCommit": "...", "sha256": "..."}`). |
| `predicateType` | `string` | Must be `"https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md"`. |
| `predicate` | `object` | The typed receipt payload defined below. |

### 2.3 Predicate Schema Breakdown

The receipt predicate is defined in [schemas/receipt.schema.json](../../schemas/receipt.schema.json):

1. **Identification**:
   - `version`: SemVer string (`0.1.0`).
   - `run_id`: Unique run identifier (e.g. `run_98f7e2a1-b4c3-...`).
2. **Step (`step`)**:
   - `node_id`: String identifier of the node (e.g. `implement`, `verify_gate`, `design_gate`).
   - `node_kind`: Enum: `"code"`, `"agent"`, `"human_gate"`.
   - `attempt`: 1-based attempt sequence number for this node.
3. **References (`references`)**:
   - `repository`: Repository in `owner/repo` format.
   - `issue`: `{ "number": <int>, "url": "<uri>" }`.
   - `design_comment`: `{ "id": <int>, "url": "<uri>", "sha256": "<hex>", "updated_at": "<iso8601>" }`.
   - `vcs`: Git commit hashes (`base_commit`, `head_commit`), branch name, and optional PR reference. `code` and `agent` receipts must record `head_commit`: it binds the receipt to the exact code it produced or checked (see node contract §5.2).
4. **Execution (`execution`)**:
   - `engine`: Runner identity (`claude-code-headless`, `bash`, `github-human-gate`).
   - `engine_version`: Version string of engine.
   - `command`: Array of command line arguments executed.
   - `tools_allowed`: Array of tool permissions granted to the node.
   - `caps`: Limits enforced (`max_turns`, `max_budget_usd`, `timeout_seconds`).
5. **Telemetry (`telemetry`)**:
   - OpenTelemetry GenAI semantic convention fields: `gen_ai_system`, `request_model`, `tokens` (`input_tokens`, `output_tokens`, `total_tokens`).
   - Trace context: `trace_id`, `span_id`, `traceparent`.
   - Runner metrics: `total_cost_usd`, `num_turns`, `duration_ms`.
6. **Outcome (`outcome`)**:
   - `status`: Enum: `"success"`, `"failure"`, `"needs_decision"`, `"misconfigured"`.
   - `terminal_reason`: Normalized string (e.g., `completed`, `gate_failed`, `max_turns_exceeded`, `human_approved`).
   - `exit_code`: Numeric process exit code if applicable. A `success` receipt may only carry `exit_code: 0`.
7. **Gate Verdict (`gate`)**:
   - `status`: Enum: `"GREEN"`, `"RED"`, `"MISCONFIGURED"`. A `success` receipt may only carry `GREEN`.
   - `verdict_line`: Exact terminal output string (e.g. `FACTORY_GATES: status=GREEN level=standard passed=12 failed=0`). On a `success` receipt it must report `status=GREEN`.
   - `checks_passed`: Array of passing check names.
   - `checks_failed`: Array of failing check names.
8. **Failure Signature (`failure_signature`)**:
   - Required on every `failure` receipt. Deterministic SHA-256 hash or normalized fingerprint of the error. Used by the runner to enforce retry caps: if two consecutive attempts fail with the identical signature, the runner halts and requests human intervention.
9. **Materials & Products (`materials`, `products`)**:
   - In-toto compliant list of consumed inputs and generated outputs with cryptographic digests.

---

## 3. Concrete Example Receipts

### Example 1: Agent Implementation Node Receipt (`implement`)

An agent node executes Claude Code headless to produce a git commit from a design comment.

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "git:commit",
      "digest": {
        "gitCommit": "d4e1f7a29b8c3d0e1f2a3b4c5d6e7f8a9b0c1d2e",
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      }
    }
  ],
  "predicateType": "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md",
  "predicate": {
    "version": "0.1.0",
    "run_id": "run_98f7e2a1-b4c3-4d5e-8f90-1a2b3c4d5e6f",
    "step": {
      "node_id": "implement",
      "node_kind": "agent",
      "attempt": 1
    },
    "references": {
      "repository": "FullFran/gentle-factory",
      "issue": {
        "number": 1,
        "url": "https://github.com/FullFran/gentle-factory/issues/1"
      },
      "design_comment": {
        "id": 24681357,
        "url": "https://github.com/FullFran/gentle-factory/issues/1#issuecomment-24681357",
        "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
        "updated_at": "2026-11-10T01:15:30Z"
      },
      "vcs": {
        "base_commit": "c0ffee15deadbeef0123456789abcdef01234567",
        "head_commit": "d4e1f7a29b8c3d0e1f2a3b4c5d6e7f8a9b0c1d2e",
        "branch": "feat/factory-node-contract"
      }
    },
    "execution": {
      "engine": "claude-code-headless",
      "engine_version": "0.2.29",
      "command": [
        "claude",
        "-p",
        "--max-turns",
        "30",
        "--max-budget-usd",
        "3.00",
        "--output-format",
        "json"
      ],
      "tools_allowed": ["read", "edit", "write", "bash"],
      "caps": {
        "max_turns": 30,
        "max_budget_usd": 3.0,
        "timeout_seconds": 1800
      }
    },
    "telemetry": {
      "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
      "span_id": "00f067aa0ba902b7",
      "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      "gen_ai_system": "anthropic",
      "request_model": "claude-3-7-sonnet-20250219",
      "tokens": {
        "input_tokens": 14250,
        "output_tokens": 2840,
        "total_tokens": 17090
      },
      "total_cost_usd": 0.852,
      "num_turns": 14,
      "duration_ms": 78240
    },
    "outcome": {
      "status": "success",
      "terminal_reason": "completed",
      "exit_code": 0
    },
    "materials": [
      {
        "uri": "git:FullFran/gentle-factory@c0ffee15deadbeef0123456789abcdef01234567",
        "digest": { "gitCommit": "c0ffee15deadbeef0123456789abcdef01234567" }
      }
    ],
    "products": [
      {
        "uri": "file://docs/design/node-contract.md",
        "digest": { "sha256": "8f4e2c1a3b5d7e9f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a8b0c2d4e6f" }
      }
    ],
    "notes": "Implemented node contract specification satisfying issue #1 design comment."
  }
}
```

---

### Example 2: Code Gate Node Receipt (`verify_gate`)

A deterministic test script validates the working tree and produces a `GREEN` verdict.

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "git:commit",
      "digest": {
        "gitCommit": "d4e1f7a29b8c3d0e1f2a3b4c5d6e7f8a9b0c1d2e"
      }
    }
  ],
  "predicateType": "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md",
  "predicate": {
    "version": "0.1.0",
    "run_id": "run_98f7e2a1-b4c3-4d5e-8f90-1a2b3c4d5e6f",
    "step": {
      "node_id": "verify_gate",
      "node_kind": "code",
      "attempt": 1
    },
    "references": {
      "repository": "FullFran/gentle-factory",
      "issue": {
        "number": 1,
        "url": "https://github.com/FullFran/gentle-factory/issues/1"
      },
      "design_comment": {
        "id": 24681357,
        "url": "https://github.com/FullFran/gentle-factory/issues/1#issuecomment-24681357",
        "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
        "updated_at": "2026-11-10T01:15:30Z"
      },
      "vcs": {
        "base_commit": "c0ffee15deadbeef0123456789abcdef01234567",
        "head_commit": "d4e1f7a29b8c3d0e1f2a3b4c5d6e7f8a9b0c1d2e",
        "branch": "feat/factory-node-contract"
      }
    },
    "execution": {
      "engine": "bash",
      "engine_version": "5.2.21",
      "command": ["tests/gates.sh"],
      "tools_allowed": ["bash"],
      "caps": {
        "timeout_seconds": 300
      }
    },
    "telemetry": {
      "duration_ms": 12450
    },
    "outcome": {
      "status": "success",
      "terminal_reason": "gate_passed",
      "exit_code": 0
    },
    "gate": {
      "status": "GREEN",
      "verdict_line": "FACTORY_GATES: status=GREEN level=standard passed=12 failed=0",
      "checks_passed": ["unit_tests", "schema_validation", "prove_test"],
      "checks_failed": []
    },
    "notes": "Deterministic gate verified successfully on commit d4e1f7a."
  }
}
```

---

### Example 3: Human Gate Node Receipt (`design_gate`)

A human maintains the design on the issue and applies the `factory:ready` label.

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "issue:comment",
      "digest": {
        "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f"
      }
    }
  ],
  "predicateType": "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md",
  "predicate": {
    "version": "0.1.0",
    "run_id": "run_98f7e2a1-b4c3-4d5e-8f90-1a2b3c4d5e6f",
    "step": {
      "node_id": "design_gate",
      "node_kind": "human_gate",
      "attempt": 1
    },
    "references": {
      "repository": "FullFran/gentle-factory",
      "issue": {
        "number": 1,
        "url": "https://github.com/FullFran/gentle-factory/issues/1"
      },
      "design_comment": {
        "id": 24681357,
        "url": "https://github.com/FullFran/gentle-factory/issues/1#issuecomment-24681357",
        "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
        "updated_at": "2026-11-10T01:15:30Z"
      }
    },
    "execution": {
      "engine": "github-human-gate",
      "tools_allowed": ["gh:api:read"]
    },
    "outcome": {
      "status": "success",
      "terminal_reason": "human_approved"
    },
    "notes": "Human ready signal verified: label factory:ready applied by repo owner."
  }
}
```

---

### Example 4: Gate Failure Receipt with Failure Signature

When a gate fails, the receipt captures the `RED` verdict and computes a `failure_signature` over the failing checks.

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "git:commit",
      "digest": {
        "gitCommit": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
      }
    }
  ],
  "predicateType": "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md",
  "predicate": {
    "version": "0.1.0",
    "run_id": "run_98f7e2a1-b4c3-4d5e-8f90-1a2b3c4d5e6f",
    "step": {
      "node_id": "verify_gate",
      "node_kind": "code",
      "attempt": 1
    },
    "references": {
      "repository": "FullFran/gentle-factory",
      "issue": {
        "number": 1,
        "url": "https://github.com/FullFran/gentle-factory/issues/1"
      },
      "design_comment": {
        "id": 24681357,
        "url": "https://github.com/FullFran/gentle-factory/issues/1#issuecomment-24681357",
        "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
        "updated_at": "2026-11-10T01:15:30Z"
      },
      "vcs": {
        "base_commit": "c0ffee15deadbeef0123456789abcdef01234567",
        "head_commit": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
        "branch": "feat/factory-node-contract"
      }
    },
    "execution": {
      "engine": "bash",
      "command": ["tests/gates.sh"],
      "tools_allowed": ["bash"],
      "caps": {
        "timeout_seconds": 300
      }
    },
    "telemetry": {
      "duration_ms": 5420
    },
    "outcome": {
      "status": "failure",
      "terminal_reason": "gate_failed",
      "exit_code": 1
    },
    "gate": {
      "status": "RED",
      "verdict_line": "FACTORY_GATES: status=RED level=standard passed=10 failed=2",
      "checks_passed": ["unit_tests"],
      "checks_failed": ["schema_validation", "prove_test"]
    },
    "failure_signature": "fa82c0e29b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e",
    "notes": "Gate failed on schema validation and prove_test; signature computed from failed check names."
  }
}
```

---

## 4. Storage Independence & Transport

### 4.1 Storage Decoupling

The receipt format is strictly decoupled from where receipts are stored. A separate worker is evaluating optimal storage backends (e.g. filesystem directory `.factory/receipts/`, git notes `refs/notes/factory-receipts`, an SQLite database, or an S3 bucket). 

Because the receipt is a self-contained in-toto Statement JSON document:
- Any storage system capable of storing raw strings or blobs can store and retrieve receipts;
- The runner needs only two primitive operations: `append_receipt(receipt)` and `get_receipts_for_run(run_id)`.

### 4.2 CNCF CloudEvents Transport Envelope

When receipts are transmitted across networks, event buses, or Orca orchestration messages (`orca orchestration send`), they may be wrapped in a CNCF CloudEvents v1.0.2 envelope ([schemas/cloudevents-envelope.schema.json](../../schemas/cloudevents-envelope.schema.json)):

```json
{
  "specversion": "1.0",
  "id": "evt_1234567890",
  "source": "https://github.com/FullFran/gentle-factory/runners/runner-01",
  "type": "org.gentle-factory.node.receipt",
  "time": "2026-11-10T01:17:00Z",
  "subject": "run_98f7e2a1-b4c3-4d5e-8f90-1a2b3c4d5e6f/implement",
  "datacontenttype": "application/json",
  "dataschema": "urn:gentle-factory:schema:receipt:0.1",
  "data": {
    "_type": "https://in-toto.io/Statement/v1",
    "subject": [
      {
        "name": "git:commit",
        "digest": {
          "gitCommit": "d4e1f7a29b8c3d0e1f2a3b4c5d6e7f8a9b0c1d2e"
        }
      }
    ],
    "predicateType": "https://github.com/FullFran/gentle-factory/blob/receipt-v0.1/docs/design/receipt-format.md",
    "predicate": {
      "version": "0.1.0",
      "run_id": "run_98f7e2a1-b4c3-4d5e-8f90-1a2b3c4d5e6f",
      "step": {
        "node_id": "implement",
        "node_kind": "agent",
        "attempt": 1
      },
      "references": {
        "repository": "FullFran/gentle-factory",
        "issue": {
          "number": 1,
          "url": "https://github.com/FullFran/gentle-factory/issues/1"
        },
        "design_comment": {
          "id": 24681357,
          "url": "https://github.com/FullFran/gentle-factory/issues/1#issuecomment-24681357",
          "sha256": "7a3f8c2e1b4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f",
          "updated_at": "2026-11-10T01:15:30Z"
        },
        "vcs": {
          "head_commit": "d4e1f7a29b8c3d0e1f2a3b4c5d6e7f8a9b0c1d2e"
        }
      },
      "execution": {
        "engine": "claude-code-headless",
        "tools_allowed": ["read", "edit", "write", "bash"]
      },
      "outcome": {
        "status": "success",
        "terminal_reason": "completed"
      }
    }
  }
}
```

---

## 5. Handoff Protocol Between Nodes

The receipt serves as the immutable handoff between workflow nodes:

1. **Upstream Verification**:
   When node `N+1` initializes, the runner passes the array of upstream receipts. The node (or runner) verifies that node `N` completed with `outcome.status == "success"`.
2. **Subject Continuity**:
   Node `N+1` reads the `subject` of node `N`'s receipt. For example, the `verify_gate` node inspects `subject[name="git:commit"].digest.gitCommit` to ensure it tests the exact commit produced by the `implement` node.
3. **Trace Continuation**:
   Node `N+1` inherits the `trace_id` and W3C `traceparent` from node `N`, ensuring distributed traces remain unified across the entire factory run.

### 5.1 OTLP Trace Export (#13)

When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, `factory run` posts the node attempts of the invocation as one OTLP/HTTP JSON `ExportTraceServiceRequest` to `<endpoint>/v1/traces` once the invocation ends, whatever the run status. A receipt and its span are the same thing: the span's `traceId` and `spanId` are the receipt's `telemetry.trace_id` and `telemetry.span_id`, and its duration is `telemetry.duration_ms`. Receipts themselves do not change.

Pinned versions (the GenAI conventions are in development stability):

- GenAI semantic conventions: `open-telemetry/semantic-conventions-genai@e713f345c1d5f6d888b2f3bbddf1a863395b784c` (development stability).
- OpenTelemetry semantic conventions: v1.45.0.
- OTLP: 1.11.1 (JSON encoding over HTTP).

Mapping:

| Span | Name | Attributes (only when the receipt has the value) |
|---|---|---|
| Resource | — | `service.name` = `factory-<factory>`, `factory.name`, `run.id`, `task.id`; scope `gentle-factory` |
| Invocation (root) | `invoke_workflow <factory>` | `gen_ai.operation.name` = `invoke_workflow`; `spanId` = parent id of the `TRACEPARENT` given to the nodes of this invocation |
| Agent node attempt | `invoke_agent <node_id>` | `gen_ai.operation.name` = `invoke_agent`, `gen_ai.agent.name` = node id, `gen_ai.provider.name` = `telemetry.gen_ai_system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `factory.total_cost_usd` (double) |
| Code node attempt | `execute_tool <node_id>` | `gen_ai.operation.name` = `execute_tool`, `gen_ai.tool.name` = node id, `factory.exit_code` |
| Both node kinds | — | `factory.attempt`, `factory.outcome.status`; when the status is not `success`, `error.type` = `outcome.terminal_reason` and span status code `2` (error) |

No attribute carries `execution.command`, `notes`, logs, prompts, outputs or file paths. A resumed run exports a new root for the new invocation in the same trace; attempts of earlier invocations are not exported again.

---

## 6. External References & Verification Status

| Reference | Scope / Feature Cited | Verification Status | Citation / Evidence |
|---|---|---|---|
| **in-toto Attestation Framework** | Statement v1.0 schema & Link model | VERIFIED | https://github.com/in-toto/attestation/blob/main/spec/v1.0/statement.md |
| **OpenTelemetry GenAI** | Semantic conventions for model, tokens, cost | VERIFIED | https://opentelemetry.io/docs/specs/semconv/gen-ai/ |
| **OpenTelemetry GenAI (pinned)** | `invoke_workflow`, `invoke_agent`, `execute_tool` spans and attributes | PINNED | `open-telemetry/semantic-conventions-genai@e713f345c1d5f6d888b2f3bbddf1a863395b784c` (development stability); semantic-conventions v1.45.0; OTLP 1.11.1 |
| **W3C Trace Context** | `traceparent` header specification | VERIFIED | https://www.w3.org/TR/trace-context/ |
| **CNCF CloudEvents** | CloudEvents v1.0.2 event envelope specification | VERIFIED | https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md |
| **JSON Schema 2020-12** | Core specification and vocabulary | VERIFIED | https://json-schema.org/draft/2020-12/schema |
| **addyosmani/factory** | Machine-readable gate verdict format | VERIFIED | `template/.claude/scripts/gates.sh` (repo commit `8af1165`) |
| **DoorDash agentic-orchestrator** | Harness-written completion receipts | VERIFIED | `internal/agent/completion_protocol.go:14-40` (repo commit `ea4f920`) |
