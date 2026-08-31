#!/bin/bash
# Start/stop/restart rails, sidekiq, vite (or css for hre) in any tmux session
# Usage: ./services.sh <session> <start|stop|restart> [rails|sidekiq|vite|css|all] [--take]
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
# Stopping the same service in every other checkout was correct while Rails, Vite
# and Sidekiq were shared singletons: starting yours required taking theirs. Since
# each slot got its own port and its own Redis database (2026-08-27) there is
# nothing to contend over, so seizing is now pure collateral damage - it Ctrl-Cs a
# colleague's running service for no benefit.
#
# Keep others by default. --take restores the old behaviour, which is still the
# only way for a checkout that genuinely shares: an old branch with no
# VITE_RUBY_PORT, or a slot past the 15-index Redis ceiling.
KEEP_OTHERS=true

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --take)        KEEP_OTHERS=false ;;
    --keep-others) KEEP_OTHERS=true ;;   # now the default; accepted so old commands still work
    *)             ARGS+=("$arg") ;;
  esac
done

SESSION="${ARGS[0]:?Usage: ./services.sh <session> <start|stop|restart> [rails|sidekiq|vite|all] [--keep-others]}"
ACTION="${ARGS[1]:?Usage: ./services.sh <session> <start|stop|restart> [rails|sidekiq|vite|all] [--keep-others]}"
SERVICE="${ARGS[2]:-all}"
AIH_BASE="$HOME/code/dvddgn"

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

# hre needed an explicit exemption when seizing was the default - it has its own
# local DB and port, so it never had cause to stop anyone. That is now every
# checkout's position, so the special case is gone.

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
      echo "  → --take: stopping $window in $s (was: $cmd)" >&2
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
# Every checkout defaults to redis db0, so all workers pop from one queue and a
# job dispatched here can be executed by another checkout running different code
# - silently, and recorded as a real result. Redis has 16 databases; giving a
# checkout its own makes its queue invisible to every other worker.
#
# Allocated when Sidekiq is first started here, not at slot creation: a checkout
# with no worker has nothing to isolate, and there are only 8 slot indices.
# Clones hold 1-7 (fixed, set once in their own .env); slots take 8-15; anything
# unallocated stays on db0 and behaves exactly as before.
#
# ENV.fetch('REDIS_URL', ...) has been in config/initializers/sidekiq.rb since
# 2025-09-03 for BOTH configure_server and configure_client, so every branch
# honours this - no capability guard needed, unlike the Vite equivalent.
redis_db_from_env() {
  sed -n 's|^REDIS_URL=redis://localhost:6379/\([0-9][0-9]*\)$|\1|p' "$1/.env" 2>/dev/null | tail -1
}

redis_db_claimed_elsewhere() {
  local wt=$1 db=$2 candidate candidate_db marker
  shopt -s nullglob
  for marker in "$AIH_BASE"/aih-wt-*.redisdb; do
    [[ "$marker" == "$wt.redisdb" ]] && continue
    candidate_db=$(cat "$marker" 2>/dev/null || true)
    [[ "$candidate_db" == "$db" ]] && return 0
  done
  for candidate in "$AIH_BASE"/aih-wt-*/; do
    candidate="${candidate%/}"
    [[ "$candidate" == "$wt" ]] && continue
    candidate_db=$(cat "$candidate.redisdb" 2>/dev/null || true)
    [[ "$candidate_db" == "$db" ]] && return 0
    candidate_db=$(redis_db_from_env "$candidate")
    [[ "$candidate_db" == "$db" ]] && return 0
  done
  return 1
}

write_redis_url() {
  local wt=$1 db=$2 env="$wt/.env" tmp
  tmp=$(mktemp "$env.redis.XXXXXX") || return 1
  awk -v url="REDIS_URL=redis://localhost:6379/$db" '
    /^REDIS_URL=/ { if (!written++) print url; next }
    { print }
    END { if (!written) print url }
  ' "$env" > "$tmp" && mv "$tmp" "$env"
}

