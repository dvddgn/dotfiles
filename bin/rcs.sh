#!/bin/bash
# rcs.sh — "remote cs": rebuild DD's iTerm2 tab layout on ANY Mac, with every tab
# attached over Tailscale SSH to a tmux session on the HOME Mac.
#
# `cs iterm` does this for tmux sessions on the machine you are sitting at. This does
# the same thing for the home Mac's sessions, so the portable Mac gets the familiar
# Work/Personal window pair with one named tab per session — the same layout, the same
# names, just reached over the tailnet.
#
# Usage:
#   rcs                      # list the home Mac's sessions (no tabs opened)
#   rcs iterm                # two windows, one tab per session, named
#   rcs tab <session>        # a single tab for one session
#   rcs ssh                  # a plain shell on the home Mac, no tmux
#   rcs --dry-run iterm      # print what it would do and open nothing
#   rcs --host <addr> ...    # target a different machine
#
# Requires: Tailscale running and signed in on THIS machine, and the home Mac up.
# It needs no setup on the home Mac at all — that side is already done.
#
# See the `tmux` skill, "Reaching this Mac remotely: phone, or the other Mac".

set -uo pipefail

# The tailnet IP, not the MagicDNS name: the name is editable in the admin console
# and has already changed once (davids-macbook-pro-2 -> -16 on 2026-09-09), while
# the address has not moved. Override with --host or $RCS_HOST.
HOST="${RCS_HOST:-100.98.222.99}"
USER_AT="${RCS_USER:-daviddeegan}"
DRY_RUN=0

die() { echo "Error: $*" >&2; exit 1; }

# Every remote attach MUST carry these flags. `-f ignore-size` keeps this client out of
# the window-size calculation, so a 116-col laptop does not reflow the home Mac's own
# 115x110 iTerm2 tabs on the same session; `-f active-pane` gives it its own active pane
# so moving around here does not drag the home cursor.
#
# NOT `pt <session>`, even though that is the same thing and is what you type by hand.
# `ssh host 'cmd'` runs cmd as `$SHELL -c`, which is non-interactive, and zsh does not
# source ~/.zshrc for those — so the pt function does not exist and the command fails.
ATTACH_FLAGS='-f ignore-size,active-pane'

ssh_cmd() { ssh -o ConnectTimeout=8 "$USER_AT@$HOST" "$@"; }

# `-t` forces a pty, which tmux needs. Without it: "open terminal failed: not a terminal".
remote_attach_cmdline() {
  printf 'ssh -t %s@%s "tmux attach -t %s %s"' "$USER_AT" "$HOST" "$1" "$ATTACH_FLAGS"
}

preflight() {
  command -v tailscale >/dev/null 2>&1 \
    || die "tailscale not installed on this machine. Install it and sign in to the same tailnet."
  tailscale status >/dev/null 2>&1 \
    || die "tailscale is installed but not running or not signed in. Run: tailscale up"
  ssh_cmd true >/dev/null 2>&1 \
    || die "cannot reach $USER_AT@$HOST over SSH. Check 'tailscale status' lists the home Mac, and that it is awake."
}

remote_sessions() {
  # Same exclusions as cs.sh's own layout, and for the same reasons: sess-HHMMSS strays
  # from a VS Code restart are not real work slots, and c1-c5/m1-m5 are on-demand rather
  # than standing tabs. Sorted, so shared prefixes (ops-*, prj-*, wt-*) cluster for free.
  ssh_cmd "tmux list-sessions -F '#{session_name}' 2>/dev/null" \
    | grep -Ev '^m1-[0-9]{6}$' \
    | grep -Ev '^(c[1-5]|m[1-5])$' \
    | sort
}

osa() { [[ $DRY_RUN -eq 1 ]] && { echo "  [dry-run] osascript: ${1//$'\n'/ }" | cut -c1-150; return 0; }
        osascript -e "$1" >/dev/null 2>&1; }

open_tab() {  # win_id, session
  osa "
  tell application \"iTerm2\"
    tell window id $1
      set newTab to (create tab with default profile)
      tell current session of newTab
        write text \"$(remote_attach_cmdline "$2")\"
      end tell
    end tell
  end tell"
}

