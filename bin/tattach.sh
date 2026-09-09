#!/bin/bash
# tattach.sh — attach to a tmux session from anywhere, choosing the sizing flags correctly.
#
# `-f ignore-size` stops a differently-sized client reflowing the desktop's own tabs on the
# same session. But it takes the client OUT of tmux's sizing calculation entirely, so when
# nothing else is attached there is no client left to size the window from: it keeps whatever
# stale size it had. A session created by ensure_core_sessions and never opened on the desktop
# sits at tmux's default 80x24, and a full-screen laptop then gets an 80x24 window in a 182x57
# terminal, with dead space around it. `resize-window -A` does not rescue it either — "largest
# attached client" also ignores an ignore-size client, so it sees none.
#
# So the flag is only correct when there is someone to protect. This picks per attach:
#
#   other clients attached  ->  -f ignore-size,active-pane   (protect them; we take the
#                               window as it is, which is the trade already agreed)
#   nobody else attached    ->  plain attach                 (nothing to disturb, so let the
#                               window fit this client properly)
#
# Usage:  tattach.sh <session>
#         tattach.sh --force-ignore-size <session>   # always protect, even if alone
#
# Called by `pt` (interactive) and by rcs's per-tab ssh command (non-interactive), so it must
# not depend on anything ~/.zshrc sets — hence a script rather than a shell function.

set -uo pipefail

FORCE=0
[[ "${1:-}" == "--force-ignore-size" ]] && { FORCE=1; shift; }
sess="${1:-}"

if [[ -z "$sess" ]]; then
  tmux list-sessions -F '#{session_name}' 2>/dev/null || { echo "no tmux server running" >&2; exit 1; }
  exit 0
fi

tmux has-session -t "$sess" 2>/dev/null || { echo "no such tmux session: $sess" >&2; exit 1; }

others=$(tmux list-clients -t "$sess" 2>/dev/null | wc -l | tr -d ' ')

if [[ $FORCE -eq 1 || ${others:-0} -gt 0 ]]; then
  exec tmux attach-session -t "$sess" -f ignore-size,active-pane
else
  exec tmux attach-session -t "$sess"
fi
