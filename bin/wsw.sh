#!/bin/bash
# wsw.sh — create or tear down a workspace-app worktree slot in one command.
#
# The sibling of wt.sh, which does the same job for AIH. They are deliberately
# separate scripts rather than one parameterised one: wt.sh is 1224 lines of
# Rails/Sidekiq/Vite/services.sh assumptions that a Next.js app has no use for,
# and ten-plus live AIH slots depend on it behaving exactly as it does.
#
# Usage:
#   wsw new     <slug> [branch] [--project <ref>] [--no-dev] [--no-ui]
#   wsw rm      <slug> [--force]
#   wsw ls
#   wsw restore [slug]
#
# Examples:
#   wsw new board-arrow                                  # branch feature/board-arrow off origin/main
#   wsw new searchpath fix/pin-search-path-git-branch-trigger
#   wsw ls                                               # every slot on disk, adopted or hand-rolled
#   wsw rm  board-arrow                                  # tear the slot down; the branch stays
#
# WHY A SLOT EXISTS HERE AT ALL
# The workspace-app AI Builder loop builds in the SHARED clone (loop.rb takes
# repo_dir from the domain's repo_root), which is the same directory every
# remote-workspace tmux window sits in. It force-switches the branch there, and
# when that checkout fails on a dirty tree it commits on whatever branch is
# current instead of stopping. So the shared clone is not a safe place to edit
# workspace-app files by hand. A slot is.
#
# WHAT A SLOT IS — much smaller than an AIH one
#   directory   ~/code/dvddgn/workspace-app-wt-<slug>   (agents already use this name)
#   session     wsw-<slug>   NOT wt-<slug>: that namespace is AIH's, and cs.sh
#               classifies wt-* as an AIH slot.
#   windows     shell, dev, cc1, cc2, cx1   (core-sessions.txt's convention:
#               shell first, agent windows last, the session's own work between)
#   port        3100 upward, first free, recorded in <worktree>.port. The AIH
#               range (3000-3099, allocated by services.sh) is left alone —
#               services.sh does not know workspace-app exists.
#   env         .env.local AND .env.agents, COPIED from the parent (never
#               symlinked: a symlink into the parent means an edit in a slot
#               silently rewrites everyone's credentials).
#   deps        node_modules cloned copy-on-write from the parent. A real
#               `npm install` is 1.0GB of disk per slot; the APFS clone is
#               a few MB.
#
# There is no Rails, no Sidekiq, no Vite, no Redis and no services.sh here, so
# there are no windows for them and nothing allocates a database.

set -uo pipefail

BASE="$HOME/code/dvddgn"
# The clone the worktrees hang off. Every slot's .git file points into
# $PARENT/.git/worktrees/, so this clone is load-bearing: it must keep existing.
# Its own checkout is the loop's workspace and churns constantly — that does not
# affect the slots, which only need its object store and its refs.
PARENT="${WSW_PARENT:-$BASE/workspace-app}"
CS="$BASE/cs.sh"
TMUX_PROJECT="$BASE/dotfiles/bin/tmux-project.sh"

