<p align="center"><img src="assets/logo.svg" alt="gentle-factory logo" width="120" height="120"></p>

# gentle-factory

**You design the change in a GitHub issue; the factory turns it into a draft pull request.**

gentle-factory is a software factory built from [gentle-ai](https://github.com/Gentleman-Programming/gentle-ai) pieces. A human writes a design as an issue comment and adds the `factory:ready` label. From there the factory runs alone: it plans, implements, runs the design's checks, reviews the change with a separate agent and opens a **draft** PR. Merging stays with a human.

The factory knows no repository in advance. Everything specific to a repository comes from the issue's design and from the repository itself (its `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, CI and scripts), read at run time.

## How a run works

```text
issue + design comment ──► collect ──► plan ──► implement ──► tests ──► review ──► output ──► draft PR
   (factory:ready)          (code)    (agent)    (agent)     (code)    (agent)     (code)
                                                    ▲                     │
                                                    └──── FALLO: retry ───┘
```

| Node | Kind | What it does |
|---|---|---|
| `collect` | code | Reads the issue, pins the design comment by hash, creates `factory/<issue>` and checks that the design's `done_when` **fails** before any change. |
| `plan` | agent, read-only | Plans the change against the design. |
| `implement` | agent | Edits and commits on `factory/<issue>`, within the design's `expected_files`. |
| `tests` | code | Runs every `done_when` check from the design. |
| `review` | agent, read-only | A separate agent judges the change; `FALLO:` sends it back to `implement`. |
| `output` | code | Pushes the branch and opens a draft PR with the run's telemetry. |

The harness closes a node, not the agent: a node completes only when the harness has checked its outputs and written a receipt. Every run leaves one receipt per node attempt, so a stopped run can be resumed and audited.

## Quick start

Requirements: Go 1.22+, Git, an authenticated [`gh`](https://cli.github.com/) and [Claude Code](https://claude.com/claude-code) (`claude`).

```bash
go install github.com/FullFran/gentle-factory/cmd/factory@latest

# 1. Check a design before labelling the issue (local, no network)
factory design check design.md --repo-dir /path/to/target --issue 42

# 2. Run one issue end to end: clone, run, archive receipts, clean up
factory start OWNER/NAME#42

# Or keep watching repositories for issues labelled factory:ready
factory watch --repo OWNER/NAME --max-open-prs 3
```

Write the design with [the design comment template](docs/design/design-comment-template.md); it must end in a `<!-- factory-design:v1 {...} -->` block valid against [the design schema](schemas/design-comment.schema.json). The pipeline is embedded in the binary, so an installed `factory` needs no checkout of this repository.

## Commands

| Command | Purpose |
|---|---|
| `factory design check` | Verify a design comment locally before `factory:ready`. |
| `factory start OWNER/NAME#N` | Run one issue end to end in a throwaway clone. |
| `factory watch` | Start `factory:ready` issues as they appear, with back-pressure on open draft PRs. |
| `factory collect` / `factory run` | The two halves of `start`, for running a custom spec by hand. |
| `factory report` | Comment the outcome on the issue and swap its labels. |
| `factory summary` / `factory status` | Cost, duration and outcome of past runs; state of the watcher. |
| `factory panel` | Local, read-only web UI over the receipts (loopback only by default). |
| `gates/prove-test.sh` | Prove a new test fails without the fix, in a disposable worktree. |

Every command, flag and exit code: [docs/reference.md](docs/reference.md).

## Safety

The agents run with edit and shell tools on the content of the issue and the target repository. Run the factory on input you trust, inside a disposable machine or container, with credentials scoped to the repositories it watches. It never merges: every change ends as a draft PR for a human to review. To run the watcher as a supervised service, see [deploy/](deploy/README.md).

## Documentation

| Doc | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Flow, components, lifecycles and decisions. |
| [docs/reference.md](docs/reference.md) | Commands, spec format, gates and pipeline in detail. |
| [docs/design/](docs/design) | Design comment template, node contract and receipt format. |
| [catalog/](catalog/README.md) | The [HCS](https://github.com/FullFran/hcs) catalog of the embedded pipeline. |

## Tests

```bash
bash tests/runner-test.sh     # the runner, with gh and claude doubles; spends nothing
bash tests/pipeline-test.sh   # the pipeline's code nodes
bash tests/start-test.sh      # start and watch against a local bare origin
```

The rest of `tests/` follows the same pattern; each script is self-contained.

## License

[Apache License 2.0](LICENSE).
