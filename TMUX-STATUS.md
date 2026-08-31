# tmux session context status

This is the canonical change guide for DD's three-row tmux status. It is written
for both humans and agents. Read it before changing the layout, inference rules,
Workspace project binding, window purposes, persistence, or restore behaviour.

## What appears in tmux

Every session has the same structure:

1. Session name, full window menu, and time
2. Session context: `PROJECT`, `REPO`, `AREA`, or `SYSTEM`
3. Active window name, purpose, and live pane working directory

Context precedence is deterministic:

1. A Workspace project binding from `~/.claude/status/tmux-projects.tsv`
2. A manual non-project override from `~/.claude/status/tmux-contexts.tsv`
3. Inference from the session name and session working directory

Project rows reserve enough room for the complete terminal-safe short URL. The
project name truncates first. Rows without a URL use the full available width.

## Source of truth

| Concern | Canonical file |
|---|---|
| Layout, inference, persistence and commands | `dotfiles/bin/tmux-project.sh` |
| Shell alias and `cct --project` | `dotfiles/zshrc` |
| Standing-session creation | `dotfiles/bin/startup.sh` and `dotfiles/core-sessions.txt` |
| Worktree lifecycle | `dotfiles/bin/wt.sh` |
| Service-created sessions/windows | `dotfiles/bin/services.sh` |
| Reboot restore and status snapshots | `dotfiles/bin/cs.sh` |
| Project-aware Claude launch | `workspace-app/ai-builder/scripts/ccp.sh` |
| Project reference and short-URL resolution | `workspace-app/scripts/resolve-ref.js` |
| tmux creation hooks | `mac-setup/tmux/tmux.conf` |
| Live tmux config | `~/.tmux.conf`, copied from the mac-setup file |

Do not add the status formats directly to `.tmux.conf`. The helper applies them
per session so project and non-project contexts can differ while retaining one
layout. Keep the live config and `mac-setup/tmux/tmux.conf` identical whenever
the hooks change.

## Automatic entry points

All normal session and window creation paths call the helper:

| Path | Behaviour |
|---|---|
| tmux `session-created` hook | Applies inferred or saved context to a manually-created session |
| tmux `after-new-window` hook | Assigns a purpose to a manually-created window |
| `up` / `startup.sh` | Applies context after building a standing session |
| `cct [name] [--project ref]` | Applies inferred/saved context or binds the supplied project |
| `wt new --project` | Resolves before creation, then saves and applies the project |
| `wt agent`, `wt restore` | Reapplies purposes and saved context |
| `wt rename` | Moves saved project and manual-context records |
| `wt done`, `wt rm` | Removes saved records for the deleted session |
| `srv` / `services.sh` | Applies context when creating a worktree session or service window |
| `ccp <project-slug>` | Binds the current tmux session after resolving the Workspace project |
| `cs restore` | Reapplies all contexts after rebuilding sessions |

The helper preserves an explicit `@window_purpose`. It only supplies a default
when a window does not already have one.

## Commands

```bash
# Inspect effective and saved context
tmux-project status m1
tmux-project list

# Bind or deliberately replace a Workspace project
tmux-project bind wt-example project:workspace-project-slug
tmux-project bind --force wt-example project:another-project

# Set or remove a durable non-project override
tmux-project context ops-budget area "Budget operations"
tmux-project context m1 repo "Advice Innovation Hub · manual workspace"
tmux-project clear-context ops-budget

# Return a project-bound session to manual or inferred context
tmux-project clear wt-example

# Override one window purpose
tmux-project purpose m1:cc2 "Parallel investigation"

# Retrofit the entire running server
tmux-project apply --all
```

Use labels `repo`, `area`, or `system` for manual context. Do not create a
manual `project` label: use `bind` so the name, canonical reference, and short
URL are verified by Workspace.

## Persistence and recovery

The two TSV files under `~/.claude/status` are machine state, not source code:

- `tmux-projects.tsv` stores verified Workspace project bindings.
- `tmux-contexts.tsv` stores optional manual non-project overrides.

Inferred context needs no saved record. Both files survive tmux restarts and Mac
reboots. `up`, `wt restore`, `cs restore`, the hooks, and the other entry points
reapply them.

On a new Mac, clone the repositories and install the config first. Then copy the
two TSV files from the old machine if their bindings should follow, or recreate
the records with `tmux-project bind` or `tmux-project context`. They are intentionally not
committed because they describe DD's live personal sessions.

`cs snapshot` writes two complementary reports:

- `~/.claude/status/contexts.txt`: one row per live session, including source.
- `~/.claude/status/windows.txt`: one row per live window, including purpose.

## Safe change procedure

1. Change `dotfiles/bin/tmux-project.sh` for layout or inference behaviour.
2. Change both `~/.tmux.conf` and `mac-setup/tmux/tmux.conf` for hook behaviour.
3. Update this document, `dotfiles/status-README.md`, and the shared tmux skill
   when commands, persistence, precedence, or automatic entry points change.
4. Update the AIH worktree skill when `wt` behaviour changes.
5. Run syntax checks:

   ```bash
   bash -n ~/code/dvddgn/dotfiles/bin/tmux-project.sh
   zsh -n ~/code/dvddgn/dotfiles/bin/{wt,startup,services,cs}.sh
   ```

6. Test a disposable session, including its first window and a later window:

   ```bash
   tmux new-session -d -s __tmux_status_test -n shell -c "$PWD"
   tmux new-window -d -t __tmux_status_test -n rails -c "$PWD"
   tmux-project status __tmux_status_test
   tmux show-window-options -v -t __tmux_status_test:rails @window_purpose
   tmux kill-session -t __tmux_status_test
   ```

7. Test project precedence and clearing with a disposable session before
   changing live bindings.
8. Run `tmux-project apply --all`, then verify every session has three rows and
   every window has a purpose.
9. Run `cs snapshot` and inspect `contexts.txt` and `windows.txt`.
10. Run `git diff --check` in every changed repository before committing.

## Important boundaries

- A short Workspace URL is 52 characters. Very narrow panes cannot physically
  display it in full; the project name still gives up space first.
- Project resolution depends on the Workspace app checkout and its local
  Supabase credentials. Inferred and manual context do not.
- Saved project names and URLs are snapshots from bind time. Re-run `bind` with
  the same reference to refresh them after a Workspace project rename.
- `startup.sh` deliberately kills and recreates the named standing sessions.
  Run it only after a reboot or when intentionally resetting those sessions.
- Saved state is keyed by tmux session name. Use `wt rename` or
  `tmux-project rename` when renaming a session that has durable context.
- Keep unrelated user changes in each repository intact and do not commit the
  machine-state TSV files.
