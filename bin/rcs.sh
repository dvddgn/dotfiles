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
#   rcs <session>            # same thing - a bare session name is accepted
#   rcs ssh                  # a plain shell on the home Mac, no tmux
#   rcs --dry-run iterm      # print what it would do and open nothing
#   rcs --all iterm          # include the wsw-*/wt-* worktree slots too
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
INCLUDE_ALL=0

die() { echo "Error: $*" >&2; exit 1; }

# Every remote attach goes through tattach.sh, which chooses these flags per attach. `-f ignore-size` keeps this client out of
# the window-size calculation, so a 116-col laptop does not reflow the home Mac's own
# 115x110 iTerm2 tabs on the same session; `-f active-pane` gives it its own active pane
# so moving around here does not drag the home cursor.
#
# NOT `pt <session>`, even though that is the same thing and is what you type by hand.
# `ssh host 'cmd'` runs cmd as `$SHELL -c`, which is non-interactive, and zsh does not
# source ~/.zshrc for those — so the pt function does not exist and the command fails.
# Absolute path, because this runs as a non-interactive remote command where nothing from
# ~/.zshrc exists — the same reason `pt` cannot be used here. tattach.sh decides the sizing
# flags per attach rather than applying them unconditionally: with nobody else attached,
# ignore-size leaves tmux no client to size the window from, so a full-screen laptop gets a
# stale 80x24 window with dead space around it. See that script's header.
REMOTE_ATTACH="\$HOME/code/dvddgn/dotfiles/bin/tattach.sh"

ssh_cmd() { ssh -o ConnectTimeout=8 "$USER_AT@$HOST" "$@"; }

# `-t` forces a pty, which tmux needs. Without it: "open terminal failed: not a terminal".
# SINGLE quotes around the remote command, not double. This string is embedded inside an
# AppleScript string literal (`write text "..."`), and an unescaped inner double quote ends
# that literal early — AppleScript then hits the bare word `tmux` and fails with
# "Expected end of line but found identifier. (-2741)". Single quotes need no escaping in
# either AppleScript or the zsh that ultimately runs the line.
remote_attach_cmdline() {
  printf "ssh -t %s@%s '%s %s'" "$USER_AT" "$HOST" "$REMOTE_ATTACH" "$1"
}

# The GUI builds (Standalone cask and Mac App Store) do NOT put `tailscale` on the PATH —
# they bundle the CLI inside the .app. Only the open-source `brew install tailscale`
# formula links it into /opt/homebrew/bin. Since a client machine is exactly where the
# GUI build is the sensible choice, checking `command -v tailscale` alone reports "not
# installed" on a machine where Tailscale is plainly running. Resolve it properly, and
# print nothing if it cannot be found — the CLI is only used for nicer diagnostics here,
# not to make the connection.
find_ts_cli() {
  local c
  for c in tailscale \
           /Applications/Tailscale.app/Contents/MacOS/Tailscale \
           /Applications/Tailscale.app/Contents/MacOS/tailscale \
           /opt/homebrew/bin/tailscale \
           /usr/local/bin/tailscale; do
    if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

preflight() {
  local TS
  TS=$(find_ts_cli) || TS=""

  if [[ -n "$TS" ]]; then
    "$TS" status >/dev/null 2>&1 \
      || die "Tailscale is installed but not running or not signed in.
  GUI app: open Tailscale from the menu bar and connect.  CLI: run 'tailscale up'."
  fi
  # Am I already ON the target? An SSH to your own tailnet address is refused (nothing
  # binds :22 locally; Tailscale SSH answers peer traffic inside tailscaled's netstack),
  # so without this check the failure surfaces as "cannot reach the home Mac, is it
  # awake?" — while you are sitting on the home Mac. That message sends you to look at
  # the wrong machine. Most common way in: running rcs inside an SSH session opened
  # FROM the portable Mac, where the shell is the home Mac's.
  local self_ips=""
  [[ -n "$TS" ]] && self_ips=$("$TS" status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["Self"]["TailscaleIPs"]))' 2>/dev/null)
  if [[ -n "$self_ips" && " $self_ips " == *" $HOST "* ]]; then
    die "$HOST is THIS machine — rcs targets the home Mac from a different one.
  If you are in an SSH session on the home Mac, run 'exit' first, then rcs on the local machine.
  To open local tabs instead, use 'cs iterm'."
  fi

  ssh_cmd true >/dev/null 2>&1 \
    || die "cannot reach $USER_AT@$HOST over SSH.
  Check: Tailscale is connected on this machine and lists the home Mac; the home Mac is
  awake (it does not sleep on AC, but does on battery); and you are not already ON it.${TS:+}"
}

