# deploy/

Files that run the factory watcher on the execution box under a systemd user unit, so a
watcher that ends for any reason comes back and the list of watched repositories is reviewed
in git.

| File | Purpose |
| --- | --- |
| `factory-watch.sh` | Launcher: checks `gh auth status` and the repository list, then `exec factory watch --repos-file FILE --interval 120`. Overrides: `FACTORY_BIN`, `FACTORY_GH_BIN`, `FACTORY_REPOS_FILE`, `FACTORY_INTERVAL`, `FACTORY_CLAUDE_BIN` (default `claude-factory`), `ANTHROPIC_MODEL` (default `claude-opus-5-5`). |
| `watched-repos.txt` | The versioned list of watched repositories, one `OWNER/NAME` per line. |
| `systemd/gentle-factory-watch.service` | The user unit: `Restart=always`, `RestartSec=30`, no timeout. |

## Install (manual, by the owner)

Installing is a manual step on the box, outside any factory run. From a checkout of this
repository:

1. Stop the old `~/work/start-factory.sh` watcher first: only one watcher can hold `watch.lock`.
2. Install the files:

   ```bash
   install -D -m 0755 deploy/factory-watch.sh ~/.local/bin/factory-watch
   install -D -m 0644 deploy/watched-repos.txt ~/.config/gentle-factory/watched-repos.txt
   install -D -m 0644 deploy/systemd/gentle-factory-watch.service ~/.config/systemd/user/gentle-factory-watch.service
   ```

3. Optional overrides (for example `ANTHROPIC_MODEL=...`) go in
   `~/.config/gentle-factory/watch.env`.
4. Enable and start the unit, and keep the user manager running after logout:

   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now gentle-factory-watch.service
   loginctl enable-linger "$USER"
   ```

## Operate

- Follow the watcher: `journalctl --user -u gentle-factory-watch -f` and `factory status`.
- Change the list: edit `deploy/watched-repos.txt` in git, re-install it with the `install`
  line above, then `systemctl --user restart gentle-factory-watch`. The list is read once
  when the watcher starts.
- `systemctl --user stop gentle-factory-watch` stops it for good (it is not restarted); a run
  in progress may take up to `TimeoutStopSec=3600` to finish.