# A slot's marker is the source of truth. The lock makes the scan-and-claim
# sequence atomic when two slots start at the same time. Existing .env values
# are considered claims too, so legacy slots without markers cannot be reused.
resolve_redis_db() {
  local wt=$1 marker="$1.redisdb" lock="$AIH_BASE/.aih-redis-allocation.lock"
  local db env_db attempt=0

  until mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [[ $attempt -lt 100 ]] || { echo "Redis allocation lock is busy: $lock" >&2; return 1; }
    sleep 0.05
  done

  db=$(cat "$marker" 2>/dev/null || true)
  env_db=$(redis_db_from_env "$wt")
  if [[ -n "$db" ]]; then
    if [[ ! "$db" =~ ^(8|9|1[0-5])$ ]]; then
      echo "Invalid Redis allocation marker $marker: '$db'" >&2
      rmdir "$lock"
      return 1
    fi
    if redis_db_claimed_elsewhere "$wt" "$db"; then
      echo "Redis db $db for $(basename "$wt") is also claimed by another worktree" >&2
      rmdir "$lock"
      return 1
    fi
  elif [[ "$env_db" =~ ^(8|9|1[0-5])$ ]] && ! redis_db_claimed_elsewhere "$wt" "$env_db"; then
    db="$env_db"
    printf '%s\n' "$db" > "$marker"
    echo "  (adopted existing Redis db $db for $(basename "$wt"))" >&2
  else
    db=""
    for candidate_db in {8..15}; do
      if ! redis_db_claimed_elsewhere "$wt" "$candidate_db"; then
        db="$candidate_db"
        break
      fi
    done
    if [[ -z "$db" ]]; then
      rmdir "$lock"
      echo ""
      return 0
    fi
    printf '%s\n' "$db" > "$marker"
    echo "  (allocated Redis db $db for $(basename "$wt"))" >&2
  fi

  if [[ "$env_db" != "$db" ]]; then
    write_redis_url "$wt" "$db" || { rmdir "$lock"; return 1; }
  fi
  rmdir "$lock"
  echo "$db"
}

REDIS_DB=""
# Stopping a service must not claim or rewrite a queue assignment. Allocation is
# needed before a checkout starts services, because Rails reads REDIS_URL at boot.
if [[ "$ACTION" != stop && "$SESSION" == wt-* && -d "$SESSION_DIR" ]]; then
  REDIS_DB=$(resolve_redis_db "$SESSION_DIR") || exit 1
  if [[ -z "$REDIS_DB" ]]; then
    echo "  WARNING: no free Redis index (8-15 all taken) - $SESSION stays on db0, shared" >&2
  fi
fi
SIDEKIQ_CMD="${REDIS_DB:+REDIS_URL=redis://localhost:6379/$REDIS_DB }bundle exec sidekiq -C config/sidekiq.yml"
# Every checkout is pinned to 3036 by config/vite.json, and only one process can
# hold a port - so the first to start serves JavaScript to all the others,
# silently. A worktree slot gets its own, derived from its Rails port.
#
# It has to reach two processes by two routes: Rails reads it from .env on boot,
# and `bin/vite dev` does NOT (dotenv only loads inside Rails), so it is also
# passed on the command line. Written here rather than only by `wt new`, so a
# slot created with --no-rails still gets one when a server is first started.
# Only if the checkout's vite.config.ts actually honours the variable. Setting it
# against a config that still hardcodes 3036 is worse than doing nothing: Vite
# binds 3036 (or fails, strictPort) while Rails proxies to the port named here -
# which is very likely another checkout's Vite. The capability is checked rather
# than assumed, so this works either side of PR #769 landing.
VITE_PORT=""
if [[ "$SESSION" == wt-* && -d "$SESSION_DIR" && "$PORT" =~ ^[0-9]+$ ]] \
   && grep -q 'VITE_RUBY_PORT' "$SESSION_DIR/vite.config.ts" 2>/dev/null; then
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