remote_sessions() {
  # Same exclusions as cs.sh's own layout, and for the same reasons: sess-HHMMSS strays
  # from a VS Code restart are not real work slots, and c1-c5/m1-m5 are on-demand rather
  # than standing tabs. Sorted, so shared prefixes (ops-*, prj-*, wt-*) cluster for free.
  #
  # Worktree slots (wsw-* and wt-*) are dropped too, which cs.sh does NOT do — the home
  # Mac has the screen space for them and this laptop does not. On 2026-09-09 the home Mac
  # had 28 sessions and 13 desktop tabs; the 10 wsw-* slots were the bulk of the gap. They
  # are agent working slots you dip into, not standing tabs, which is the same argument
  # cs.sh already makes for c1-c5/m1-m5. `--all` keeps them in the layout; naming one
  # (`rcs wt-pr-915`) always works regardless, via remote_sessions_all below.
  local out
  out=$(remote_sessions_all \
        | grep -Ev '^m1-[0-9]{6}$' \
        | grep -Ev '^(c[1-5]|m[1-5])$')
  # An explicit branch rather than a command held in a variable: `$filter` unquoted
  # relies on word-splitting to reassemble a command line, which is fragile and hides
  # the pattern from the reader.
  if [[ $INCLUDE_ALL -eq 0 ]]; then
    out=$(printf '%s\n' "$out" | grep -Ev '^(wsw|wt)-')
  fi
  printf '%s\n' "$out" | grep -v '^$' | sort
}

# Every session the home Mac actually has, unfiltered.
#
# The exclusions above shape the bulk `iterm` LAYOUT - they are about screen space on a
# laptop, and have no business gating a session the user named out loud. Naming one is
# the statement that you want it. Before 2026-09-11 `cmd_tab` validated against the
# filtered list, so `rcs tab wt-pr-915` died with "no tmux session 'wt-pr-915'" unless
# you also passed --all - while the comment above claimed "`rcs tab <name>` opens one".
# DD hit exactly that and worked around it with `rcs --all tab wt-pr-915`.
remote_sessions_all() {
  ssh_cmd "tmux list-sessions -F '#{session_name}' 2>/dev/null" | grep -v '^$' | sort
}

# Never discard osascript's stderr. The first version of this did (`>/dev/null 2>&1`) and
# so could not tell a created tab from a refused one — it printed "18 tabs opened" while
# opening none. AppleScript failures here are ordinary, not exotic: iTerm2 not installed,
# or macOS Automation permission not yet granted to the calling terminal, which fails with
# error -1743 and no dialog if the user has previously denied it.
osa() {
  if [[ $DRY_RUN -eq 1 ]]; then
    # Raw AppleScript, truncated, one line per tab: 30 lines that never name a single
    # session, which is the only thing a dry run is for. cmd_iterm/cmd_tab print a real
    # plan instead. RCS_DRY_RUN_VERBOSE=1 brings the script back for debugging osascript.
    [[ -n "${RCS_DRY_RUN_VERBOSE:-}" ]] && echo "  [dry-run] osascript: ${1//$'\n'/ }" | cut -c1-150
    return 0
  fi
  osa_get "$1" >/dev/null
}

# Same, but hands back what AppleScript returned. Split from osa() so that the many
# fire-and-forget calls (create tab, set name, close tab) stay silent — `create tab`
# returns a tab object whose description would otherwise be printed 18 times.
osa_get() {
  local out
  if ! out=$(osascript -e "$1" 2>&1); then
    if [[ "$out" == *"-1743"* || "$out" == *"Not authorized"* ]]; then
      die "macOS blocked this from controlling iTerm2.
  Grant it in System Settings -> Privacy & Security -> Automation: find your terminal
  app in the list and enable iTerm. Then run rcs iterm again."
    fi
    die "AppleScript failed: $out"
  fi
  printf '%s' "$out"
}

