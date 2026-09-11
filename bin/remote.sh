#!/bin/bash
# remote.sh — print the copy-paste commands for reaching something on the home Mac
# from the laptop or the phone.
#
# Written 2026-09-10. DD works from the road over Tailscale SSH, and the missing piece was
# not capability — SSH, rcs, rserve, VS Code Remote-SSH and Screen Sharing all worked — it
# was that an agent finishing a job on the home Mac had no single way to hand back "here is
# how to get to the thing I just made". Every handoff was reassembled by hand, differently
# each time, and usually incompletely.
#
# Runs ON the home Mac. Prints commands to run on the LAPTOP.
#
# Usage:
#   remote                 # list everything connectable
#   remote pick            # numbered list, choose by number or partial name
#   remote <session>       # a tmux session (aih, remote-workspace, wt-tsdemo, ...)
#   remote <slug>          # a worktree slot: its session, its app URL, its VS Code workspace
#
# Agents: end any turn that creates a slot or a session by running this and pasting the output.

set -uo pipefail

# This inspects THIS machine's tmux sessions, .port files and `tailscale serve` state, so it
# only makes sense on the home Mac. dotfiles sync to both Macs, so without this guard running
# it on the portable one lists the LAPTOP's sessions and prints a header naming the laptop's
# own tailnet address as "the home Mac" - confidently wrong, and hard to spot.
# The hardware UUID is the only identifier that cannot drift or be copied, which is the same
# reasoning ~/.claude/machine.md uses. Override with REMOTE_SH_ANY_HOST=1.
HOME_MAC_UUID="2971A3E8-CF7D-50DA-943B-7464CD9931D5"
this_uuid=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')
if [[ -z "${REMOTE_SH_ANY_HOST:-}" && -n "$this_uuid" && "$this_uuid" != "$HOME_MAC_UUID" ]]; then
  echo "This is not the home Mac, and 'remote' reads the home Mac's sessions and slots." >&2
  echo "SSH in first, then run it there:" >&2
  echo "    ssh daviddeegan@100.98.222.99" >&2
  echo "    remote ${1:-}" >&2
  echo >&2
  echo "(To inspect THIS machine anyway: REMOTE_SH_ANY_HOST=1 remote ${1:-})" >&2
  exit 1
fi

CODE="$HOME/code/dvddgn"
TS=/opt/homebrew/bin/tailscale
[[ -x "$TS" ]] || TS=$(command -v tailscale) || TS=""

ip() { [[ -n "$TS" ]] && "$TS" ip -4 2>/dev/null | head -1; }
IP=$(ip); IP=${IP:-100.98.222.99}
USER_AT="daviddeegan@$IP"
TATTACH="$CODE/dotfiles/bin/tattach.sh"

exposed() {  # is port $1 published to the tailnet?
  [[ -n "$TS" ]] || return 1
  "$TS" serve status 2>/dev/null | grep -q ":$1\b"
}

slot_dir_for() {  # slug -> worktree dir, or empty
  local s=$1 d
  for d in "$CODE/aih-wt-$s" "$CODE/workspace-app-wt-$s"; do
    [[ -d "$d" ]] && { echo "$d"; return 0; }
  done
  return 1
}

