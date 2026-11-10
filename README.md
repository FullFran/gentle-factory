# gentle-factory

A software factory built from [gentle-ai](https://github.com/Gentleman-Programming/gentle-ai) pieces, packaged as composable [HCS](https://github.com/FullFran/hcs) packages: nodes, run adapters and gates. A human designs the work in an issue; once the design is marked ready, the factory runs alone up to a draft PR. A concrete factory (for example, issue to draft PR for one repository) is a layer of those packages, assembled and run by the [metaharness](https://github.com/FullFran/metaharness), whose `factories/` folder composes factories like this one.

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
| `layers/` | one layer per concrete factory |

## Dotfiles v1 gates (S4)

Run from this checkout (the target may be a separate repository):

```bash
bash gates/gates.sh /path/to/dotfiles <base-ref>
bash tests/gates-test.sh
```

The gate requires Bash, Git, GNU `date`/`stat`, `head`, `tr`, zsh, tmux and jq.
It reports each gate as `GATE: name=... status=... duration_ms=...`, runs all
three gates, and ends with exactly one final verdict:

```text
FACTORY_GATES: status=GREEN
```

| Gate | Scope |
|---|---|
| `shell-syntax` | Changed tracked files relative to the base (including staged/unstaged edits), selected by shell extension or shebang; `bash -n` or `zsh -n`. Deleted files and symlinks are skipped. |
| `blob-size` | Every tracked regular file in the working tree; files larger than 1 MiB fail (exactly 1 MiB is allowed). |
| `scripts-tests` | Every `scripts/tests/*-test.sh`, run with Bash from the target root, without stopping at the first failure. |

Exit codes are `0` (GREEN), `1` (RED), and `2` (MISCONFIGURED).
Missing tools, an invalid base, an absent/empty test directory, or an unavailable
test (exit 77, 126 or 127) are MISCONFIGURED. MISCONFIGURED takes precedence over
RED, so incomplete coverage cannot be mistaken for a passing run.
Tests and their output are not a security boundary; run trusted code in a disposable workbox.

### Prove a regression test

Commit the implementation and its tests, leave the target tree clean (including
no untracked files), then run from the target repository:

```bash
bash /path/to/gentle-factory/gates/prove-test.sh <base-ref> -- bash scripts/tests/example-test.sh
# Override test-path detection when needed (repeat --test-path for multiple paths):
bash /path/to/gentle-factory/gates/prove-test.sh <base-ref> --test-path checks -- bash checks/regression.sh
```

The proof creates a detached worktree under `/tmp`, keeps HEAD's tests, restores
non-test paths to the base, and runs the command there. Use repository-relative
test commands: absolute paths back into the original checkout bypass the proof.
Default test detection covers `test/`, `tests/`, `__tests__/`, and conventional
`*.test.*`, `*.spec.*`, `test_*`, `*_test.*`, `spec_*`, and `*_spec.*` names.
An explicit `--test-path` replaces those defaults. This is a base-to-HEAD
comparison, not a merge-base comparison.

The final line is `PROOF: status=PROVEN|NOT_PROVEN|MISCONFIGURED reason=...`
(with one concrete status and reason). A nonzero test exit proves the
counterfactual; a passing test is NOT_PROVEN. Missing commands, skipped tests,
signals, dirty trees and absent non-test changes are MISCONFIGURED. Exit codes
are respectively `0`, `1`, and `2`. Run the full gate separately to establish
that the fixed version passes: proof alone does not establish correctness.
The caller's tree and index are never edited. The temporary worktree is removed
on exit, command error, or catchable interrupt; cleanup failure reports its path.
SIGKILL or host failure cannot run cleanup and may leave a `/tmp/gentle-factory-proof.*`
worktree requiring manual removal with `git worktree remove --force <path>`.

### Evidence and limits

- **VERIFIED:** the dotfiles [CI workflow](https://github.com/FullFran/dotfiles/blob/main/.github/workflows/ci.yml) checks shell syntax, tracked-file size, and `scripts/tests/*-test.sh` with zsh, tmux and jq installed. This gate narrows syntax to changed files and intentionally treats CI skips (exit 77) as MISCONFIGURED.
- **VERIFIED:** the [upstream proof script](https://github.com/addyosmani/factory/blob/main/template/.factory/scripts/prove-test.sh) separates tests from non-test changes and requires the test to fail without the fix. This implementation uses a disposable worktree instead of reverse-applying a patch to the caller's checkout.
- Non-script configuration changes (for example nvim or zsh configuration) have no behavioral tests in this v1 gate. Syntax checks, where applicable, do not establish that the configuration works.
- The local contract tests use throwaway Git repositories and dependency doubles; they verify orchestration and checker selection, not zsh/tmux/jq themselves. An actual dotfiles gate run still requires those tools. Scratch directories are created outside the checkout in `/tmp` and removed by the tests.
