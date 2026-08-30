#!/bin/bash
# wt.sh — create or tear down a complete AIH worktree slot in one command.
#
# A slot is: the git worktree, its .env, a copy-on-write node_modules, an entry
# in the shared VS Code workspace, a tmux session, the seven windows a slot always
# ends up needing, its own VS Code window and an iTerm2 tab attached to the session
# — so none of it is assembled a step at a time later. The window and the tab are
# not optional extras: a slot exists to be worked in by hand (nothing automated
# creates one), so it is not finished until there is somewhere to work in it.
# --no-ui skips both, for a batch of slots or a session with no GUI.
#
# Usage:
#   wt new    <slug> [branch] [--claudes N] [--no-rails] [--no-ui]  # N defaults to 3 ($WT_CLAUDES)
#   wt agent  <slug> [window-name]
#   wt restore [slug] [--rails]        # after a reboot: rebuild the tmux sessions
#   wt done   <slug> [--force]
#   wt rename <old-slug> <new-slug> [new-branch]
#   wt rm     <slug> [--force]
#   wt ls
#
# Examples:
#   wt new dropzone                                  # branch feature/dropzone off origin/main
#   wt new dropzone feature/property-profile-upload-ux
#   wt new review-79 feature/profile-79-review --claudes 2
#   wt done dropzone                                 # the whole close-out, once the PR is merged
#   wt rm  dropzone                                  # teardown alone, merged or not
#
# `done` is the one to reach for after a merge: it refuses unless the branch is
# actually in origin/main, then deletes the local and remote branch and tears the
# slot down. `rm` skips the merge check, for a slot being abandoned.
#
# NEITHER can be run from inside the slot. git will remove a worktree from within
# itself quite happily, leaving every shell in that session in a directory that no
# longer exists - `fatal: Unable to read current working directory` on every command
# afterwards, blaming git rather than naming the cause. Both refuse instead.
#
# Windows created in session wt-<slug>, in this order:
#   claude   the agent (ccp <project-slug> to launch one with project context)
#   rails    driven by services.sh / srv; started automatically unless --no-rails
#   sidekiq  left idle deliberately — Sidekiq is a singleton across every clone
#            and worktree, so only one may run at a time
#   vite     left idle too — it binds 3036 and only one checkout can hold it.
#            Assets build on demand via autoBuild, so this is only for frontend work
#   shell    a free terminal at the worktree root
#
# Ports are allocated by services.sh (3012 upward, recorded in <worktree>.port
# beside the worktree). This script never allocates one itself — it starts rails
# through services.sh and reads the file back.

set -uo pipefail