cmd_list() {
  preflight
  echo "tmux sessions on the home Mac ($HOST):"
  remote_sessions | sed 's/^/  /'
}

cmd_ssh() { preflight; exec ssh -t "$USER_AT@$HOST"; }

cmd_tab() {
  local sess="$1"
  [[ -n "$sess" ]] || die "usage: rcs tab <session>"
  preflight
  remote_sessions | grep -qx "$sess" || die "no tmux session '$sess' on the home Mac. Run 'rcs' to list them."
  osa 'tell application "iTerm2" to activate'
  local win_id
  if [[ $DRY_RUN -eq 1 ]]; then win_id="<current>"; else
    win_id=$(osascript -e 'tell application "iTerm2" to id of current window' 2>/dev/null) \
      || win_id=$(osascript -e 'tell application "iTerm2" to id of (create window with default profile)')
  fi
  open_tab "$win_id" "$sess"
  sleep 4   # a name set too early is clobbered when the shell reports its own title
  osa "tell application \"iTerm2\" to tell window id $win_id to tell current session to set name to \"$sess\""
  echo "opened a tab for '$sess' on the home Mac."
}

cmd_iterm() {
  preflight
  local -a sessions=() win_ids=() tab_ids=()
  local work_win personal_win sess win_id
  local -i work_n=1 personal_n=1

  # NOT `mapfile`: macOS ships bash 3.2.57, which does not have it (it arrived in bash 4).
  # Process substitution rather than a pipe, so the array survives — a pipeline would
  # populate it inside a subshell and leave it empty here. Same shape cs.sh uses.
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && sessions+=("$line")
  done < <(remote_sessions)
  [[ ${#sessions[@]} -gt 0 ]] || die "the home Mac reports no tmux sessions."

  osa 'tell application "iTerm2" to activate'
  if [[ $DRY_RUN -eq 1 ]]; then work_win="<work>"; personal_win="<personal>"; else
    work_win=$(osascript -e 'tell application "iTerm2" to id of (create window with default profile)')
    personal_win=$(osascript -e 'tell application "iTerm2" to id of (create window with default profile)')
  fi

  # DD's own Work/Personal split, mirrored from cs.sh so the remote layout matches the
  # one muscle memory already knows: claw and every ops-*/prj-* is Personal.
  local -a s2=() w2=() t2=()
  for sess in "${sessions[@]}"; do
    if [[ "$sess" == "claw" || "$sess" == ops-* || "$sess" == prj-* ]]; then
      win_id=$personal_win; personal_n=$((personal_n + 1)); t2+=("$personal_n")
    else
      win_id=$work_win; work_n=$((work_n + 1)); t2+=("$work_n")
    fi
    s2+=("$sess"); w2+=("$win_id")
    open_tab "$win_id" "$sess"
    sleep 0.4
  done

  sleep 4
  local i
  for i in "${!s2[@]}"; do
    osa "tell application \"iTerm2\" to tell window id ${w2[$i]} to tell current session of tab ${t2[$i]} to set name to \"${s2[$i]}\""
  done

  osa "tell application \"iTerm2\" to tell window id $work_win to if (count of tabs) > 1 then close tab 1"
  osa "tell application \"iTerm2\" to tell window id $personal_win to if (count of tabs) > 1 then close tab 1"

  echo "${#s2[@]} tabs opened across 2 iTerm2 windows (Work / Personal), each attached to the home Mac over Tailscale."
  echo "Detach a tab with Ctrl-a d (leaves the session running), then 'exit' to close the SSH."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --host)    HOST="${2:?--host needs an address}"; shift 2 ;;
    --user)    USER_AT="${2:?--user needs a name}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done

case "${1:-list}" in
  list|"")  cmd_list ;;
  iterm)    cmd_iterm ;;
  tab)      shift; cmd_tab "${1:-}" ;;
  ssh)      cmd_ssh ;;
  *)        die "unknown command '$1'. Try: rcs, rcs iterm, rcs tab <session>, rcs ssh" ;;
esac
