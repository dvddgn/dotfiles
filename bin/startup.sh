#!/bin/zsh
# Master startup script — opens VS Code and creates tmux sessions
#
# Usage:
#   ./startup.sh              # start ALL sessions
#   ./startup.sh aih          # start just aih
#   ./startup.sh aih c1 ws    # start specific sessions
#   ./startup.sh --list       # show available session names
#   ./startup.sh --status     # show running tmux sessions

get_dir() {
  case "$1" in
    aih)  echo "$HOME/code/dvddgn/advice-innovation-hub" ;;
    c1)   echo "$HOME/code/dvddgn/advice-innovation-hub-clone-1" ;;
    c2)   echo "$HOME/code/dvddgn/advice-innovation-hub-clone-2" ;;
    c3)   echo "$HOME/code/dvddgn/advice-innovation-hub-clone-3" ;;
    c4)   echo "$HOME/code/dvddgn/advice-innovation-hub-clone-4" ;;
    c5)   echo "$HOME/code/dvddgn/advice-innovation-hub-clone-5" ;;
    m1)   echo "$HOME/code/dvddgn/advice-innovation-hub-m1" ;;
    m2)   echo "$HOME/code/dvddgn/advice-innovation-hub-m2" ;;
    m3)   echo "$HOME/code/dvddgn/advice-innovation-hub-m3" ;;
    m4)   echo "$HOME/code/dvddgn/advice-innovation-hub-m4" ;;
    m5)   echo "$HOME/code/dvddgn/advice-innovation-hub-m5" ;;
    ws)   echo "$HOME/code/dvddgn/workspace-app" ;;
    hre)  echo "$HOME/code/dvddgn/horizons-real-estate" ;;
    claw) echo "$HOME/.openclaw/workspace" ;;
    *)    echo "" ;;
  esac
}

ALL_SESSIONS=(aih c1 c2 c3 c4 c5 m1 m2 m3 m4 m5 ws hre claw)

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

  # Add service windows based on session type
  case "$SESSION" in
    aih|c1|c2|c3|c4|c5|m1|m2|m3|m4|m5)
      # Rails apps — rails, sidekiq, vite (not started, ready to go)
      tmux new-window -t "$SESSION" -n "rails" -c "$DIR"
      tmux new-window -t "$SESSION" -n "sidekiq" -c "$DIR"
      tmux new-window -t "$SESSION" -n "vite" -c "$DIR"
      ;;
    ws)
      # Health check (auto-starts)
      tmux new-window -t "$SESSION" -n "health" -c "$DIR"
      tmux send-keys -t "${SESSION}:health" "./ai-builder/scripts/health-check.sh" C-m
      # Next.js app — dev server (not started)
      tmux new-window -t "$SESSION" -n "localhost" -c "$DIR"
      ;;
    hre)
      # Horizons Real Estate (Rails 8.1) — rails + tailwind watch (not started, ready to go)
      tmux new-window -t "$SESSION" -n "rails" -c "$DIR"
      tmux new-window -t "$SESSION" -n "css" -c "$DIR"
      ;;
    claw)
      # No services — just agents
      ;;
  esac

  # Claude Code agent windows (not started — type cc or cc --resume <name> to start)
  tmux new-window -t "$SESSION" -n "cc1" -c "$DIR"
  tmux new-window -t "$SESSION" -n "cc2" -c "$DIR"
  tmux new-window -t "$SESSION" -n "cc3" -c "$DIR"

  # Codex agent window (not started — type cx to start)
  tmux new-window -t "$SESSION" -n "cx1" -c "$DIR"

  # Start on first window
  tmux select-window -t "${SESSION}:1"

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
