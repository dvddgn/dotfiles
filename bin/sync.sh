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
#   sync --auto     # unattended: commit, pull, push. Run hourly by com.dvddgn.auto-sync
#
# Runs on either Mac. Same paths on both.

set -uo pipefail
REPOS=("$HOME/.claude" "$HOME/code/dvddgn/agent-skills" "$HOME/code/dvddgn/dotfiles")
PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

# ---- --auto ---------------------------------------------------------------------------------
# Added 2026-10-29. Before this, the home Mac's cron job (~/.openclaw/workspace/scripts/
# git-auto-sync.sh) committed and pushed ~/.claude and agent-skills but never pulled, and the
# laptop ran nothing. The laptop's agent-skills was found 288 commits behind, every pull blocked
# by uncommitted files in synced/ that something rewrites on each machine. --auto replaces that
# job on both Macs.
#
#   ~/.claude, agent-skills : commit everything, pull --rebase, push. Every change there is meant
#                             to be kept (memory, settings, generated synced/ skills).
#   dotfiles                : pull only. It is hand-written code, so it is never auto-committed;
#                             an uncommitted edit there is a pull skipped, not a commit made.
#
# A conflict is never resolved here: the rebase is aborted, the repo is left exactly as it was,
# and the failure is recorded. Two machines editing the same file needs a person (on 2026-10-29
# both Macs had appended a line to the same MEMORY.md).
#
# A failure is written to ~/.claude/status/auto-sync-failure.txt (gitignored, so it stays on the
# Mac it describes), which the statusline shows in every session, plus a macOS notification. The
# marker is removed on the next clean run. A job that fails quietly is not a sync job: the old
# cron job logged 124 PUSH FAILED entries to /tmp before anyone looked.
#
# A run must also never hang. On 2026-10-29 the laptop woke for 9 seconds at 18:22, launchd ran
# the missed 18:15 job, and the Mac slept again during the dotfiles fetch. The ssh connection to
# GitHub died without a FIN, so ssh waited on it for 27 minutes until it was killed by hand. A
# hung run is worse than a failed one: launchd starts no new run while it lives, so every later
# :15 is skipped, and no marker is written, so the statusline stays silent. Two guards:
#   - ssh keepalives, so a dead connection fails in about 45s instead of never;
#   - a watchdog that, after AUTO_SYNC_LIMIT seconds (default 600), writes the marker and kills
#     the run. A rebase it interrupts is reported by the next run's "already in progress" check.
auto_sync() {
  local marker="$HOME/.claude/status/auto-sync-failure.txt"
  local failures=() r name out rc un L R branch
  stamp() { date '+%Y-%m-%d %H:%M:%S'; }
  echo "[$(stamp)] auto-sync on $(hostname -s)"

  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=30}"
  local limit="${AUTO_SYNC_LIMIT:-600}" self=$$
  (
    exec 2>/dev/null   # else stop_watchdog logs "Terminated: sleep" on every clean run
    sleep "$limit"
    mkdir -p "$(dirname "$marker")"
    echo "auto-sync failed on $(hostname -s) at $(stamp) - still running after ${limit}s, killed - log: ~/Library/Logs/auto-sync.log" > "$marker"
    echo "  FAILED: still running after ${limit}s, killed"
    osascript -e "display notification \"run hung for ${limit}s and was killed\" with title \"auto-sync failed\"" >/dev/null 2>&1
    # The whole process group: the stuck process is a grandchild (bash -> git -> ssh).
    kill -TERM -- "-$(ps -o pgid= -p "$self" | tr -d ' ')"
  ) &
  local watchdog=$!; disown "$watchdog"
  stop_watchdog() { pkill -P "$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null; }

  # Pushes and SSH pulls need the ssh-agent that oh-my-zsh's ssh-agent plugin starts from the
  # first interactive shell; launchd does not inherit it. Same fix as git-auto-sync.sh, which
  # documents why (the key's passphrase is not in the keychain, only in a running agent).
  local ssh_env="$HOME/.ssh/environment-$(hostname -s)"
  if [[ -z "${SSH_AUTH_SOCK:-}" && -r "$ssh_env" ]]; then . "$ssh_env" >/dev/null 2>&1; fi
  if [[ -z "${SSH_AUTH_SOCK:-}" || ! -S "${SSH_AUTH_SOCK:-}" ]]; then
    failures+=("no live ssh-agent (reboot with no login?) - open a terminal so one starts")
  fi

  for r in "${REPOS[@]}"; do
    name=$(basename "$r"); [[ "$name" == ".claude" ]] && name="~/.claude"
    if ! git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
      failures+=("$name: not a git repo"); continue
    fi
    local gd; gd=$(git -C "$r" rev-parse --git-dir)
    [[ "$gd" = /* ]] || gd="$r/$gd"
    if [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" ]]; then
      failures+=("$name: a rebase or merge is already in progress - finish or abort it by hand"); continue
    fi
    branch=$(git -C "$r" branch --show-current)

    if [[ "$name" != "dotfiles" && -n "$(git -C "$r" status --porcelain)" ]]; then
      git -C "$r" add -A
      git -C "$r" commit -q -m "auto-sync: $(hostname -s) $(date '+%Y-%m-%d %H:%M')" \
        && echo "  $name: committed local changes"
    fi

    if [[ "$name" == "dotfiles" && -n "$(git -C "$r" status --porcelain)" ]]; then
      git -C "$r" fetch -q origin 2>/dev/null
      if [[ "$(git -C "$r" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)" -gt 0 ]]; then
        failures+=("dotfiles: behind the remote but has uncommitted edits - commit them, then run sync")
      else
        echo "  dotfiles: uncommitted edits, nothing to pull - left alone"
      fi
      continue
    fi

    out=$(git -C "$r" pull -q --rebase 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
      [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" ]] && git -C "$r" rebase --abort >/dev/null 2>&1
      failures+=("$name: pull failed, rebase aborted, nothing changed - $(printf '%s' "$out" | grep -m1 -E 'CONFLICT|fatal|error' || printf '%s' "$out" | head -1)")
      continue
    fi
    echo "  $name: pulled ($(git -C "$r" rev-parse --short HEAD))"

    [[ "$name" == "dotfiles" ]] && continue
    un=$(git -C "$r" log HEAD --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$un" -gt 0 ]]; then
      git -C "$r" push -q origin "HEAD:refs/heads/$branch" >/dev/null 2>&1
      # The remote, not push's exit code: see "git push can report Everything up-to-date while
      # the remote is behind" in ~/.claude/CLAUDE.md.
      L=$(git -C "$r" rev-parse HEAD); R=$(git -C "$r" ls-remote origin "$branch" 2>/dev/null | cut -f1)
      if [[ "$L" == "$R" ]]; then echo "  $name: pushed $un commit(s)"
      else failures+=("$name: push did not land ($un commit(s) local only, remote ${R:0:7})"); fi
    fi
  done

  if [[ ${#failures[@]} -gt 0 ]]; then
    mkdir -p "$(dirname "$marker")"
    { echo "auto-sync failed on $(hostname -s) at $(stamp) - log: ~/Library/Logs/auto-sync.log"
      printf '%s\n' "${failures[@]}"; } > "$marker"
    printf '  FAILED: %s\n' "${failures[@]}"
    osascript -e "display notification \"${#failures[@]} problem(s) - see ~/.claude/status/auto-sync-failure.txt\" with title \"auto-sync failed\"" >/dev/null 2>&1
    stop_watchdog; return 1
  fi
  stop_watchdog
  rm -f "$marker"
  echo "  ok"
}

if [[ "${1:-}" == "--auto" ]]; then auto_sync; exit $?; fi

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