list_all() {
  echo "Connectable things on the home Mac ($IP):"
  echo
  echo "  tmux sessions"
  tmux ls -F '    #{session_name}  (#{session_windows} windows)' 2>/dev/null || echo "    (no tmux server)"
  echo
  echo "  worktree slots"
  local f slug port d
  shopt -s nullglob
  for f in "$CODE"/*.port; do
    slug=$(basename "$f" .port); slug=${slug#aih-wt-}; slug=${slug#workspace-app-wt-}
    port=$(cat "$f" 2>/dev/null)
    d=$(slot_dir_for "$slug") || continue
    if exposed "$port"; then printf '    %-24s port %s  (exposed)\n' "$slug" "$port"
    else printf '    %-24s port %s  (NOT exposed - run: rserve %s)\n' "$slug" "$port" "$slug"; fi
  done
  shopt -u nullglob
  echo
  echo "  remote <name>   for the commands to reach any of them"
}

session_block() {
  local sess=$1
  echo "### tmux session: $sess"
  echo
  tmux list-windows -t "$sess" -F '  #{window_index}: #{window_name}' 2>/dev/null
  echo
  echo "  # an iTerm tab on the laptop, attached over the tailnet (preferred)"
  echo "  rcs --all tab $sess"
  echo
  echo "  # or a plain SSH attach from any terminal, phone included"
  echo "  ssh -t $USER_AT '$TATTACH $sess'"
  echo
  echo "  # detach and leave everything running:  Ctrl-a  then  d"
  echo "  # NEVER type 'exit' inside tmux to disconnect - it kills the pane, and any agent in it."
}

slot_block() {
  local slug=$1 dir=$2 port sess
  port=$(cat "$CODE/$(basename "$dir").port" 2>/dev/null)
  for sess in "wt-$slug" "wsw-$slug"; do tmux has-session -t "$sess" 2>/dev/null && break; sess=""; done
  echo "### worktree slot: $slug"
  echo "  path    $dir"
  echo "  branch  $(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "  port    ${port:-unknown}"
  echo
  if [[ -n "$port" ]]; then
    if exposed "$port"; then
      echo "  # the running app, in the laptop's browser - use the IP, never the .ts.net name"
      echo "  http://$IP:$port"
    else
      echo "  # NOT exposed to the tailnet yet. On the home Mac:"
      echo "  rserve $slug"
      echo "  # then: http://$IP:$port"
    fi
    echo
  fi
  local wsfile
  wsfile=$(ls "$dir"/*.code-workspace 2>/dev/null | head -1)
  if [[ -n "$wsfile" ]]; then
    echo "  # VS Code Remote-SSH: connect to $USER_AT, then"
    echo "  #   File > Open Workspace from File >"
    echo "  $wsfile"
    echo
  fi
  [[ -n "$sess" ]] && { session_block "$sess"; echo; }
  echo "  # when the PR is merged, on the home Mac:"
  echo "  tailscale serve --tcp ${port:-PORT} off   # just this one; 'rserve off' drops them all"
  echo "  wt done $slug                             # or 'wt rm $slug' to park it"
}

# Same picker as `rcs pick`. `remote` had exactly the friction rcs did - it lists ~50 names
# and then you type one. Number or substring; ambiguous substrings list and stop.
cmd_pick() {
  local -a names=() labels=() slot_slugs=()
  local f slug port d line skip s

  # Slots first: they are the richer target, and their block already contains their tmux
  # session, window list and both attach commands.
  shopt -s nullglob
  for f in "$CODE"/*.port; do
    slug=$(basename "$f" .port); slug=${slug#aih-wt-}; slug=${slug#workspace-app-wt-}
    port=$(cat "$f" 2>/dev/null); d=$(slot_dir_for "$slug") || continue
    names+=("$slug"); slot_slugs+=("$slug")
    if exposed "$port"; then labels+=("$slug  (slot, port $port, exposed)")
    else labels+=("$slug  (slot, port $port, NOT exposed - rserve $slug)"); fi
  done
  shopt -u nullglob

  # Then sessions - but NOT a wt-<slug>/wsw-<slug> whose slot is already listed. Listing
  # both made "tsd" ambiguous between `tsdemo` and `wt-tsdemo`, which are the same thing to
  # anyone picking from this list, and the slot entry is strictly more useful.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    skip=0
    for s in "${slot_slugs[@]}"; do
      [[ "$line" == "wt-$s" || "$line" == "wsw-$s" ]] && { skip=1; break; }
    done
    [[ $skip -eq 1 ]] && continue
    names+=("$line"); labels+=("$line  (tmux session)")
  done < <(tmux ls -F '#{session_name}' 2>/dev/null | sort)
  [[ ${#names[@]} -gt 0 ]] || { echo "nothing connectable."; exit 1; }

  local i=1
  for line in "${labels[@]}"; do printf '  %2d  %s\n' "$i" "$line"; i=$((i + 1)); done
  echo
  printf 'Which? (number, or part of a name): '
  local ans; read -r ans
  [[ -n "$ans" ]] || { echo "nothing chosen."; exit 0; }

  local chosen=""
  if [[ "$ans" =~ ^[0-9]+$ ]]; then
    [[ "$ans" -ge 1 && "$ans" -le ${#names[@]} ]] || { echo "no such number '$ans' (1-${#names[@]})." >&2; exit 1; }
    chosen=${names[$((ans - 1))]}
  else
    local -a hits=()
    for line in "${names[@]}"; do [[ "$line" == *"$ans"* ]] && hits+=("$line"); done
    case ${#hits[@]} in
      0) echo "nothing matches '$ans'." >&2; exit 1 ;;
      1) chosen=${hits[0]} ;;
      *) echo "'$ans' matches ${#hits[@]}:"; printf '    %s\n' "${hits[@]}"
         echo "be more specific." >&2; exit 1 ;;
    esac
  fi
  echo
  main "$chosen"
}

main() {
  local what="${1:-}"
  if [[ -z "$what" ]]; then list_all; exit 0; fi
  if [[ "$what" == "pick" || "$what" == "-i" ]]; then cmd_pick; exit 0; fi
  # Resolve BEFORE printing the header, so a bad name gives an error and nothing else.
  local dir=""
  if ! dir=$(slot_dir_for "$what") && ! tmux has-session -t "$what" 2>/dev/null; then
    echo "No slot or tmux session called '$what'." >&2; echo >&2; list_all >&2; exit 1
  fi
  echo "# Run these on the LAPTOP. Home Mac is $IP."
  echo "# Needs Tailscale signed in there; nothing to set up on this end."
  echo
  if [[ -n "$dir" ]]; then slot_block "$what" "$dir"; else session_block "$what"; fi
  echo
  echo "  # GUI fallback - the home Mac's own screen, incl. its Finder:  vnc://$IP"
}
main "$@"