BASE="$HOME/code/dvddgn"
# The clone the worktrees hang off. Every slot's .git file points into
# $PARENT/.git/worktrees/, so this clone is load-bearing: it must keep existing,
# and its own checkout should stay on main and idle. Override for a different
# clone or repo - existing slots stay bound to whichever parent created them.
PARENT="${AIH_PARENT:-$BASE/advice-innovation-hub-m1}"
SERVICES="$BASE/services.sh"
CS="$BASE/cs.sh"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Removing the worktree you are standing in succeeds, and leaves the shell in a
# directory that no longer exists. Refuse, and say where to run it from.
assert_outside() {
  local wt=$1 here real
  here=$(pwd -P 2>/dev/null) || return 0   # already in a phantom dir; nothing to protect
  real=$(cd "$wt" 2>/dev/null && pwd -P) || real="$wt"
  if [[ "$here" == "$real" || "$here" == "$real"/* ]]; then
    echo "Error: you are inside $real" >&2
    echo "       A slot cannot tear itself down - the directory would vanish under this shell." >&2
    echo "       Run it from somewhere else, e.g.:  cd $PARENT && wt ${ACTION:-rm} $(basename "$wt" | sed 's/^aih-wt-//')" >&2
    exit 1
  fi
}

# ---- workspace file -----------------------------------------------------------
# A small .code-workspace INSIDE the worktree, purely so `code <path>.code-workspace`
# opens it as its own window with a real title - "wt · <slug>" in the macOS Window
# menu and the title bar - instead of the bare folder name a plain `code <path>`
# gives you. *.code-workspace is already in .git/info/exclude, which every worktree
# shares with the parent's .git, so this never shows up in `git status` and needs no
# cleanup on teardown - it goes with the directory.
write_standalone_ws() {
  local slug=$1 branch=$2 wt=$3
  python3 - "$wt/$slug.code-workspace" "$slug" "$branch" <<'PY'
import json, sys
path, slug, branch = sys.argv[1:4]
short = branch.removeprefix("feature/")
ws = {
    "folders": [{"name": f"{slug} · {short}", "path": "."}],
    "settings": {
        "window.title": f"wt · {slug} — ${{activeEditorShort}}",
        "workbench.colorCustomizations": {
            "titleBar.activeBackground": "#0f4c5c",
            "titleBar.activeForeground": "#ffffff",
        },
        "window.zoomLevel": 1,
        "terminal.integrated.hideOnStartup": "never",
        "workbench.panel.defaultLocation": "left",
        "terminal.integrated.profiles.osx": {
            f"tmux-wt-{slug}": {
                "path": "/bin/zsh",
                "args": [
                    "-c",
                    f"tmux attach -t wt-{slug} 2>/dev/null || echo 'No tmux session. Run: wt restore {slug}' && exec zsh",
                ],
            }
        },
        "terminal.integrated.defaultProfile.osx": f"tmux-wt-{slug}",
    },
}
open(path, "w").write(json.dumps(ws, indent=2, ensure_ascii=False) + "\n")
print(f"  standalone workspace written ({path.split('/')[-1]})")
PY
}

# ---- windows ------------------------------------------------------------------
# The session shape, in one place, so `new` and `restore` cannot drift apart. The
# names are load-bearing: services.sh drives windows called rails/sidekiq/vite,
# and bin/sidekiq refuses to run unless the session has one named sidekiq.
# How many agent windows a session is scaffolded with. Clone sessions get three
# (startup.sh's cc1/cc2/cc3); slots got one, which meant every extra agent had to
# be added by hand at the moment it was wanted. Override with WT_CLAUDES.
CLAUDES_DEFAULT=${WT_CLAUDES:-3}

make_windows() {
  local session=$1 wt=$2 claudes=${3:-$CLAUDES_DEFAULT} i
  tmux new-session -d -s "$session" -c "$wt" -n claude
  for ((i = 2; i <= claudes; i++)); do
    tmux new-window -d -t "$session" -n "claude$i" -c "$wt"
  done
  tmux new-window -d -t "$session" -n rails   -c "$wt"
  tmux new-window -d -t "$session" -n sidekiq -c "$wt"
  tmux new-window -d -t "$session" -n vite    -c "$wt"
  tmux new-window -d -t "$session" -n shell   -c "$wt"
  echo "  tmux session $session: $(tmux list-windows -t "$session" -F '#{window_name}' | paste -sd' ' -)"
}

# The orchestrator is not a slot: it has no checkout of its own and drives the
# others from the parent clone, so it gets agent windows and a shell and none of
# the service windows. Listed here so `wt restore` brings it back after a reboot
# along with everything else - nothing else creates it.
EXTRA_SESSIONS=(orchestrator)
extra_session_dir() {
  case "$1" in
    orchestrator) echo "$PARENT" ;;
    *) return 1 ;;
  esac
}

make_agent_windows() {
  local session=$1 dir=$2 n=${3:-$CLAUDES_DEFAULT} i
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "  $session: session already up"
    return 0
  fi
  tmux new-session -d -s "$session" -c "$dir" -n claude
  for ((i = 2; i <= n; i++)); do
    tmux new-window -d -t "$session" -n "claude$i" -c "$dir"
  done
  tmux new-window -d -t "$session" -n shell -c "$dir"
  echo "  $session: $(tmux list-windows -t "$session" -F '#{window_name}' | paste -sd' ' -)"
}

# ---- vite ---------------------------------------------------------------------
# config/vite.json pins every checkout to 3036, and only one process can hold a
# port - so whoever starts Vite first serves JavaScript to every other checkout,
# silently, because Rails proxies /vite-dev/* to whatever port it is told. A slot
# therefore needs its own, derived from its Rails port so it cannot collide.
#
# Rails reads this from .env on boot. `bin/vite dev` does NOT - dotenv only loads
# inside Rails - so services.sh passes it on the command line as well.
set_vite_port() {
  local wt=$1 railsport=$2 viteport
  [[ "$railsport" =~ ^[0-9]+$ ]] || return 0
  # Only if this checkout's vite.config.ts honours the variable (PR #769). Against
  # a config that still hardcodes 3036, naming a port here sends Rails to someone
  # else's Vite while this one fails to bind.
  grep -q 'VITE_RUBY_PORT' "$wt/vite.config.ts" 2>/dev/null || return 0
  viteport=$((railsport + 30))          # 3012+ -> 3042+, clear of 3036/3037
  grep -q '^VITE_RUBY_PORT=' "$wt/.env" 2>/dev/null && return 0
  {
    echo ""
    echo "# This checkout's own Vite dev server. Without it every checkout shares"
    echo "# 3036 and the first one to start serves JavaScript to all the others."
    echo "VITE_RUBY_PORT=$viteport"
  } >> "$wt/.env"
  echo "  vite port $viteport (in .env)"
}

# ---- memory -------------------------------------------------------------------
# Claude Code keys its memory directory off the working directory's path, so a new
# slot starts with an empty one and an agent there loses every accumulated lesson.
# The clones already solve this by symlinking to a single canonical store keyed on
# the base clone; slots join the same convention rather than inventing another.
CANONICAL_MEMORY="$HOME/.claude/projects/-Users-daviddeegan-code-dvddgn-advice-innovation-hub/memory"

link_memory() {
  local wt=$1
  [[ -d "$CANONICAL_MEMORY" ]] || { echo "  (no canonical memory store — skipping)"; return 0; }
  # Dots are encoded as dashes too, same as separators.
  local proj="$HOME/.claude/projects/$(echo "$wt" | sed 's|[/.]|-|g')"
  mkdir -p "$proj"
  if [[ -e "$proj/memory" && ! -L "$proj/memory" ]]; then
    echo "  memory: left alone — $proj/memory already exists as a real directory"
    return 0
  fi
  [[ -L "$proj/memory" ]] && rm "$proj/memory"
  ln -s "$CANONICAL_MEMORY" "$proj/memory" \
    && echo "  memory linked ($(ls "$CANONICAL_MEMORY"/*.md 2>/dev/null | wc -l | tr -d ' ') entries)"
}

# ---- new ----------------------------------------------------------------------
# The terminal-profile list - the entries in VS Code's terminal dropdown that drop
# you straight into a slot's tmux session - is GENERATED from the live tmux
# sessions by cs.sh, never written entry by entry, so a slot appearing or
# disappearing leaves the dropdown out of date until something runs `cs snapshot`.
# Do it here rather than leaving it to be noticed later.
#
# A slot no longer earns a FOLDER entry anywhere - it gets its own standalone
# window (write_standalone_ws + code, below) instead of living inside the shared
# aih-worktrees.code-workspace alongside every other slot. That file grew to
# 15+ full worktree roots, and VS Code's git-status polling and file watching
# cost scales with the total size of every root open in one window - a real,
# measured slowdown on git diffs and PR review, not a hypothetical one. Fixed
# 2026-08-30 by giving every active repo (worktrees, m1, claw, workspace-app,
# hre, ...) its own dedicated window and leaving the shared file for genuinely
# lightweight reference-only folders (dotfiles, agent-skills, Claude config,
# Drive folders) that carry none of that cost.
#
# Quiet on purpose. This is a side effect of the command the caller actually asked
# for, and cs.sh prints half a dozen lines about Claude sessions and listening
# servers that would bury the output of that command.
refresh_profiles() {
  [[ -x "$CS" ]] || return 0
  "$CS" snapshot >/dev/null 2>&1 && echo "  terminal profiles refreshed"
}

cmd_new() {
  local slug="" branch="" claudes=$CLAUDES_DEFAULT start_rails=true open_ui=true
  while (($#)); do
    case "$1" in
      --claudes) claudes="${2:?--claudes needs a number}"; shift 2 ;;
      --no-rails) start_rails=false; shift ;;
      --no-ui) open_ui=false; shift ;;
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$slug" ]]; then slug=$1; elif [[ -z "$branch" ]]; then branch=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  [[ -n "$slug" ]] || usage 1

  # tmux reads dots and colons as window and pane separators, so the slug cannot
  # contain them. DD types this name, so keep it short.
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lowercase letters, digits and hyphens: '$slug'"
  branch="${branch:-feature/$slug}"

  local wt="$BASE/aih-wt-$slug" session="wt-$slug"
  [[ -e "$wt" ]] && die "$wt already exists"
  tmux has-session -t "$session" 2>/dev/null && die "tmux session $session already exists"
  [[ -d "$PARENT" ]] || die "parent clone not found at $PARENT"

  echo "Creating slot '$slug' on branch $branch"
  git -C "$PARENT" fetch origin main --quiet

  # An existing branch is checked out; otherwise one is cut from origin/main.
  # A branch can only be checked out in one worktree, which is what stops two
  # agents ending up on the same branch in two trees.
  if git -C "$PARENT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "  local branch $branch"
    git -C "$PARENT" worktree add "$wt" "$branch" --quiet || die "worktree add failed"
  elif git -C "$PARENT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "  tracking origin/$branch"
    git -C "$PARENT" fetch origin "$branch" --quiet
    git -C "$PARENT" worktree add "$wt" --track -b "$branch" "origin/$branch" --quiet || die "worktree add failed"
  else
    echo "  new branch off origin/main"
    git -C "$PARENT" worktree add -b "$branch" "$wt" origin/main --quiet || die "worktree add failed"
  fi

  # The only untracked file the app needs.
  cp "$PARENT/.env" "$wt/.env" && echo "  .env copied"

  # Copy, never symlink: Vite writes its cache into node_modules/.vite and two
  # worktrees sharing that directory collide. -Rc is APFS copy-on-write, so
  # 300MB of files costs a few MB of real disk.
  if [[ -d "$PARENT/node_modules" ]]; then
    cp -Rc "$PARENT/node_modules" "$wt/node_modules" && echo "  node_modules cloned (copy-on-write)"
  fi

  write_standalone_ws "$slug" "$branch" "$wt"
  link_memory "$wt"

  make_windows "$session" "$wt" "$claudes"
  refresh_profiles

  local urlline
  if $start_rails; then
    "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    sleep 1
    local port
    port=$(cat "$wt.port" 2>/dev/null || echo "?")
    echo "  rails starting on port $port"
    urlline="  url       http://localhost:$port"
    set_vite_port "$wt" "$port"
  else
    urlline="  url       no server — start one with: srv $session rails --keep-others"
  fi

  # A slot is interactive by definition - nothing automated creates one (the
  # ai-builder loop works on a branch inside the AIH clone, and this script has no
  # programmatic callers), so there is no "is this for a person?" to decide and no
  # flag to make anyone decide it. Open the window and the tab every time.
  #
  # The asymmetry settles it: opening these when they were not wanted costs
  # closing a window and a tab, while not opening them costs DD a slot he cannot
  # get into and has to know was supposed to be there in order to notice. --no-ui
  # exists for the batch case and for a session with no GUI; it is an escape
  # hatch, not a routine choice.
  #
  # cs.sh degrades rather than failing when iTerm2 is unreachable, and `code` is
  # guarded the same way - a slot must never fail to build because a window
  # manager did not cooperate.
  local uiline
  if $open_ui; then
    echo "  opening the standalone VS Code window and an iTerm2 tab"
    if command -v code >/dev/null 2>&1; then
      code "$wt/$slug.code-workspace" >/dev/null 2>&1 \
        || echo "  (VS Code would not open it - by hand: code $wt/$slug.code-workspace)"
    else
      echo "  (no 'code' on PATH - by hand: code $wt/$slug.code-workspace)"
    fi
    # cs.sh prints its own by-hand instruction on every unhappy path; the exit
    # code is only read so this summary does not claim a tab that is not there.
    local tab_rc=0
    [[ -x "$CS" ]] && { "$CS" tab "$session"; tab_rc=$?; }
    if [[ $tab_rc -eq 0 ]]; then
      uiline="  window    VS Code window and iTerm2 tab opened — drag the tab left if you want it sorted"
    else
      uiline="  window    VS Code window opened; the iTerm2 tab needs a hand — see the note above"
    fi
  else
    uiline="  window    code $wt/$slug.code-workspace   then: cs tab $session"
  fi

  # The attach command goes last and unlabelled, on its own line, because it is
  # the one line DD copies. Everything above it is reference.
  cat <<EOF

Slot ready.
  path      $wt
  branch    $branch
$urlline
  agent     tmux send-keys -t $session:claude 'ccp <project-slug>' C-m
  sidekiq   window is idle on purpose — only one Sidekiq may run across all clones
  vite      window is idle too — it binds 3036 exclusively; assets autoBuild without it
$uiline

Attach:
  tmux attach -t $session
EOF
}

# ---- rm -----------------------------------------------------------------------
cmd_rm() {
  local slug="" force=false
  while (($#)); do
    case "$1" in
      --force) force=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) slug=$1; shift ;;
    esac
  done
  [[ -n "$slug" ]] || usage 1

  local wt="$BASE/aih-wt-$slug" session="wt-$slug"
  ACTION=rm assert_outside "$wt"
  echo "Removing slot '$slug'"

  if tmux has-session -t "$session" 2>/dev/null; then
    "$SERVICES" "$session" stop all >/dev/null 2>&1
    sleep 1
    tmux kill-session -t "$session" && echo "  tmux session killed"
  fi

  refresh_profiles
  rm -f "$wt.port" && echo "  port file removed"
  # A brief/context file lives BESIDE the worktree so `git worktree remove`
  # cannot take it with the directory - which is also why nothing else ever
  # did. They are small and outside every `git status`, so they accumulate
  # silently: three orphans had built up by 2026-08-30.
  for side in "$wt.brief.md" "$wt.context.md"; do
    [[ -f "$side" ]] && rm -f "$side" && echo "  $(basename "$side") removed"
  done

  if [[ -d "$wt" ]]; then
    local branch
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    if $force; then
      # `--force` still refuses when it cannot clear the directory (a server was
      # writing to log/, node_modules is busy), and it leaves the registration
      # behind while reporting failure. Take the files ourselves: --force has
      # already accepted the loss of anything uncommitted, and `done` checked for
      # unpushed commits before it got here.
      if git -C "$PARENT" worktree remove --force "$wt"; then
        echo "  worktree removed (forced)"
      else
        rm -rf "$wt"
        git -C "$PARENT" worktree prune
        if [[ -d "$wt" ]]; then
          echo "  worktree NOT removed - $wt is still on disk"
        else
          echo "  worktree removed (git left files behind; cleared them)"
        fi
      fi
    else
      git -C "$PARENT" worktree remove "$wt" && echo "  worktree removed" \
        || echo "  worktree NOT removed — uncommitted work? re-run with --force once you have checked"
    fi
    # `done` deletes the branch itself a moment later; only `rm` needs the hint.
    [[ -n "$branch" && "${ACTION:-rm}" != "done" ]] && \
      echo "  branch $branch still exists: git -C $PARENT branch -d $branch"
  fi
}

# ---- done ---------------------------------------------------------------------
# The close-out: verify the branch really is in origin/main, delete it locally and
# on the remote, then tear the slot down. The merge check is the point - `rm` will
# happily bin a slot whose work never landed.
cmd_done() {
  local slug="" force=false
  while (($#)); do
    case "$1" in
      --force) force=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) slug=$1; shift ;;
    esac
  done
  [[ -n "$slug" ]] || usage 1

  local wt="$BASE/aih-wt-$slug" session="wt-$slug"
  ACTION=done assert_outside "$wt"
  [[ -d "$wt" ]] || die "no worktree at $wt"

  local branch
  branch=$(git -C "$wt" branch --show-current) || die "cannot read the branch in $wt"
  echo "Closing out '$slug' ($branch)"

  # Uncommitted or unpushed work is lost with the worktree, so say so before it is.
  if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
    $force || die "uncommitted changes in $wt - commit, stash or re-run with --force"
    echo "  WARNING: discarding uncommitted changes (--force)"
  fi

  git -C "$PARENT" fetch origin main --quiet
  local unpushed
  unpushed=$(git -C "$wt" log --oneline "origin/main..HEAD" 2>/dev/null | wc -l | tr -d ' ')

  # A merge commit or fast-forward leaves the branch an ancestor of main. A squash
  # or rebase merge does not, so fall back to asking GitHub whether a PR landed.
  local merged_via=""
  if git -C "$PARENT" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
    merged_via="in origin/main"
  elif command -v gh >/dev/null 2>&1; then
    local pr
    pr=$(gh pr list --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
           --head "$branch" --state merged --json number -q '.[0].number' 2>/dev/null)
    [[ -n "$pr" ]] && merged_via="PR #$pr (squashed or rebased, so not an ancestor)"
  fi

  if [[ -z "$merged_via" ]]; then
    if $force; then
      echo "  WARNING: $branch is NOT merged - proceeding anyway (--force)"
      [[ "$unpushed" != "0" ]] && echo "  WARNING: $unpushed commit(s) not in origin/main will be lost"
    else
      echo "Error: $branch is not merged into origin/main." >&2
      [[ "$unpushed" != "0" ]] && echo "       It has $unpushed commit(s) that main does not." >&2
      echo "       Merge it first, or use \`wt rm $slug\` to abandon the slot deliberately." >&2
      exit 1
    fi
  else
    echo "  merged: $merged_via"
  fi

  ACTION=done cmd_rm "$slug" --force

  # Branch deletion comes after the worktree is gone - git refuses to delete a
  # branch that is still checked out somewhere.
  if git -C "$PARENT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$PARENT" branch -D "$branch" >/dev/null && echo "  local branch deleted"
  fi
  if git -C "$PARENT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git -C "$PARENT" push origin --delete "$branch" --quiet && echo "  remote branch deleted"
  else
    echo "  remote branch already gone"
  fi

  echo
  # Never claim a clean close-out without looking. A removal that failed prints an
  # error of its own, and a success line underneath it is worse than no line.
  if [[ -d "$wt" ]]; then
    echo "NOT fully closed out: $wt is still on disk ($(du -sh "$wt" 2>/dev/null | cut -f1 | tr -d " "))." >&2
    echo "Everything else for '$slug' is gone. Check what is holding it, then: rm -rf $wt" >&2
    exit 1
  fi
  echo "Closed out. Nothing left for '$slug'."
}

# ---- agent --------------------------------------------------------------------
# Several agents can share one slot as long as none of them edits files - scoping
# and review sessions read code and write to the workspace, so they conflict over
# nothing. This adds another correctly named and correctly placed agent window.
cmd_agent() {
  local slug="" name=""
  while (($#)); do
    case "$1" in
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$slug" ]]; then slug=$1; elif [[ -z "$name" ]]; then name=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  [[ -n "$slug" ]] || die "usage: wt agent <slug> [window-name]"

  # Accept a slot slug (scoping -> wt-scoping) or a session name outright, so this
  # works for the orchestrator and any other long-lived session, not only slots.
  local session=""
  if tmux has-session -t "wt-$slug" 2>/dev/null; then session="wt-$slug"
  elif tmux has-session -t "$slug" 2>/dev/null; then session="$slug"
  else die "no tmux session 'wt-$slug' or '$slug'"; fi

  # Default to the next free claude/claudeN. A name is better when the windows
  # hold different subjects - three windows called claude2/3/4 tell you nothing.
  if [[ -z "$name" ]]; then
    local n=2
    while tmux list-windows -t "$session" -F "#{window_name}" | grep -qx "claude$n"; do n=$((n + 1)); done
    name="claude$n"
  fi
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "window name must be lowercase letters, digits and hyphens"
  tmux list-windows -t "$session" -F "#{window_name}" | grep -qx "$name" && die "window $name already exists in $session"

  # A slot has a known directory; any other session takes its current pane path.
  local wt="$BASE/aih-wt-$slug"
  [[ -d "$wt" ]] || wt=$(tmux display-message -t "$session" -p '#{pane_current_path}' 2>/dev/null)
  [[ -d "$wt" ]] || die "cannot resolve a working directory for $session"

  # Insert after the last agent window so the agents stay together, ahead of the
  # service windows. tmux -a inserts after the target index and renumbers.
  local after
  after=$(tmux list-windows -t "$session" -F "#{window_index} #{window_name}" \
          | awk '$2 ~ /^claude/ {i=$1} END {print i+0}')
  if [[ "$after" -gt 0 ]]; then
    tmux new-window -d -a -t "${session}:${after}" -n "$name" -c "$wt"
  else
    tmux new-window -d -t "$session" -n "$name" -c "$wt"
  fi

  echo "Added $name to $session"
  tmux list-windows -t "$session" -F "  #{window_index}: #{window_name}"
  cat <<EOF

  agent   tmux send-keys -t ${session}:${name} 'ccp <project-slug>' C-m

Attach:
  tmux attach -t $session
EOF
}

# ---- rename -------------------------------------------------------------------
# Exploration starts before a project exists, so a slot is often named for an idea
# and then turns into something. This moves the directory, branch, tmux session,
# port file and workspace entry together, so none of them is left describing the
# old thing.
cmd_rename() {
  local old="" new="" branch=""
  while (($#)); do
    case "$1" in
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$old" ]]; then old=$1; elif [[ -z "$new" ]]; then new=$1
         elif [[ -z "$branch" ]]; then branch=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  [[ -n "$old" && -n "$new" ]] || die "usage: wt rename <old-slug> <new-slug> [new-branch]"
  [[ "$new" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lowercase letters, digits and hyphens: '$new'"

  local owt="$BASE/aih-wt-$old" nwt="$BASE/aih-wt-$new"
  ACTION=rename assert_outside "$owt"
  [[ -d "$owt" ]] || die "no worktree at $owt"
  [[ -e "$nwt" ]] && die "$nwt already exists"
  tmux has-session -t "wt-$new" 2>/dev/null && die "tmux session wt-$new already exists"

  echo "Renaming slot '$old' -> '$new'"

  # git worktree move keeps the administrative link intact. The directory keeps its
  # inode, so a shell sitting inside it survives - its `pwd` reads stale, but the
  # directory is still there. Unlike removal, which leaves it pointing at nothing.
  git -C "$PARENT" worktree move "$owt" "$nwt" || die "worktree move failed"
  echo "  directory moved"

  if [[ -n "$branch" ]]; then
    local current
    current=$(git -C "$nwt" branch --show-current)
    if [[ "$current" != "$branch" ]]; then
      git -C "$PARENT" branch -m "$current" "$branch" && echo "  branch $current -> $branch"
    fi
  fi
  local finalbranch
  finalbranch=$(git -C "$nwt" branch --show-current)

  tmux has-session -t "wt-$old" 2>/dev/null && {
    tmux rename-session -t "wt-$old" "wt-$new" && echo "  tmux session wt-$old -> wt-$new"
  }

  [[ -f "$owt.port" ]] && mv "$owt.port" "$nwt.port" && echo "  port file moved"
  # Same reason as the port file: named for the slug, so a rename would strand
  # them under the old one and teardown would no longer find them.
  for ext in brief.md context.md; do
    [[ -f "$owt.$ext" ]] && mv "$owt.$ext" "$nwt.$ext" && echo "  $ext file moved"
  done
  rm -f "$nwt/$old.code-workspace"
  write_standalone_ws "$new" "$finalbranch" "$nwt"

  refresh_profiles

  cat <<EOF

Renamed.
  path      $nwt
  branch    $finalbranch

A session already running inside the slot keeps working - the directory kept its
inode, so only its \`pwd\` reads stale. Tell it to \`cd $nwt\` when convenient.

Attach:
  tmux attach -t wt-$new
EOF
}

# ---- restore ------------------------------------------------------------------
# tmux does not survive a reboot - there is no resurrect/continuum here, so the
# server dies with every session in it. The worktrees do survive, and so do the
# Claude transcripts (they live in ~/.claude/projects, not in the worktree). So a
# restart loses the sessions and nothing else, and this rebuilds them.
#
# It does NOT resume the agents. Restarting eight of them unasked is expensive and
# usually wrong; it prints the command for each instead, newest session first.
cmd_restore() {
  local start_rails=false slug_filter=""
  while (($#)); do
    case "$1" in
      --rails) start_rails=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) slug_filter=$1; shift ;;
    esac
  done

  local wt slug session found=0 extras=0 extra dir
  for extra in "${EXTRA_SESSIONS[@]}"; do
    [[ -n "$slug_filter" && "$slug_filter" != "$extra" ]] && continue
    dir=$(extra_session_dir "$extra") || continue
    make_agent_windows "$extra" "$dir"
    extras=$((extras + 1))
  done

  shopt -s nullglob
  for wt in "$BASE"/aih-wt-*/; do
    wt="${wt%/}"
    # A directory matching the glob is not necessarily a real worktree - a
    # `git worktree move` whose old path still had an open file (a running
    # rails/sidekiq/vite server's log or pid file) can leave a `.vite`-cache
    # husk behind with no `.git` file, indistinguishable from a real slot by
    # name alone. Cost a real bug: this loop treated four such leftovers from
    # a batch of `wt rename` calls as live slots and stood up bogus tmux
    # sessions for them (found and cleaned up 2026-08-30). `git worktree list`
    # is the only source of truth for what is actually a worktree.
    [[ -e "$wt/.git" ]] || continue
    slug="${wt##*/aih-wt-}"
    [[ -n "$slug_filter" && "$slug" != "$slug_filter" ]] && continue
    found=$((found + 1))
    session="wt-$slug"

    if tmux has-session -t "$session" 2>/dev/null; then
      echo "  $slug: session already up"
    else
      make_windows "$session" "$wt"
      link_memory "$wt" >/dev/null
      $start_rails && "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    fi

    # Backfill for slots created before standalone workspace files existed.
    if [[ ! -f "$wt/$slug.code-workspace" ]]; then
      local rbranch
      rbranch=$(git -C "$wt" branch --show-current 2>/dev/null)
      write_standalone_ws "$slug" "${rbranch:-$slug}" "$wt" >/dev/null
    fi

    # The transcript directory is the working directory path with / replaced by -.
    local proj latest
    proj="$HOME/.claude/projects/$(echo "$wt" | sed 's|/|-|g')"
    latest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
      echo "     resume: cd $wt && claude --resume $(basename "$latest" .jsonl)"
    fi
  done

  [[ "$found" == "0" && "$extras" == "0" ]] && { echo "No slots found."; return 0; }
  [[ "$found" == "0" ]] && return 0
  cat <<EOF

$found slot(s). Sessions rebuilt; agents are not resumed - run a resume line above,
or start fresh with: ccp <project-slug> --opus "<brief>"
EOF
}

# ---- ls -----------------------------------------------------------------------
cmd_ls() {
  local wt slug branch port session
  shopt -s nullglob
  for wt in "$BASE"/aih-wt-*/; do
    wt="${wt%/}"
    slug="${wt##*/aih-wt-}"
    branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo '?')
    port=$(cat "$wt.port" 2>/dev/null || echo '-')
    session="wt-$slug"
    tmux has-session -t "$session" 2>/dev/null && session="$session (up)" || session="$session (down)"
    printf '%-14s %-42s %-6s %s\n' "$slug" "$branch" "$port" "$session"
  done
}

case "${1:-}" in
  new)    shift; cmd_new "$@" ;;
  agent)  shift; cmd_agent "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  done)   shift; cmd_done "$@" ;;
  rename) shift; cmd_rename "$@" ;;
  rm)     shift; cmd_rm "$@" ;;
  ls)     shift; cmd_ls "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown command '$1' (use new, agent, restore, done, rename, rm or ls)" ;;
esac
