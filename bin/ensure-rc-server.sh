#!/bin/bash
# ensure-rc-server.sh - keep a Claude Code Remote Control server running on the home Mac, so new
# sessions can be started from the Claude phone/desktop app (Code tab -> Devices) and run HERE,
# with this machine's files, tools, skills and ~/.claude, rather than in the cloud.
#
# Run by the com.dvddgn.rc-server LaunchAgent at login and every 5 minutes (launchd/,
# installed with bin/install-rc-server.sh). Same shape as workspace-app's ensure-loops: check,
# and start only what is missing. Safe to run by hand at any time.
#
# Why a check-and-start loop and not just tmux: tmux does not survive a reboot, and
# `claude remote-control` EXITS by itself after ~10 minutes without network
# (https://code.claude.com/docs/en/remote-control#limitations). Either way the Mac silently
# drops off the app's Devices list until something starts it again.
#
# Why inside tmux and not straight under launchd: the server's screen (status, QR code on
# space, `w` to toggle spawn mode) stays reachable with `pt rc-server`.
#
# Auth: the server needs the full claude.ai login from the keychain. A LaunchAgent runs inside
# DD's login session, so it can read it. CLAUDE_CODE_OAUTH_TOKEN (the setup-token the loops use)
# is inference-only and Remote Control refuses it, so it is explicitly unset.

set -uo pipefail

SESSION="${RC_SERVER_SESSION:-rc-server}"
DIR="${RC_SERVER_DIR:-$HOME/code/dvddgn/workspace-app}"
NAME="${RC_SERVER_NAME:-home-mac}"
SPAWN="${RC_SERVER_SPAWN:-same-dir}"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }

if [ -f /tmp/rc-server.paused ]; then
  echo "$(stamp) paused (/tmp/rc-server.paused exists) - not checking"
  exit 0
fi

# Healthy = the session exists AND a `claude ... rc` / `remote-control` process lives under its
# pane. The session alone is not proof: a pane left at a shell prompt would pass that check.
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  pane_pid=$(tmux list-panes -t "=$SESSION" -F '#{pane_pid}' 2>/dev/null | head -1)
  # Walk the pane's process tree (pane shell -> zsh -> claude, or claude itself).
  tree="$pane_pid"; frontier="$pane_pid"
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do next="$next $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"; done
    frontier=$(echo $next); tree="$tree $frontier"
  done
  for p in $tree; do
    if ps -o command= -p "$p" 2>/dev/null | grep -qE '(^|/)claude( .*)? (rc|remote-control)( |$)'; then
      # Stale-version check. Claude auto-updates and deletes old versions, but a long-running
      # server keeps spawning sessions from the version it started on. Once that version is
      # deleted every new session fails with "spawn error: ENOENT .../versions/<old>" and the
      # app just shows a session that never responds (seen 2026-11-10: server on 2.1.312,
      # installed 2.1.322).
      running_bin=$(lsof -a -p "$p" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | grep '/claude/versions/' | head -1)
      current_bin=$(readlink "$HOME/.local/bin/claude" 2>/dev/null || true)
      if [ -z "$running_bin" ] || [ -z "$current_bin" ] || [ "$running_bin" = "$current_bin" ]; then
        exit 0
      fi
      # Sessions started from the app run as children of the server; killing it would kill them.
      active=$(pgrep -P "$p" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$active" -gt 0 ]; then
        if [ ! -e "$running_bin" ]; then
          echo "$(stamp) WARNING: server runs deleted $running_bin - new sessions will fail; $active session(s) active, not restarting. Restart by hand: tmux kill-session -t rc-server"
        fi
        exit 0
      fi
      # Idle and out of date: restart now, before the old version is deleted.
      echo "$(stamp) server on $(basename "$running_bin"), installed $(basename "$current_bin"), no active sessions - restarting"
      break
    fi
  done
  [ -n "${running_bin:-}" ] || echo "$(stamp) session $SESSION exists but no claude rc process under pane $pane_pid - restarting"
  tmux kill-session -t "=$SESSION" 2>/dev/null || true
fi

if [ ! -d "$DIR" ]; then
  echo "$(stamp) $DIR missing - cannot start" >&2
  exit 1
fi

# Login + interactive zsh so the server, and every session it spawns, get DD's normal PATH
# (rbenv shims, nvm node, ~/bin) - the same environment as a session started by hand.
tmux new-session -d -s "$SESSION" -c "$DIR" \
  "unset CLAUDE_CODE_OAUTH_TOKEN; exec zsh -ilc 'cd \"$DIR\" && exec claude rc --name \"$NAME\" --spawn $SPAWN'"
echo "$(stamp) started $SESSION in $DIR (name=$NAME spawn=$SPAWN)"
