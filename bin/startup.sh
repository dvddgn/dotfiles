#!/bin/zsh
# Master startup script — opens VS Code and creates tmux sessions
#
# Usage:
#   ./startup.sh              # start ALL sessions
#   ./startup.sh aih          # start just aih
#   ./startup.sh aih c1 ws    # start specific sessions
#   ./startup.sh --list       # show available session names
#   ./startup.sh --status     # show running tmux sessions
#
# The session list, each one's directory, and its extra windows all come from
# core-sessions.txt (beside this script) rather than being hard-coded here -
# add a line there for a new standing session and this script picks it up
# with no code change. cs.sh's `ensure_core_sessions()` reads the exact same
# file for the safe (create-only-if-missing) path; this script stays the
# unconditional kill-and-recreate one, so it must only ever be run by hand,
# right after a confirmed reboot or when a session is deliberately being reset
# — never automatically, and never with live work still in it.

CORE_SESSIONS="$HOME/code/dvddgn/dotfiles/core-sessions.txt"
TMUX_PROJECT="$HOME/code/dvddgn/dotfiles/bin/tmux-project.sh"

typeset -A SESSION_DIR SESSION_EXTRA
ALL_SESSIONS=()

load_core_sessions() {
  local name dir extra
  while IFS='|' read -r name dir extra; do
    name="${name// /}"
    [[ -z "$name" || "$name" == \#* ]] && continue
    # Trim ALL leading/trailing whitespace, not just one space - the file pads
    # columns for readability, and a single-space trim silently left a
    # trailing space on the directory, which made `-c "$DIR"` reference a
    # path that doesn't exist and made tmux fall back to $HOME instead of
    # erroring - caught by checking pane_current_path after a real test run,
    # not by the tmux commands themselves, which failed silently.
    dir="${dir#"${dir%%[![:space:]]*}"}"; dir="${dir%"${dir##*[![:space:]]}"}"
    extra="${extra#"${extra%%[![:space:]]*}"}"; extra="${extra%"${extra##*[![:space:]]}"}"
    case "$dir" in
      "~"*) dir="${dir/#\~/$HOME}" ;;
      /*) : ;;
      *) dir="$HOME/code/dvddgn/$dir" ;;
    esac
    SESSION_DIR[$name]="$dir"
    SESSION_EXTRA[$name]="$extra"
    ALL_SESSIONS+=("$name")
  done < "$CORE_SESSIONS"
}
load_core_sessions

get_dir() {
  echo "${SESSION_DIR[$1]:-}"
}

# Handle flags
case "$1" in
  --list)
    echo "Available sessions:"
    for s in "${ALL_SESSIONS[@]}"; do
      echo "  $s  →  $(get_dir $s)"
    done
    exit 0
    ;;
  --status)
    tmux ls 2>/dev/null || echo "No tmux sessions running"
    exit 0
    ;;
esac

# Parse --no-code flag (skip VS Code launch)
NO_CODE=false
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--no-code" ]]; then
    NO_CODE=true
  else
    ARGS+=("$arg")
  fi
done

# Determine which sessions to start
if [ ${#ARGS[@]} -gt 0 ]; then
  SESSIONS=("${ARGS[@]}")
else
  SESSIONS=("${ALL_SESSIONS[@]}")
fi

for SESSION in "${SESSIONS[@]}"; do
  DIR="$(get_dir $SESSION)"

  if [ -z "$DIR" ]; then
    echo "Unknown session: $SESSION (run ./startup.sh --list to see options)"
    continue
  fi

  echo "Setting up $SESSION ($DIR)..."

  # Kill existing session if it exists
  tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION"

  # Create session — first window is a shell
  tmux new-session -d -s "$SESSION" -n "shell" -c "$DIR"

  # Extra windows specific to this session, from core-sessions.txt. A window
  # can auto-run a command on creation: "name:command" instead of a bare
  # "name" (ws's health-check is the worked example in the file itself).
  local extra="${SESSION_EXTRA[$SESSION]}"
  if [[ -n "$extra" ]]; then
    for item in "${(s:,:)extra}"; do
      [[ -z "$item" ]] && continue
      wname="${item%%:*}"
      if [[ "$item" == *:* ]]; then wcmd="${item#*:}"; else wcmd=""; fi
      tmux new-window -t "$SESSION" -n "$wname" -c "$DIR"
      [[ -n "$wcmd" ]] && tmux send-keys -t "${SESSION}:${wname}" "$wcmd" C-m
    done
  fi

  # Claude Code agent windows (not started — type cc or cc --resume <name> to start)
  tmux new-window -t "$SESSION" -n "cc1" -c "$DIR"
  tmux new-window -t "$SESSION" -n "cc2" -c "$DIR"
  tmux new-window -t "$SESSION" -n "cc3" -c "$DIR"

  # Codex agent window (not started — type cx to start)
  tmux new-window -t "$SESSION" -n "cx1" -c "$DIR"

  # Start on first window
  tmux select-window -t "${SESSION}:1"
  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$SESSION" >/dev/null 2>&1 || true

  # Open VS Code (use workspace file if it exists, unless --no-code)
  if [ "$NO_CODE" = false ]; then
    local ws_files=("$DIR"/*.code-workspace(N))
    if [ ${#ws_files[@]} -gt 0 ]; then
      code "${ws_files[1]}"
    else
      code "$DIR"
    fi
  fi
done

echo ""
echo "Done. Sessions created:"
tmux ls 2>/dev/null
echo ""
echo "To attach: tmux attach -t <name>"