require_iterm() {
  [[ $DRY_RUN -eq 1 ]] && return 0
  [[ -d /Applications/iTerm.app || -d "$HOME/Applications/iTerm.app" ]] \
    || die "iTerm2 is not installed on this machine — rcs iterm builds an iTerm2 tab layout.
  Install iTerm2, or use 'rcs ssh' for a plain shell and 'rcs' to list sessions."
}

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
  require_iterm
  preflight
  remote_sessions_all | grep -qx "$sess" \
    || die "no tmux session '$sess' on the home Mac. Run 'rcs' to list them ('rcs --all' includes worktree slots)."
  osa 'tell application "iTerm2" to activate'
  local win_id
  if [[ $DRY_RUN -eq 1 ]]; then win_id="<current>"; else
    # A no-window iTerm2 makes "id of current window" fail; that one is expected, so it
    # stays a plain osascript with a fallback rather than going through osa_get's die.
    win_id=$(osascript -e 'tell application "iTerm2" to id of current window' 2>/dev/null)
    [[ "$win_id" =~ ^[0-9]+$ ]] \
      || win_id=$(osa_get 'tell application "iTerm2" to id of (create window with default profile)')
    [[ "$win_id" =~ ^[0-9]+$ ]] || die "iTerm2 did not return a usable window id ('$win_id')." 
  fi
  open_tab "$win_id" "$sess"
  sleep 4   # a name set too early is clobbered when the shell reports its own title
  osa "tell application \"iTerm2\" to tell window id $win_id to tell current session to set name to \"$sess\""
  echo "opened a tab here, attached to '$sess' on the home Mac."
}

# Personal window vs Work window. Mirrors cs.sh's split (DD's own, 2026-08-30): claw plus
# every ops-*/prj-* session, all of which live inside ~/.openclaw/workspace.
is_personal() { [[ "$1" == "claw" || "$1" == ops-* || "$1" == prj-* ]]; }

cmd_iterm() {
  require_iterm
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
  if [[ $DRY_RUN -eq 1 ]]; then
    local -a plan_work=() plan_personal=()
    for sess in "${sessions[@]}"; do
      if is_personal "$sess"; then plan_personal+=("$sess"); else plan_work+=("$sess"); fi
    done
    echo "Would open 2 iTerm2 windows here, ${#sessions[@]} tabs, each SSH'd to a tmux session on $HOST:"
    echo
    echo "  Work (${#plan_work[@]} tabs)"
    printf '    %s\n' "${plan_work[@]}"
    echo
    echo "  Personal (${#plan_personal[@]} tabs)"
    printf '    %s\n' "${plan_personal[@]}"
    echo
    echo "  Nothing was opened. Drop --dry-run to do it, or 'rcs <session>' for just one."
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then work_win="<work>"; personal_win="<personal>"; else
    work_win=$(osa_get 'tell application "iTerm2" to id of (create window with default profile)')
    personal_win=$(osa_get 'tell application "iTerm2" to id of (create window with default profile)')
    # An empty or non-numeric id silently poisons every `tell window id ...` that follows,
    # which is how 18 tabs can be "opened" into nothing.
    [[ "$work_win" =~ ^[0-9]+$ && "$personal_win" =~ ^[0-9]+$ ]] \
      || die "iTerm2 did not return usable window ids (work='$work_win' personal='$personal_win'). Is iTerm2 running?"
  fi

  # DD's own Work/Personal split, mirrored from cs.sh so the remote layout matches the
  # one muscle memory already knows: claw and every ops-*/prj-* is Personal.
  local -a s2=() w2=() t2=()
  for sess in "${sessions[@]}"; do
    if is_personal "$sess"; then
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

  # Report what EXISTS, not what was attempted. Counting the tabs is the only statement
  # here that the user can act on; "I issued 18 commands" is not.
  local work_tabs personal_tabs total
  work_tabs=$(osa_get "tell application \"iTerm2\" to count tabs of window id $work_win")
  personal_tabs=$(osa_get "tell application \"iTerm2\" to count tabs of window id $personal_win")
  total=$((work_tabs + personal_tabs))
  if [[ $total -ne ${#s2[@]} ]]; then
    echo "WARNING: asked for ${#s2[@]} tabs but iTerm2 reports $total (Work $work_tabs, Personal $personal_tabs)." >&2
  fi
  echo "$total tabs open across 2 iTerm2 windows (Work $work_tabs / Personal $personal_tabs), each attached to the home Mac over Tailscale."
  echo "Detach a tab with Ctrl-a d (leaves the session running), then 'exit' to close the SSH."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --all)     INCLUDE_ALL=1; shift ;;
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
  # A bare session name means `tab <session>`. DD reached for `rcs aih` twice before
  # reading the error, which is the signal that the sub-command was the unnatural part -
  # every other name in this setup (pt aih, remote aih) takes the session directly.
  # Only accept it when the home Mac really has that session, so a typo still gets the
  # usage message rather than a confusing failure deeper in.
  *)        if remote_sessions_all | grep -qx "$1"; then cmd_tab "$1"
            else die "unknown command or session '$1'.
  Try: rcs, rcs <session>, rcs iterm, rcs tab <session>, rcs ssh
  Run 'rcs' to list the sessions on the home Mac."
            fi ;;
esac
