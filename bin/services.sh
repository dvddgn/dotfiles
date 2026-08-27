#!/bin/bash
# Start/stop/restart rails, sidekiq, vite (or css for hre) in any tmux session
# Usage: ./services.sh <session> <start|stop|restart> [rails|sidekiq|vite|css|all] [--keep-others]
#
# On start/restart, services of the same kind running in OTHER sessions are
# stopped first (shared Supabase DB + shared vite port make concurrent runs
# messy). Pass --keep-others to skip this. Stop never touches other sessions.

STATIC_SESSIONS=(aih c1 c2 c3 c4 c5 m1 m2 m3 m4 m5)
# Worktree sessions (wt-<slug>) are created on demand, so discover them from tmux
# rather than hardcoding. Without this, a server left running in a worktree would
# survive the stop sweep and keep holding sidekiq's queue or vite's port.
WT_SESSIONS=($(tmux ls -F "#{session_name}" 2>/dev/null | grep '^wt-' || true))
ALL_SESSIONS=("${STATIC_SESSIONS[@]}" "${WT_SESSIONS[@]}")
KEEP_OTHERS=false

# Parse args, pulling out --keep-others
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--keep-others" ]]; then
    KEEP_OTHERS=true
  else
    ARGS+=("$arg")
  fi
done

SESSION="${ARGS[0]:?Usage: ./services.sh <session> <start|stop|restart> [rails|sidekiq|vite|all] [--keep-others]}"
ACTION="${ARGS[1]:?Usage: ./services.sh <session> <start|stop|restart> [rails|sidekiq|vite|all] [--keep-others]}"
SERVICE="${ARGS[2]:-all}"

# Directory backing a session. Worktrees follow the convention wt-<slug> -> aih-wt-<slug>.
session_dir() {
  case "$1" in
    aih)    echo "$HOME/code/dvddgn/advice-innovation-hub" ;;
    c[1-5]) echo "$HOME/code/dvddgn/advice-innovation-hub-clone-${1#c}" ;;
    m[1-5]) echo "$HOME/code/dvddgn/advice-innovation-hub-${1}" ;;
    hre)    echo "$HOME/code/dvddgn/horizons-real-estate" ;;
    wt-*)   echo "$HOME/code/dvddgn/aih-wt-${1#wt-}" ;;
    *)      echo "" ;;
  esac
}

# A worktree's Rails port is recorded at first use and never moves after that, so the URL
# stays stable across restarts. Clones own 3000-3011; worktrees start at 3012.
# The record lives BESIDE the worktree, not inside it, so it never shows up as an untracked
# file in git status or gets committed by accident.
resolve_wt_port() {
  local dir=$1 f=$1.port p=3012
  [[ -f "$f" ]] && { cat "$f"; return; }
  while lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 \
     || grep -qx "$p" "$HOME"/code/dvddgn/aih-wt-*.port 2>/dev/null; do
    p=$((p+1))
  done
  echo "$p" | tee "$f"
}

# cct-created sessions have a single shell window, so create service windows on demand.
ensure_window() {
  local s=$1 w=$2 dir
  dir="$(session_dir "$s")"
  tmux list-windows -t "$s" -F "#{window_name}" 2>/dev/null | grep -qx "$w" && return 0
  # tmux refuses -c on a directory that does not exist, and the failure is easy to
  # miss: the send-keys that follows then reports "can't find window: <name>", which
  # names the wrong problem entirely. Fail here, where the real cause is visible.
  if [[ -n "$dir" && ! -d "$dir" ]]; then
    echo "Error: no directory at $dir — is '$s' a real session?" >&2
    exit 1
  fi
  tmux new-window -d -t "$s" -n "$w" -c "${dir:-$PWD}" || {
    echo "Error: could not create window '$w' in session '$s'" >&2
    exit 1
  }
}

# Resolve the directory unconditionally - the vite port is read from its .env
# whether or not the session already exists.
SESSION_DIR="$(session_dir "$SESSION")"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  if [[ "$SESSION" == wt-* && -d "$SESSION_DIR" ]]; then
    echo "Creating tmux session $SESSION at $SESSION_DIR"
    tmux new-session -d -s "$SESSION" -c "$SESSION_DIR"
  else
    echo "Session '$SESSION' not found. Run tmux ls to see available sessions."
    exit 1
  fi
fi

# hre has its own local DB and port — no cross-session conflicts, never stop others
[[ "$SESSION" == "hre" ]] && KEEP_OTHERS=true

# Determine port based on session
case "$SESSION" in
  aih) PORT=3000 ;;
  c1)  PORT=3001 ;;
  c2)  PORT=3002 ;;
  c3)  PORT=3003 ;;
  c4)  PORT=3004 ;;
  c5)  PORT=3005 ;;
  m1)  PORT=3006 ;;
  m2)  PORT=3007 ;;
  m3)  PORT=3008 ;;
  m4)  PORT=3009 ;;
  m5)  PORT=3010 ;;
  hre) PORT=3011 ;;
  wt-*) PORT=$(resolve_wt_port "$(session_dir "$SESSION")") ;;
  *)   PORT=3000 ;;
