# What is running on this machine

Three files, refreshed together by one command:

```bash
cs snapshot
```

They are plain text, column-aligned, and safe to open any time. **Nothing keeps them
current on its own** — they describe the machine at the moment `cs snapshot` last ran.
Check the file's modified time to know how stale that is.

`cs` is `~/code/dvddgn/dotfiles/bin/cs.sh`, symlinked to `~/code/dvddgn/cs.sh` and
aliased in `zshrc`.

---

## `sessions.txt` — the Claude sessions

One row per tmux pane with a Claude process in it. **This is the file that makes a reboot
survivable**, because tmux does not: there is no `tmux-resurrect` here, so a restart takes
the server and every session in it. The transcripts survive regardless — they live in
`~/.claude/projects/`, not in the terminal — but without this file the session names are
gone and there is nothing to rebuild from.

| column | |
|---|---|
| `SESSION` | the tmux session name — what you attach to, and what `cs restore` recreates. A row like `ws:cc2` is a **second agent window** inside session `ws` |
| `DIRECTORY` | where it must be recreated; Claude keys transcripts by working directory |
| `CLAUDE SESSION NAME` | what `claude --resume` takes |

Sorted by directory, so it reads as groups: everything in the claw workspace together,
each clone together, each worktree slot together.

**One row per agent WINDOW, not per session** — a session can hold several, and all of them
need rebuilding after a reboot.

**When column 1 and column 3 differ**, the two halves have drifted. Renaming a tmux
session does not rename the Claude session inside it, and `--resume` only takes the
latter. Fix both:

```bash
tmux rename-session -t <old> <new>     # what you attach to
/rename <new>                          # inside the session: what --resume takes
```

Beware a third label: Claude also shows an auto-generated **conversation summary** below
the working directory, which drifts as the subject moves. That is not the session name and
will not resume. The name is the tab above the input box.

## `windows.txt` — every tmux window

One row per window rather than per session, so a session with several agent windows shows
all of them. This is the "what is actually open" file — `sessions.txt` deliberately skips
anything without a Claude process, including the clone shells and the idle worktree slots.

| column | |
|---|---|
| `SESSION` `WINDOW` `NAME` | which window |
| `COMMAND` | what is running in it — `zsh` means idle |
| `DIRECTORY` | the pane's working directory |

## `servers.txt` — everything listening

| column | |
|---|---|
| `PORT` `PID` `PROCESS` | from `lsof` |
| `OWNER` | **which of your things this is** |
| `URL` | blank for anything not serving HTTP |
| `DIRECTORY` | the process's own working directory |

`OWNER` is the column that earns its place, because `lsof` cannot tell you it. Worktree
slot ports come from the `<worktree>.port` files beside each slot; the clones and the
shared services come from the fixed table `services.sh` owns. So `3017` reads as
`wt-doc-import` rather than as a number.

`DIRECTORY` identifies the rows `OWNER` cannot name — a stray preview server, a forgotten
`python -m http.server`, which checkout is holding the exclusive Vite port on 3036.

## `exceptions.txt` — what needs cleaning up

A report, not a nag: empty (header row only) when there's nothing to flag. Four checks,
each one discovered live rather than designed up front:

| `TYPE` | What it means |
|---|---|
| `UNNAMED` | The scraped Claude session name isn't a real `claude -n`/`/rename` name — Claude's own transient status text, an unsent draft sitting in the input box, or an auto-generated summary. Real names are kebab-case here; can't be auto-resumed by `cs restore`/`wt restore` otherwise. |
| `NAME-MISMATCH` | An `ops-*`/`prj-*` session (one Claude name for its whole life) whose Claude session name has drifted from its tmux session name. |
| `STRAY-SESSION` | A `word-HHMMSS` tmux session — VS Code or a bare `cct` created it and nobody named it. None of this setup's real conventions produce that shape. |
| `STALE-DIR` | An `aih-wt-*` directory with no `.git` — a `git worktree move` leftover (the old path had an open file handle), not a real worktree. |

---

## Naming conventions you will see

| prefix | |
|---|---|
| `ops-` | standing work you return to week after week — these get a VS Code terminal profile |
| `prj-` | a project with an end; still running, still reachable from `Ctrl-a s`, but not in the terminal dropdown |
| `wt-` | a worktree slot — a branch with somewhere to live. Rebuilt by `wt restore`, not by `cs restore` |
| clone shells | `aih`, `m1`–`m5`, `ws`, `hre`, `claw` — recreated by `up` |

## After a reboot

```bash
up            # the clone sessions
cs restore    # the Claude sessions, in their right directories
wt restore    # the worktree slots, with their windows
vs wt         # the VS Code workspace
```

`cs restore` rebuilds each session and **prints** how to resume the agent in it — it does
not resume them, because restarting thirty at once is rarely what you want.

Full write-up: **SOP → Dev Tools → "Restarting Sessions After a Reboot"** in the workspace.

## Finding a session again

```bash
cs                # sessions for the current directory, newest first
cs -g budget      # search the whole transcript, not just its first line
cs r 3            # resume the third
```

A transcript outlives its directory. A session whose worktree was torn down is still
resumable — recreate the path and resume:

```bash
mkdir -p ~/code/dvddgn/aih-wt-<slug>
cd ~/code/dvddgn/aih-wt-<slug> && claude --resume <session-id>
```

## One trap worth knowing

**A tmux pane in copy-mode silently swallows anything sent to it** — no error, no output.
Mouse mode is on, so a stray scroll puts a pane there and leaves it. If an agent seems to
be ignoring you, press `q` or `Esc` in the pane, or:

```bash
tmux display-message -t <session> -p '#{pane_in_mode}'   # 1 = stuck
tmux send-keys -t <session> -X cancel
```
