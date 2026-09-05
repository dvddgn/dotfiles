This repository is used by [Le Wagon](https://www.lewagon.com) students.

## Toolset

- [oh-my-zsh](http://ohmyz.sh/)
- [Visual Studio Code](https://code.visualstudio.com/)
- [git](https://git-scm.com/)

## bin/

Dev-workflow scripts, symlinked onto the machine by `install.sh`. **Where each one
lands depends on whether it has a `.sh` extension**, and the two destinations are not
interchangeable:

- `bin/*.sh` → `~/code/dvddgn/`, because the shell aliases and the scripts themselves
  reference them by that path.
- everything else → `~/bin`, because they are typed as bare commands. `zshrc` puts
  `~/bin` on `PATH`.

| Script | Linked into | What it does |
|---|---|---|
| `wt.sh` | `~/code/dvddgn` | `wt new/agent/project/restore/done/rename/rm/ls` — creates a complete AIH worktree slot and can bind its tmux session to a Workspace project |
| `tmux-project.sh` | `~/code/dvddgn` | Uniform three-row session status, inferred or manually-set context, durable Workspace project bindings, and automatic per-window purpose labels |
| `services.sh` | `~/code/dvddgn` | `srv` — start/stop/restart rails, sidekiq and vite in any tmux session, stopping the same service elsewhere unless `--keep-others` |
| `cs.sh` | `~/code/dvddgn` | `cs` — list/resume Claude sessions; `cs snapshot` writes the inspectable session, window, server and exception reports; `cs restore` rebuilds sessions after a reboot and reapplies session context |
| `startup.sh` | `~/code/dvddgn` | `up` — brings up the day's tmux sessions |
| `recap` | `~/bin` | Sets the bullet-point recap shown under the Claude Code statusline's context bar, keyed to the current Claude session — see below |
| `mdopen` | `~/bin` | Renders a markdown file to HTML and opens it in the browser; routes anything that is not `.md` to `codeopen` |
| `codeopen` | `~/bin` | Renders a source file syntax-highlighted with line numbers and opens it in the browser |
| `diffopen` | `~/bin` | Renders a `git diff` (or two plain files) side by side and opens it in the browser |

The matching aliases live in `zshrc`.

The split is worth knowing about because it is what let a script go missing.
`install.sh` originally globbed `bin/*.sh` only, so the extension-less scripts were
hand-linked into `~/bin` machine by machine — and `recap`, which had never been copied
into this repo at all, simply never arrived on the second Mac. Both groups are
installed now. A new script belongs in `bin/` either way; only its extension decides
where it is linked.

For the complete three-row tmux architecture, automation matrix, persistence
rules, and safe change procedure, see [`TMUX-STATUS.md`](TMUX-STATUS.md).

## Claude Code statusline

Claude Code renders the statusline under its input box by running
`claude/statusline-command.sh` from this repo, symlinked to
`~/.claude/statusline-command.sh` by `install.sh`. It reads Claude Code's JSON on
stdin and prints, one per line:

- the working directory, shortened to `~` and truncated to its last two segments
- the session name, when one is set
- the git branch · the model name
- a 20-character context bar — green under 50%, yellow to 79%, red at 80% and above
- up to five recap bullets

The bullets are the only part anything writes to, and `bin/recap` is what writes them:

```bash
recap "first bullet" "second bullet"   # replace the recap
recap add "another bullet"             # append one
recap                                  # show the current recap
recap clear                            # remove it
```

A recap belongs to **one Claude session**, keyed by `$CLAUDE_CODE_SESSION_ID` — the
same id the renderer receives as `.session_id` — so every session starts empty and
keeps its own. Run `recap` outside a Claude session and it falls back to a
directory-scoped recap, which the renderer uses only when the session has none of its
own. Files live in `~/.claude/recap/`; anything untouched for 30 days is pruned. Five
bullets maximum, each truncated at 72 characters when rendered.

**None of it appears without the `statusLine` key in `~/.claude/settings.json`:**

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline-command.sh"
}
```

That file is deliberately **not** symlinked from here — it also carries machine-specific
plugins and permissions, so only the one key needs to be reproducible. `install.sh`
adds it in place with `jq`, only when it is absent, and backs the file up first; if
`jq` is missing or the file is not valid JSON it prints the key and changes nothing.

Verify the whole chain — writer, file location, session key, renderer — with a real
render rather than by looking at the symlinks:

```bash
recap "test bullet"
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"x"},"context_window":{"used_percentage":1},"session_id":"%s"}' \
  "$PWD" "$CLAUDE_CODE_SESSION_ID" | bash ~/.claude/statusline-command.sh
recap clear
```

The output should end with `▸ test bullet`. Section 16 of the
[`mac-setup`](https://github.com/dvddgn/mac-setup) guide covers installing this on a
new machine from nothing.

## How `install.sh` treats what is already there

Every step in `install.sh` goes through the same two helpers, so their rules are worth
knowing before adding a step.

`backup()` moves a **real file** out of the way to `<target>.backup`. It deliberately
does nothing to a symlink, there is nothing to preserve in a pointer.

`symlink()` decides what to do about anything already sitting at the link path:

| What is there | What happens |
|---|---|
| nothing | the link is created, and it says so |
| a symlink already pointing at the right file | left alone, silently |
| a **broken** symlink | replaced, and it says what it used to point at |
| a symlink to a different real file | left alone, with a message saying where it points |
| a real file | untouched by `symlink()`, `backup()` is what moves it first |

The broken-symlink row is the one that was wrong until September 2026. `[ ! -e "$link" ]`
follows the link, so it is *true* for a broken one, and the old helper announced the
symlink and then let `ln -s` fail with `File exists`, exiting 0 with a link still pointing
nowhere. A fresh machine hits this every time: the `dvddgn/claude-config` clone brings its
own symlink to `claude/statusline-command.sh` in this repo, which is broken until this
repo is cloned.

Run the helper tests after changing either one:

```bash
./test/install-helpers-test.sh
```

They extract `backup` and `symlink` out of `install.sh` rather than copying them, so they
cannot drift, and they run against a throwaway `$HOME`.