esac

# Returns the current command in <session>:<window>'s pane, or empty if window absent
window_command() {
  local s=$1
  local w=$2
  tmux list-windows -t "$s" -F "#{window_name}|#{pane_current_command}" 2>/dev/null \
    | awk -F'|' -v w="$w" '$1==w {print $2}'
}

# Returns 0 if the window appears to have a running service (non-shell command)
window_is_running() {
  local cmd=$1
  [[ -n "$cmd" && "$cmd" != "zsh" && "$cmd" != "bash" && "$cmd" != "fish" && "$cmd" != "sh" ]]
}

# Stop the given service in all other sessions where it's actively running
stop_others() {
  local window=$1
  $KEEP_OTHERS && return 0
  for s in "${ALL_SESSIONS[@]}"; do
    [[ "$s" == "$SESSION" ]] && continue
    tmux has-session -t "$s" 2>/dev/null || continue
    local cmd
    cmd=$(window_command "$s" "$window")
    if window_is_running "$cmd"; then
      echo "  → Stopping $window in $s (was: $cmd)"
      tmux send-keys -t "$s:$window" C-c
    fi
  done
}

start_service() {
  local window=$1
  local cmd=$2
  ensure_window "$SESSION" "$window"
  stop_others "$window"
  echo "Starting $window in $SESSION..."
  tmux send-keys -t "$SESSION:$window" "$cmd" C-m
}

stop_service() {
  local window=$1
  echo "Stopping $window in $SESSION..."
  tmux send-keys -t "$SESSION:$window" C-c
}

restart_service() {
  local window=$1
  local cmd=$2
  ensure_window "$SESSION" "$window"
  stop_others "$window"
  echo "Restarting $window in $SESSION..."
  tmux send-keys -t "$SESSION:$window" C-c
  sleep 1
  tmux send-keys -t "$SESSION:$window" "$cmd" C-m
}

do_action() {
  local window=$1
  local cmd=$2
  case "$ACTION" in
    start)   start_service "$window" "$cmd" ;;
    stop)    stop_service "$window" ;;
    restart) restart_service "$window" "$cmd" ;;
    *)       echo "Unknown action: $ACTION (use start|stop|restart)"; exit 1 ;;
  esac
}

RAILS_CMD="bin/rails server -p $PORT"
SIDEKIQ_CMD="bundle exec sidekiq -C config/sidekiq.yml"
# Every checkout is pinned to 3036 by config/vite.json, and only one process can
# hold a port - so the first to start serves JavaScript to all the others,
# silently. A worktree slot gets its own, derived from its Rails port.
#
# It has to reach two processes by two routes: Rails reads it from .env on boot,
# and `bin/vite dev` does NOT (dotenv only loads inside Rails), so it is also
# passed on the command line. Written here rather than only by `wt new`, so a
# slot created with --no-rails still gets one when a server is first started.
VITE_PORT=""
if [[ "$SESSION" == wt-* && -d "$SESSION_DIR" && "$PORT" =~ ^[0-9]+$ ]]; then
  VITE_PORT=$(grep -h '^VITE_RUBY_PORT=' "$SESSION_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2)
  if [[ -z "$VITE_PORT" ]]; then
    VITE_PORT=$((PORT + 30))     # 3012+ -> 3042+, clear of vite's 3036/3037
    {
      echo ""
      echo "# This checkout's own Vite dev server. Without it every checkout shares"
      echo "# 3036 and the first one to start serves JavaScript to all the others."
      echo "VITE_RUBY_PORT=$VITE_PORT"
    } >> "$SESSION_DIR/.env"
    echo "  (allocated Vite port $VITE_PORT for $SESSION)"
  fi
fi
VITE_CMD="${VITE_PORT:+VITE_RUBY_PORT=$VITE_PORT }bin/vite dev"
CSS_CMD="bin/rails tailwindcss:watch"

case "$SERVICE" in
  rails)   do_action "rails" "$RAILS_CMD" ;;
  sidekiq) do_action "sidekiq" "$SIDEKIQ_CMD" ;;
  vite)    do_action "vite" "$VITE_CMD" ;;
  css)     do_action "css" "$CSS_CMD" ;;
  all)
    if [[ "$SESSION" == "hre" ]]; then
      do_action "rails" "$RAILS_CMD"
      do_action "css" "$CSS_CMD"
    else
      do_action "rails" "$RAILS_CMD"
      do_action "sidekiq" "$SIDEKIQ_CMD"
      do_action "vite" "$VITE_CMD"
    fi
    ;;
  *)       echo "Unknown service: $SERVICE (use rails|sidekiq|vite|css|all)"; exit 1 ;;
esac

echo "Done."
