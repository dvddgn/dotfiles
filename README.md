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
| `wt.sh` | `wt new/agent/project/restore/done/rename/rm/ls` — creates a complete AIH worktree slot and can bind its tmux session to a Workspace project |
| `tmux-project.sh` | Uniform three-row session status, inferred or manually-set context, durable Workspace project bindings, and automatic per-window purpose labels |
| `services.sh` | `srv` — start/stop/restart rails, sidekiq and vite in any tmux session, stopping the same service elsewhere unless `--keep-others` |
| `cs.sh` | `cs` — list/resume Claude sessions; `cs snapshot` writes the inspectable session, window, server and exception reports; `cs restore` rebuilds sessions after a reboot and reapplies session context |
| `startup.sh` | `up` — brings up the day's tmux sessions |

The matching aliases live in `zshrc`.

For the complete three-row tmux architecture, automation matrix, persistence
rules, and safe change procedure, see [`TMUX-STATUS.md`](TMUX-STATUS.md).
