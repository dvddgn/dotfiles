#!/bin/bash
# wt.sh — create or tear down a complete AIH worktree slot in one command.
#
# A slot is: the git worktree, its .env, a copy-on-write node_modules, an entry
# in the shared VS Code workspace, a tmux session, and the four windows a slot
# always ends up needing — so none of it is assembled a step at a time later.
#
# Usage:
#   wt new    <slug> [branch] [--claudes N] [--no-rails]
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
WSFILE="$BASE/aih-worktrees.code-workspace"
SERVICES="$BASE/services.sh"

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
# The entry goes at the TOP of folders so the newest slot is the first thing in
# the Source Control panel. Editing this file while the window is open adds the
# folder with no reload.
ws_add() {
  local slug=$1 branch=$2
  [[ -f "$WSFILE" ]] || { echo "  (no $WSFILE — skipping registration)"; return 0; }
  python3 - "$WSFILE" "$slug" "$branch" <<'PY'
import json, sys
path, slug, branch = sys.argv[1:4]
ws = json.load(open(path))
entry = {"name": f"{slug} · {branch.removeprefix('feature/')}", "path": f"aih-wt-{slug}"}
ws["folders"] = [f for f in ws["folders"] if f.get("path") != entry["path"]]
ws["folders"].insert(0, entry)
open(path, "w").write(json.dumps(ws, indent=2, ensure_ascii=False) + "\n")
print(f"  registered as \"{entry['name']}\"")
PY
}

ws_remove() {
  local slug=$1
  [[ -f "$WSFILE" ]] || return 0
  python3 - "$WSFILE" "$slug" <<'PY'
import json, sys
path, slug = sys.argv[1:3]
ws = json.load(open(path))
before = len(ws["folders"])
ws["folders"] = [f for f in ws["folders"] if f.get("path") != f"aih-wt-{slug}"]
open(path, "w").write(json.dumps(ws, indent=2, ensure_ascii=False) + "\n")
print("  workspace entry removed" if len(ws["folders"]) < before else "  (no workspace entry)")
PY
}

# ---- windows ------------------------------------------------------------------
# The session shape, in one place, so `new` and `restore` cannot drift apart. The
# names are load-bearing: services.sh drives windows called rails/sidekiq/vite,
# and bin/sidekiq refuses to run unless the session has one named sidekiq.
make_windows() {
  local session=$1 wt=$2 claudes=${3:-1} i
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
cmd_new() {
  local slug="" branch="" claudes=1 start_rails=true
  while (($#)); do
    case "$1" in
      --claudes) claudes="${2:?--claudes needs a number}"; shift 2 ;;
      --no-rails) start_rails=false; shift ;;
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

  ws_add "$slug" "$branch"
  link_memory "$wt"

  make_windows "$session" "$wt" "$claudes"

  local urlline
  if $start_rails; then
    "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    sleep 1
    local port
    port=$(cat "$wt.port" 2>/dev/null || echo "?")
    echo "  rails starting on port $port"
    urlline="  url       http://localhost:$port"
  else
    urlline="  url       no server — start one with: srv $session rails --keep-others"
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

  ws_remove "$slug"
  rm -f "$wt.port" && echo "  port file removed"

  if [[ -d "$wt" ]]; then
    local branch
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    if $force; then
      git -C "$PARENT" worktree remove --force "$wt" && echo "  worktree removed (forced)"
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

  local session="wt-$slug"
  tmux has-session -t "$session" 2>/dev/null || die "no tmux session $session"

  # Default to the next free claude/claudeN. A name is better when the windows
  # hold different subjects - three windows called claude2/3/4 tell you nothing.
  if [[ -z "$name" ]]; then
    local n=2
    while tmux list-windows -t "$session" -F "#{window_name}" | grep -qx "claude$n"; do n=$((n + 1)); done
    name="claude$n"
  fi
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "window name must be lowercase letters, digits and hyphens"
  tmux list-windows -t "$session" -F "#{window_name}" | grep -qx "$name" && die "window $name already exists in $session"

  local wt="$BASE/aih-wt-$slug"
  [[ -d "$wt" ]] || die "no worktree at $wt"

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

  ws_remove "$old" >/dev/null
  ws_add "$new" "$finalbranch"

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

  local wt slug session found=0
  shopt -s nullglob
  for wt in "$BASE"/aih-wt-*/; do
    wt="${wt%/}"
    slug="${wt##*/aih-wt-}"
    [[ -n "$slug_filter" && "$slug" != "$slug_filter" ]] && continue
    found=$((found + 1))
    session="wt-$slug"

    if tmux has-session -t "$session" 2>/dev/null; then
      echo "  $slug: session already up"
    else
      make_windows "$session" "$wt" 1
      link_memory "$wt" >/dev/null
      $start_rails && "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    fi

    # The transcript directory is the working directory path with / replaced by -.
    local proj latest
    proj="$HOME/.claude/projects/$(echo "$wt" | sed 's|/|-|g')"
    latest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
      echo "     resume: cd $wt && claude --resume $(basename "$latest" .jsonl)"
    fi
  done

  [[ "$found" == "0" ]] && { echo "No slots found."; return 0; }
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
