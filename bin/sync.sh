#!/bin/bash
# sync.sh — pull (and optionally push) the config repos that follow DD between machines.
#
# Written 2026-09-11. Two machines now push to the same three repos, so "did I pull?" became
# a real question with a silent wrong answer: on 2026-09-11 a `git pull` on the laptop printed
# `Aborting` because of one uncommitted line, DD read the "Updating" text ABOVE it, and ran two
# more commands against the old code before noticing. A pull that does nothing must be loud.
#
# Usage:
#   sync            # pull all three, report per-repo, exit non-zero if any needs attention
#   sync --push     # also push anything committed-but-unpushed
#
# Runs on either Mac. Same paths on both.

set -uo pipefail
REPOS=("$HOME/.claude" "$HOME/code/dvddgn/agent-skills" "$HOME/code/dvddgn/dotfiles")
PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

fail=0
printf '%-18s %s\n' "REPO" "RESULT"
for r in "${REPOS[@]}"; do
  name=$(basename "$r")
  [[ "$name" == ".claude" ]] && name="~/.claude"
  if ! git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
    printf '  %-16s %s\n' "$name" "not a git repo - skipped"; continue
  fi

  branch=$(git -C "$r" branch --show-current)
  dirty=$(git -C "$r" status --porcelain | wc -l | tr -d ' ')

  # Refuse rather than --autostash: an autostash hides exactly the thing worth seeing, and a
  # stash on a machine about to be carried through an airport is a great way to lose an edit.
  if [[ "$dirty" -gt 0 ]]; then
    printf '  %-16s *** %s uncommitted file(s) - pull would abort ***\n' "$name" "$dirty"
    git -C "$r" status --porcelain | sed 's/^/                     /'
    printf '                   -> git -C %s diff, then commit\n' "$r"
    fail=1; continue
  fi

  out=$(git -C "$r" pull --rebase 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '  %-16s *** PULL FAILED ***\n' "$name"
    printf '%s\n' "$out" | sed 's/^/                     /' | head -4
    fail=1; continue
  fi
  # `git pull` says "Already up to date."; `git pull --rebase` says "Current branch X is up
  # to date." Matching only the first printed a BLANK result for the commonest case, which
  # is the one shape a status line must never take.
  if printf '%s' "$out" | grep -qE "Already up to date|is up to date"; then
    printf '  %-16s up to date\n' "$name"
  else
    summary=$(printf '%s' "$out" | grep -E 'Updating|Successfully rebased|Fast-forward|files? changed' | head -1 | sed 's/^ *//')
    printf '  %-16s %s\n' "$name" "${summary:-pulled}"
  fi

  # Committed but never pushed. --not --remotes, not the ahead-count: a branch with no
  # upstream reports 0 ahead while having commits no remote has ever seen.
  un=$(git -C "$r" log HEAD --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$un" -gt 0 ]]; then
    if [[ $PUSH -eq 1 ]]; then
      git -C "$r" push -q origin "HEAD:refs/heads/$branch" 2>/dev/null
      L=$(git -C "$r" rev-parse HEAD); R=$(git -C "$r" ls-remote origin "$branch" 2>/dev/null | cut -f1)
      if [[ "$L" == "$R" ]]; then printf '  %-16s pushed %s commit(s)\n' "" "$un"
      else printf '  %-16s *** PUSH DID NOT LAND - remote still %s ***\n' "" "${R:0:7}"; fail=1; fi
    else
      printf '  %-16s %s commit(s) not pushed - run: sync --push\n' "" "$un"; fail=1
    fi
  fi
done

echo
if [[ $fail -eq 0 ]]; then echo "All repos clean, pulled and pushed."; else echo "Something above needs you."; fi
exit $fail
