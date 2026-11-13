#!/usr/bin/env bash
# Launcher for the gentle-factory watcher, run by the systemd user unit
# deploy/systemd/gentle-factory-watch.service. Installed as ~/.local/bin/factory-watch.
# The repositories come from FACTORY_REPOS_FILE (format: deploy/watched-repos.example.txt), read once at start.
# No timeout and no tee: the unit supervises the process and stdout/stderr go to the journal.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

FACTORY_BIN="${FACTORY_BIN:-factory}"
FACTORY_GH_BIN="${FACTORY_GH_BIN:-gh}"
FACTORY_REPOS_FILE="${FACTORY_REPOS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/gentle-factory/watched-repos.txt}"
FACTORY_INTERVAL="${FACTORY_INTERVAL:-120}"
export FACTORY_CLAUDE_BIN="${FACTORY_CLAUDE_BIN:-claude-factory}"
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-opus-5-5}"

if ! "$FACTORY_GH_BIN" auth status >/dev/null 2>&1; then
  echo "factory-watch: gh is not authenticated" >&2
  exit 1
fi
if [ ! -f "$FACTORY_REPOS_FILE" ]; then
  echo "factory-watch: repos file not found: $FACTORY_REPOS_FILE" >&2
  exit 1
fi

exec "$FACTORY_BIN" watch --repos-file "$FACTORY_REPOS_FILE" --interval "$FACTORY_INTERVAL" "$@"