PORT_BASE=3100
PORT_MAX=3199

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Removing the worktree you are standing in succeeds, and leaves the shell in a
# directory that no longer exists — `fatal: Unable to read current working
# directory` on every command afterwards, blaming git rather than naming the
# cause. Refuse, and say where to run it from.
assert_outside() {
  local wt=$1 here real
  here=$(pwd -P 2>/dev/null) || return 0   # already in a phantom dir; nothing to protect
  real=$(cd "$wt" 2>/dev/null && pwd -P) || real="$wt"
  if [[ "$here" == "$real" || "$here" == "$real"/* ]]; then
    echo "Error: you are inside $real" >&2
    echo "       A slot cannot tear itself down - the directory would vanish under this shell." >&2
    echo "       Run it from somewhere else, e.g.:  cd $PARENT && wsw rm $(basename "$wt" | sed 's/^workspace-app-wt-//')" >&2
    exit 1
  fi
}

# ---- ports --------------------------------------------------------------------
# A port is free only if BOTH are true: nothing is listening on it right now, and
# no other slot's .port file has claimed it. The second half is the one that
# matters — a slot whose dev server happens to be down still owns its port, and
# handing it to a new slot means the two collide the moment the first restarts.
# Checking "is anything listening" alone would do exactly that.
port_claimed() {
  local port=$1 f
  shopt -s nullglob
  for f in "$BASE"/workspace-app-wt-*.port; do
    [[ "$(cat "$f" 2>/dev/null)" == "$port" ]] && return 0
  done
  return 1
}

port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

alloc_port() {
  local p
  for ((p = PORT_BASE; p <= PORT_MAX; p++)); do
    port_claimed "$p" && continue
    port_listening "$p" && continue
    echo "$p"
    return 0
  done
  return 1
}

# ---- memory -------------------------------------------------------------------
# Claude Code keys its memory directory off the working directory's path, so a
# new slot starts with an empty one and an agent there loses every accumulated
# lesson about this repo. Point it at the canonical store instead, the same way
# the clones and AIH slots do.
CANONICAL_MEMORY="$HOME/.claude/projects/-Users-daviddeegan-code-dvddgn-workspace-app/memory"

link_memory() {
  local wt=$1
  [[ -d "$CANONICAL_MEMORY" ]] || { echo "  (no canonical memory store - skipping)"; return 0; }
  # Dots are encoded as dashes too, same as separators.
  local proj="$HOME/.claude/projects/$(echo "$wt" | sed 's|[/.]|-|g')"
  mkdir -p "$proj"
  if [[ -e "$proj/memory" && ! -L "$proj/memory" ]]; then
    echo "  memory: left alone - $proj/memory already exists as a real directory"
    return 0
  fi
  [[ -L "$proj/memory" ]] && rm "$proj/memory"
  ln -s "$CANONICAL_MEMORY" "$proj/memory" \
    && echo "  memory linked ($(ls "$CANONICAL_MEMORY"/*.md 2>/dev/null | wc -l | tr -d ' ') entries)"
}

# ---- windows ------------------------------------------------------------------
# The session shape, in one place, so `new` and `restore` cannot drift apart.
# core-sessions.txt's convention for every standing session: "shell" first,
# "cc1,cc2,cx1" last, and whatever is specific to this session in between — here
# that is the one `dev` window. Two Claude windows rather than three because a
# slot is one context; cx1 is the Codex window every session gets.
make_windows() {
  local session=$1 wt=$2
  tmux new-session -d -s "$session" -c "$wt" -n shell
  tmux new-window -d -t "$session" -n dev -c "$wt"
  tmux new-window -d -t "$session" -n cc1 -c "$wt"
  tmux new-window -d -t "$session" -n cc2 -c "$wt"
  tmux new-window -d -t "$session" -n cx1 -c "$wt"
  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$session" >/dev/null 2>&1 || true
  echo "  tmux session $session: $(tmux list-windows -t "$session" -F '#{window_name}' | paste -sd' ' -)"
}

# ---- dev server ---------------------------------------------------------------
# Start it in its own window so it keeps running after this script exits and DD
# can read its output.
start_dev() {
  local session=$1 port=$2
  tmux send-keys -t "${session}:dev" "npm run dev -- -p $port" C-m
}

# A running process is not a serving app. `next dev` returns from its own boot
# long before it can answer anything — it compiles a route on that route's FIRST
# request — so "the tmux window has a node process in it" and "there is an app on
# this port" are different claims, and only the second one is worth printing.
#
# Assert on what only a served Next.js page can produce: a real HTTP status, and
# a body referencing /_next/. A status alone is too weak (curl reports one for
# anything that speaks HTTP on that port); the /_next/ reference is emitted by
# Next's own document, whether the route renders, redirects to a login page or
# returns its error overlay. Prints "<code> next" or "<code> unknown" on success,
# nothing on timeout.
wait_for_dev() {
  local port=$1 timeout=${2:-180} waited=0 code body
  while ((waited < timeout)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://localhost:$port/" 2>/dev/null)
    if [[ -n "$code" && "$code" != "000" ]]; then
      body=$(curl -s -L --max-time 20 "http://localhost:$port/" 2>/dev/null)
      if grep -q '/_next/' <<<"$body"; then
        echo "$code next"
      else
        echo "$code unknown"
      fi
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# ---- iTerm --------------------------------------------------------------------
# Killing a tmux session does NOT close whatever iTerm2 tab was attached to it —
# it leaves a dead plain shell behind for DD to notice and ask about later. $1 is
# the tty captured via `tmux list-clients` BEFORE the session is killed;
# list-clients returns nothing once it is gone, so the caller must capture it
# first. Silent no-op if there was no attached client or iTerm2 is unreachable —
# a slot torn down from a headless context is not an error.
#
# Returns non-zero when there was no tab to close, so the caller cannot print
# "iTerm2 tab closed" over a slot that never had one — the early `return 0`
# this was first written with (carried over from wt.sh) made a --no-ui slot
# report a tab closure that never happened.
close_iterm_tab() {
  local tty=$1
  [[ -n "$tty" ]] || return 1
  osascript -e "
  tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of (current session of t)) is \"$tty\" then
            close t
            return \"closed\"
          end if
        end try
      end repeat
    end repeat
  end tell
  " 2>/dev/null | grep -q closed
}

# ---- new ----------------------------------------------------------------------
cmd_new() {
  local slug="" branch="" project_ref="" start_dev_server=true open_ui=true
  while (($#)); do
    case "$1" in
      --project) project_ref="${2:?--project needs a Workspace project reference}"; shift 2 ;;
      --no-dev) start_dev_server=false; shift ;;
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

  local wt="$BASE/workspace-app-wt-$slug" session="wsw-$slug"
  [[ -e "$wt" ]] && die "$wt already exists"
  tmux has-session -t "$session" 2>/dev/null && die "tmux session $session already exists"
  [[ -d "$PARENT" ]] || die "parent clone not found at $PARENT"
  [[ -f "$PARENT/.env.local" ]] || die "no .env.local in $PARENT - a slot without it cannot reach Supabase"

  echo "Creating slot '$slug' on branch $branch"
  git -C "$PARENT" fetch origin main --quiet

  # An existing branch is checked out; otherwise one is cut from origin/main. A
  # branch can only be checked out in one worktree, which is what stops two
  # agents ending up on the same branch in two trees — and, here, what stops a
  # slot fighting the loop for a branch the loop is building on in the parent.
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

  # -p preserves the mode: .env.agents is 0600 in the parent and holds the
  # service-role key and the Postgres password. A hand-rolled `cp` left one of
  # the existing worktrees' copies world-readable at 0644.
  local envf
  for envf in .env.local .env.agents; do
    if [[ -f "$PARENT/$envf" ]]; then
      cp -p "$PARENT/$envf" "$wt/$envf" && echo "  $envf copied ($(stat -f '%Lp' "$wt/$envf"))"
    else
      echo "  ($envf not in the parent - skipped)"
    fi
  done

  # Copy, never symlink: Next writes into node_modules/.cache and two worktrees
  # sharing that directory collide. -Rc is APFS copy-on-write. Measured on this
  # machine 2026-09-06, by free-space delta rather than `du` (which reports the
  # apparent 1.0G either way): cp -Rc costs 26MB of real disk, cp -R costs 583MB,
  # and a real `npm install` costs the full ~1.0GB. The -c is the whole point.
  if [[ -d "$PARENT/node_modules" ]]; then
    if cp -Rc "$PARENT/node_modules" "$wt/node_modules" 2>/dev/null; then
      # Verify the clone by the artifact that matters, not by cp's exit code: the
      # binary the dev server is about to be started with.
      if [[ -x "$wt/node_modules/.bin/next" ]]; then
        echo "  node_modules cloned (copy-on-write, $(du -sh "$wt/node_modules" 2>/dev/null | cut -f1 | tr -d ' ') apparent)"
      else
        die "node_modules cloned but node_modules/.bin/next is missing - the slot would not run"
      fi
    else
      die "node_modules clone failed (cp -Rc) - fix that rather than running npm install per slot; a real install is 1.0GB"
    fi
  else
    echo "  (no node_modules in the parent - run npm install in the slot)"
  fi

  link_memory "$wt"

  local port=""
  if $start_dev_server; then
    port=$(alloc_port) || die "no free port in $PORT_BASE-$PORT_MAX"
    echo "$port" > "$wt.port"
    echo "  port $port (recorded in $(basename "$wt.port"))"
  fi

  make_windows "$session" "$wt"
  if [[ -n "$project_ref" ]]; then
    [[ -x "$TMUX_PROJECT" ]] || die "tmux project helper not found at $TMUX_PROJECT"
    "$TMUX_PROJECT" bind "$session" "$project_ref" \
      || echo "  project status could not be applied; retry with: $TMUX_PROJECT bind $session $project_ref"
  fi

  local urlline
  if $start_dev_server; then
    start_dev "$session" "$port"
    echo "  dev server starting on $port (next dev compiles on first request - waiting for it to answer)"
    local ready
    if ready=$(wait_for_dev "$port"); then
      local code=${ready% *} kind=${ready#* }
      if [[ "$kind" == "next" ]]; then
        echo "  dev server answering: HTTP $code, Next.js confirmed"
        urlline="  url       http://localhost:$port   (HTTP $code)"
      else
        echo "  dev server answering: HTTP $code, but the body has no /_next/ reference - check the dev window"
        urlline="  url       http://localhost:$port   (HTTP $code - NOT confirmed as Next.js)"
      fi
    else
      echo "  dev server did NOT answer on $port within the timeout - read: tmux attach -t $session (window dev)"
      urlline="  url       http://localhost:$port   (NOT ANSWERING - see the dev window)"
    fi
  else
    urlline="  url       no server (--no-dev) - start one with: tmux send-keys -t $session:dev 'npm run dev -- -p <port>' C-m"
  fi

  # A slot is interactive by definition — nothing automated creates one, since
  # the loop works in the parent clone. So there is no "is this for a person?" to
  # decide: open the tab every time. cs.sh prints its own by-hand instruction on
  # every unhappy path; its exit code is read only so this summary does not claim
  # a tab that is not there.
  local uiline
  if $open_ui; then
    local tab_rc=0
    [[ -x "$CS" ]] && { "$CS" tab "$session"; tab_rc=$?; }
    if [[ $tab_rc -eq 0 ]]; then
      uiline="  window    iTerm2 tab opened"
    else
      uiline="  window    the iTerm2 tab needs a hand - see the note above"
    fi
  else
    uiline="  window    not opened (--no-ui) - by hand: cs tab $session"
  fi

  cat <<EOF

Slot ready.
  path      $wt
  branch    $branch
$urlline
$uiline
  agent     tmux send-keys -t $session:cc1 'ccp <project-slug>' C-m
  close     wsw rm $slug        (from outside the slot)

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

  local wt="$BASE/workspace-app-wt-$slug" session="wsw-$slug"
  assert_outside "$wt"

  # Nothing is torn down until this passes. Removing a slot is the park/abandon
  # path and parking is the common one — the slot goes, the branch stays, and the
  # same work resumes later via `wsw new <slug> <branch>`. So the two things
  # worth losing sleep over are checked here, together, BEFORE anything is taken.
  #
  # This refuses rather than warns because the remedy — push — is impossible once
  # the directory is gone, and a warning printed immediately before the thing it
  # warns about is not a control. Unpushed commits survive teardown in $PARENT's
  # object store, but held reachable by the local branch ref and nothing else.
  if ! $force && [[ -d "$wt" ]]; then
    local branch_now dirty unpushed
    branch_now=$(git -C "$wt" branch --show-current 2>/dev/null)
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
    unpushed=$(git -C "$wt" log HEAD --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [[ -n "$dirty" ]]; then
      echo "Error: uncommitted changes in $wt - nothing has been torn down." >&2
      git -C "$wt" status --short >&2
      echo "       Commit them, or re-run with --force once you have looked at them." >&2
      exit 1
    fi
    if [[ "$unpushed" != "0" ]]; then
      echo "Error: $unpushed commit(s) on ${branch_now:-HEAD} are on no remote - nothing has been torn down." >&2
      git -C "$wt" log HEAD --not --remotes --oneline >&2
      echo "       Parking this slot? Push first, so the branch reopens from anywhere:" >&2
      echo "         git -C $wt push -u origin ${branch_now:-HEAD}" >&2
      echo "       Abandoning it? Re-run with --force." >&2
      exit 1
    fi
  fi

  echo "Removing slot '$slug'"

  if tmux has-session -t "$session" 2>/dev/null; then
    local tty
    tty=$(tmux list-clients -t "$session" -F "#{client_tty}" 2>/dev/null | head -1)
    # The dev server is a child of the dev window's shell, so killing the session
    # takes it with it and frees the port.
    tmux kill-session -t "$session" && echo "  tmux session killed"
    close_iterm_tab "$tty" && echo "  iTerm2 tab closed"
  fi

  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" forget "$session" >/dev/null 2>&1 || true

  # The port file lives BESIDE the worktree — anything inside would show up in
  # every `git status` — which is also why `git worktree remove` cannot take it
  # with the directory and why nothing else ever removes it.
  [[ -f "$wt.port" ]] && rm -f "$wt.port" && echo "  port file removed"

  if [[ -d "$wt" ]]; then
    local branch
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    if $force; then
      # `--force` still refuses when it cannot clear the directory (something was
      # writing to .next, node_modules is busy), and it leaves the registration
      # behind while reporting failure. Take the files ourselves: --force has
      # already accepted the loss of anything uncommitted.
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
        || echo "  worktree NOT removed - uncommitted work? re-run with --force once you have checked"
    fi
    [[ -n "$branch" ]] && \
      echo "  branch $branch still exists: git -C $PARENT branch -d $branch"
  else
    echo "  (no directory at $wt)"
  fi

  # Catches both the husk case (a directory that was never a real worktree) and a
  # registration whose directory has already been deleted by hand.
  git -C "$PARENT" worktree prune && echo "  worktree registrations pruned"

  if [[ -d "$wt" ]]; then
    echo "NOT fully removed: $wt is still on disk ($(du -sh "$wt" 2>/dev/null | cut -f1 | tr -d ' '))." >&2
    exit 1
  fi
}

# ---- ls -----------------------------------------------------------------------
# Every workspace-app-wt-* directory on disk, whether or not `wsw` made it. The
# three slots that existed when this script was written were all hand-rolled and
# had no session and no port file; a listing that only knew about its own slots
# would have shown nothing, which is how they accumulated unnoticed in the first
# place. Registration comes from `git worktree list`, not from the directory
# name — a `git worktree move` that left files behind produces a husk directory
# that matches the glob and is not a worktree at all.
cmd_ls() {
  local wt slug branch port dirty session state registered found=0
  shopt -s nullglob

  local -a reg_paths=()
  while IFS= read -r line; do
    reg_paths+=("${line%% *}")
  done < <(git -C "$PARENT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')

  printf '%-18s %-52s %-6s %-10s %s\n' "SLUG" "BRANCH" "PORT" "DIRTY" "SESSION"
  for wt in "$BASE"/workspace-app-wt-*/; do
    wt="${wt%/}"
    slug="${wt##*/workspace-app-wt-}"
    found=$((found + 1))

    registered=no
    local p
    for p in "${reg_paths[@]}"; do [[ "$p" == "$wt" ]] && registered=yes; done

    if [[ "$registered" == "no" ]]; then
      printf '%-18s %-52s %-6s %-10s %s\n' "$slug" "!! not a registered worktree (husk)" "-" "-" "-"
      continue
    fi

    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    [[ -z "$branch" ]] && branch="(detached $(git -C "$wt" rev-parse --short HEAD 2>/dev/null))"
    port=$(cat "$wt.port" 2>/dev/null || echo '-')
    dirty=$(git -C "$wt" status --short 2>/dev/null | wc -l | tr -d ' ')
    [[ "$dirty" == "0" ]] && dirty="clean" || dirty="$dirty file(s)"
    session="wsw-$slug"
    if tmux has-session -t "$session" 2>/dev/null; then
      state="$session (up)"
    else
      state="$session (down)"
    fi
    # A port recorded but nothing listening means the dev server is not running —
    # worth distinguishing from having no port at all, since the port is still
    # claimed either way.
    if [[ "$port" != "-" ]] && ! port_listening "$port"; then
      port="$port!"
    fi
    printf '%-18s %-52s %-6s %-10s %s\n' "$slug" "$branch" "$port" "$dirty" "$state"
  done

  # A registration whose directory is gone is invisible to the loop above and
  # still blocks the path from being reused.
  local p slug2
  for p in "${reg_paths[@]}"; do
    [[ "$p" == "$PARENT" ]] && continue
    [[ -d "$p" ]] && continue
    slug2="${p##*/workspace-app-wt-}"
    printf '%-18s %-52s %-6s %-10s %s\n' "$slug2" "!! registered but the directory is gone" "-" "-" "run: git -C $PARENT worktree prune"
    found=$((found + 1))
  done

  [[ "$found" == "0" ]] && { echo "No slots."; return 0; }
  echo
  echo "PORT with a trailing ! is claimed but nothing is listening (dev server down)."
  return 0
}

# ---- restore ------------------------------------------------------------------
# tmux does not survive a reboot — there is no resurrect/continuum here, so the
# server dies with every session in it. The worktrees survive, and so do the
# Claude transcripts (they live in ~/.claude/projects, not in the worktree). So a
# restart loses the sessions and nothing else, and this rebuilds them.
#
# It does NOT start the dev servers or resume the agents; it prints how to.
cmd_restore() {
  local slug_filter="${1:-}" wt slug session found=0 port
  shopt -s nullglob
  for wt in "$BASE"/workspace-app-wt-*/; do
    wt="${wt%/}"
    # A directory matching the glob is not necessarily a real worktree. Same husk
    # case cmd_ls guards against; standing a tmux session up for one would make a
    # leftover look like a live slot.
    [[ -e "$wt/.git" ]] || continue
    slug="${wt##*/workspace-app-wt-}"
    [[ -n "$slug_filter" && "$slug" != "$slug_filter" ]] && continue
    found=$((found + 1))
    session="wsw-$slug"

    if tmux has-session -t "$session" 2>/dev/null; then
      echo "  $slug: session already up"
      continue
    fi
    make_windows "$session" "$wt"
    link_memory "$wt" >/dev/null
    [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$session" >/dev/null 2>&1 || true
    port=$(cat "$wt.port" 2>/dev/null)
    if [[ -n "$port" ]]; then
      echo "     dev:    tmux send-keys -t $session:dev 'npm run dev -- -p $port' C-m"
    else
      echo "     dev:    no port recorded - this slot was hand-rolled; wsw rm and wsw new to adopt it"
    fi
  done

  [[ "$found" == "0" ]] && { echo "No slots found."; return 0; }
  echo
  echo "$found slot(s). Sessions rebuilt; dev servers and agents are not started."
}

case "${1:-}" in
  new)     shift; cmd_new "$@" ;;
  rm)      shift; cmd_rm "$@" ;;
  ls)      shift; cmd_ls "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown command '$1' (use new, rm, ls or restore)" ;;
esac
