# deploy/

Files that run the factory watcher on the machine that executes runs, under a systemd user unit, so a
watcher that ends for any reason comes back and the list of watched repositories is reviewed
in git.

| File | Purpose |
| --- | --- |
| `factory-watch.sh` | Launcher: checks `gh auth status` and the repository list, then `exec factory watch --repos-file FILE --interval 120`. Overrides: `FACTORY_BIN`, `FACTORY_GH_BIN`, `FACTORY_REPOS_FILE`, `FACTORY_INTERVAL`, `FACTORY_CLAUDE_BIN` (default `claude-factory`), `ANTHROPIC_MODEL` (default `claude-opus-5-5`). |
| `watched-repos.example.txt` | Example of the repository list, one `OWNER/NAME` per line. The real list is deployment configuration: keep it outside this repository (for example in the configuration that provisions the machine) and install it as `~/.config/gentle-factory/watched-repos.txt`. |
| `systemd/gentle-factory-watch.service` | The user unit: `Restart=always`, `RestartSec=30`, no timeout. |

## Install

Installing is a manual step on that machine, outside any factory run. From a checkout of this
repository:

1. Stop any watcher already running there: only one watcher can hold `watch.lock`.
2. Install the files:

   ```bash
   install -D -m 0755 deploy/factory-watch.sh ~/.local/bin/factory-watch
   install -D -m 0644 deploy/systemd/gentle-factory-watch.service ~/.config/systemd/user/gentle-factory-watch.service
   ```

3. Write the repository list to `~/.config/gentle-factory/watched-repos.txt`, starting from
   `deploy/watched-repos.example.txt`, or let your provisioning write it.
4. Optional overrides (for example `ANTHROPIC_MODEL=...`) go in
   `~/.config/gentle-factory/watch.env`. The launcher expects a `claude-factory` command: a
   wrapper that runs Claude Code with a profile of its own, so your personal configuration
   never reaches the agents. To use plain `claude`, set `FACTORY_CLAUDE_BIN=claude` there.
5. Enable and start the unit, and keep the user manager running after logout:

   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now gentle-factory-watch.service
   loginctl enable-linger "$USER"
   ```

## Operate

- Follow the watcher: `journalctl --user -u gentle-factory-watch -f` and `factory status`.
- Change the list: update `~/.config/gentle-factory/watched-repos.txt` where it is managed,
  then `systemctl --user restart gentle-factory-watch`. The list is read once when the
  watcher starts.
- `systemctl --user stop gentle-factory-watch` stops it for good (it is not restarted); a run
  in progress may take up to `TimeoutStopSec=3600` to finish.
