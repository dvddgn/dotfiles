#!/bin/bash
# wt.sh — create or tear down a complete AIH worktree slot in one command.
#
# A slot is: the git worktree, its .env, a copy-on-write node_modules, an entry
# in the shared VS Code workspace, a tmux session, and the four windows a slot
# always ends up needing — so none of it is assembled a step at a time later.
#
# Usage:
#   wt new <slug> [branch] [--claudes N] [--no-rails]
#   wt rm  <slug> [--force]
#   wt ls
#
# Examples:
#   wt new dropzone                                  # branch feature/dropzone off origin/main
#   wt new dropzone feature/property-profile-upload-ux
#   wt new review-79 feature/profile-79-review --claudes 2
#   wt rm  dropzone
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
PARENT="$BASE/advice-innovation-hub-m1"
WSFILE="$BASE/aih-worktrees.code-workspace"
SERVICES="$BASE/services.sh"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
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

  # Every window a slot ends up needing, created up front rather than on demand.
  tmux new-session -d -s "$session" -c "$wt" -n claude
  local i
  for ((i = 2; i <= claudes; i++)); do
    tmux new-window -d -t "$session" -n "claude$i" -c "$wt"
  done
  tmux new-window -d -t "$session" -n rails   -c "$wt"
  tmux new-window -d -t "$session" -n sidekiq -c "$wt"
  tmux new-window -d -t "$session" -n vite    -c "$wt"
  tmux new-window -d -t "$session" -n shell   -c "$wt"
  echo "  tmux session $session: $(tmux list-windows -t "$session" -F '#{window_name}' | paste -sd' ' -)"

  local port="see 'srv $session rails'"
  if $start_rails; then
    "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    sleep 1
    port=$(cat "$wt.port" 2>/dev/null || echo "?")
    echo "  rails starting on port $port"
  fi

  # The attach command goes last and unlabelled, on its own line, because it is
  # the one line DD copies. Everything above it is reference.
  cat <<EOF

Slot ready.
  path      $wt
  branch    $branch
  url       http://localhost:$port
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
    [[ -n "$branch" ]] && echo "  branch $branch still exists: git -C $PARENT branch -d $branch"
  fi
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
  new) shift; cmd_new "$@" ;;
  rm)  shift; cmd_rm "$@" ;;
  ls)  shift; cmd_ls "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown command '$1' (use new, rm or ls)" ;;
esac
