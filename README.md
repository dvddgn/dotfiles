This repository is used by [Le Wagon](https://www.lewagon.com) students.

## Toolset

- [oh-my-zsh](http://ohmyz.sh/)
- [Visual Studio Code](https://code.visualstudio.com/)
- [git](https://git-scm.com/)

## bin/

Dev-workflow scripts, symlinked into `~/code/dvddgn/` by `install.sh` because the
shell aliases and the scripts themselves reference them by that path.

| Script | What it does |
|---|---|
| `wt.sh` | `wt new/rm/ls` — creates a complete AIH worktree slot: worktree, `.env`, copy-on-write `node_modules`, VS Code workspace entry, tmux session with `claude`/`rails`/`sidekiq`/`vite`/`shell` windows, and a Rails server |
| `services.sh` | `srv` — start/stop/restart rails, sidekiq and vite in any tmux session, stopping the same service elsewhere unless `--keep-others` |
| `startup.sh` | `up` — brings up the day's tmux sessions |

The matching aliases live in `zshrc`.
