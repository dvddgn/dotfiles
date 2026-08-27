#!/bin/bash
# cs.sh — find and resume Claude Code sessions for a working directory.
#
# Claude keys its transcripts by working directory, so a directory that hosts many
# long-running conversations (the claw workspace has 39) gives you a resume picker
# with no labels on it. This lists them with the line that started each one, which
# is what actually tells you which is which.
#
# Usage:
#   cs                       # sessions for the current directory, newest first
#   cs <dir>                 # sessions for another directory
#   cs -n 40                 # show more (default 20)
#   cs -g email              # only those whose opening line matches
#   cs r <n|session-id>      # resume that one (index from the listing, or an id)
#   cs r <n> --opus          # resume with a model override
#   cs snapshot              # record every live Claude tmux session (do this now)
#                            # also writes tmux-inventory.tsv (all sessions+windows)
#                            # and servers.tsv (everything listening, and which slot owns it)
#   cs restore               # after a reboot: rebuild those sessions
#
# Transcripts live under ~/.claude/projects and outlive the directory itself, so a
# session whose worktree or terminal is gone is still here and still resumable.

set -uo pipefail

die() { echo "Error: $*" >&2; exit 1; }

proj_dir() {
  local d
  d=$(cd "${1:-$PWD}" 2>/dev/null && pwd -P) || d="${1:-$PWD}"
  # Claude encodes the path with BOTH separators and dots replaced by dashes:
  # /Users/dd/.openclaw/workspace -> -Users-dd--openclaw-workspace
  echo "$HOME/.claude/projects/$(echo "$d" | sed 's|[/.]|-|g')"
}

list_sessions() {
  local proj=$1 limit=$2 filter=$3 matches=""
  [[ -d "$proj" ]] || die "no sessions recorded for that directory ($proj)"
  # Search the whole conversation, not just its opening line - what you remember
  # about a session is rarely the first thing you said to it. grep does this in
  # seconds over hundreds of MB where re-parsing the JSON in python would not.
  if [[ -n "$filter" ]]; then
    matches=$(grep -ril -- "$filter" "$proj"/*.jsonl 2>/dev/null \
              | xargs -n1 basename 2>/dev/null | sed 's/\.jsonl$//' | paste -sd, -)
  fi
  python3 - "$proj" "$limit" "$filter" "$matches" <<'PY'
import glob, json, os, sys, time
proj, limit, filt = sys.argv[1], int(sys.argv[2]), sys.argv[3].lower()
deep = set(filter(None, (sys.argv[4] if len(sys.argv) > 4 else "").split(",")))
rows = []
for f in glob.glob(os.path.join(proj, "*.jsonl")):
    first = None
    try:
        with open(f, errors="ignore") as fh:
            for line in fh:
                try: rec = json.loads(line)
                except Exception: continue
                if rec.get("type") != "user": continue
                c = rec.get("message", {}).get("content")
                if isinstance(c, list):
                    c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
                # Skip system-injected openers; the first thing DD typed is the label.
                if isinstance(c, str) and c.strip() and not c.lstrip().startswith("<"):
                    first = " ".join(c.split())[:78]
                    break
    except OSError:
        continue
    rows.append((os.path.getmtime(f), os.path.basename(f)[:-6], os.path.getsize(f), first or "(no user text)"))
rows.sort(reverse=True)
if filt:
    # A hit in the opening line or anywhere in the transcript.
    rows = [r for r in rows if filt in r[3].lower() or r[1] in deep]
if not rows:
    print("  no matching sessions"); raise SystemExit(0)
print(f"  {len(rows)} session(s) in {proj}\n")
for i, (mt, sid, size, first) in enumerate(rows[:limit], 1):
    print(f"  {i:3}  {time.strftime('%m-%d %H:%M', time.localtime(mt))}  {size/1e6:6.1f}MB  {first}")
    print(f"       {sid}")
if len(rows) > limit:
    print(f"\n  … {len(rows) - limit} more; -n {len(rows)} to see all")
# The index->id map, so `cs r <n>` does not have to re-derive the ordering.
with open(os.path.join(proj, ".cs-index"), "w") as fh:
    fh.write("\n".join(r[1] for r in rows))
PY
}

# ---- snapshot / restore -------------------------------------------------------
# tmux does not survive a reboot here (no resurrect/continuum), so a restart takes
# every session with it. The transcripts survive, and each running Claude shows the
# name it was launched with - which is what `--resume` takes. Recording the pair
# (tmux session, working directory, Claude session name) is therefore enough to
# rebuild the lot.
#
# The map lives outside any repo on purpose: these names describe personal
# subjects, and dotfiles is a public repository.
# One folder, so everything about the machine's live state is in one place, and
# each file is column-aligned rather than raw TSV - these are read by eye far more
# often than they are parsed.
STATUS="$HOME/.claude/status"
MAP="$STATUS/sessions.txt"

cmd_snapshot() {
  local n=0 seen=""
  mkdir -p "$STATUS"
  : > "$MAP.tmp"
  # Walk WINDOWS, not sessions: reading a session gives only its ACTIVE pane, so a
  # session with three agent windows recorded one, and `ws` - whose active window
  # is a shell - was missed entirely despite running three agents.
  #
  # Target by window INDEX, never by name. Claude names its window after its own
  # version (2.1.220), and tmux reads the dot as a pane separator, so
  # `-t session:2.1.220` silently resolves to nothing.
  while IFS=$'\t' read -r sess idx wname cwd; do
    local title label t
    [[ -z "$sess" || ! -d "$cwd" ]] && continue
    t="${sess}:${idx}"

    # Detect Claude by what is on screen, not by the process name: a session
    # launched through ccp leaves `bash` as the pane's foreground process, so
    # filtering on the command name misses exactly the sessions that matter.
    tmux capture-pane -t "$t" -p 2>/dev/null | LC_ALL=C tr -cd '\11\12\15\40-\176' \
      | grep -qE 'bypass permissions|accept edits|plan mode' || continue

    # Claude shows TWO things and only one is resumable: the SESSION NAME (set by
    # `claude -n` or /rename), and below the working directory an auto-generated
    # CONVERSATION SUMMARY that drifts as the subject moves. --resume takes the
    # name, so read the line above the cwd rather than the one below it.
    title=$(tmux capture-pane -t "$t" -p 2>/dev/null | LC_ALL=C tr -cd '\11\12\15\40-\176' \
            | awk '{L[n++]=$0} END{ for(i=n-1;i>=0;i--) if (L[i] ~ /^  [~.\/]/) {
                     # the name is a tab above the input box: exactly one leading
                     # space, where input-box text starts at column 0
                     for(j=i-1;j>=0 && j>i-6;j--) if (L[j] ~ /^ [^ ]/) { print L[j]; exit }
                     exit } }' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]\{2,\}.*$//;s/[[:space:]]*$//')
    if [[ -z "$title" ]]; then
      title=$(tmux capture-pane -t "$t" -p 2>/dev/null | grep -v '^$' \
              | grep -B1 -E '·[[:space:]]+(Opus|Sonnet|Haiku|Fable)' | head -1 \
              | sed 's/^[[:space:]]*//;s/[[:space:]]\{2,\}.*$//;s/[[:space:]]*$//')
    fi

    # The first agent window in a session is the session; later ones are qualified
    # by window name, which is what `cs restore` needs to recreate them.
    if [[ " $seen " == *" $sess "* ]]; then label="${sess}:${wname}"; else label="$sess"; seen="$seen $sess"; fi

    printf '%s\t%s\t%s\n' "$label" "$cwd" "$title" >> "$MAP.tmp"
    n=$((n + 1))
  done < <(tmux list-panes -a -F "#{session_name}$(printf '\t')#{window_index}$(printf '\t')#{window_name}$(printf '\t')#{pane_current_path}" 2>/dev/null)

  mkdir -p "$STATUS"
  { printf 'SESSION\tDIRECTORY\tCLAUDE SESSION NAME\n'
    sort -t$'\t' -k2,2 -k1,1 "$MAP.tmp"; } | column -t -s$'\t' > "$MAP"
  rm -f "$MAP.tmp"
  write_inventory
  write_servers
  [[ -f "$STATUS/README.md" ]] || cp "$HOME/code/dvddgn/dotfiles/status-README.md" "$STATUS/README.md" 2>/dev/null
  echo "Recorded $n live Claude session(s) -> $STATUS/"
  printf '  %s\n' "sessions.txt  ($n)" \
                  "windows.txt   ($(($(wc -l < "$INVENTORY") - 1)) windows)" \
                  "servers.txt   ($(($(wc -l < "$SERVERS") - 1)) listening)"
}

# Everything open, not just the Claude sessions: one row per tmux WINDOW, so a
# session with several agent windows shows all of them.
INVENTORY="$STATUS/windows.txt"
write_inventory() {
  mkdir -p "$STATUS"
  {
    printf 'SESSION\tWINDOW\tNAME\tCOMMAND\tDIRECTORY\n'
    # tmux does not interpret \t in a format string - the tab has to be a real one.
    tmux list-windows -a -F "#{session_name}$(printf '\t')#{window_index}$(printf '\t')#{window_name}$(printf '\t')#{pane_current_command}$(printf '\t')#{pane_current_path}" 2>/dev/null \
      | sort -t$'\t' -k5,5 -k1,1 -k2,2n
  } | column -t -s$'\t' > "$INVENTORY"
}

# What is actually listening, and which slot owns it. The <worktree>.port files map
# a port back to the slot that reserved it, which is the bit lsof cannot tell you.
SERVERS="$STATUS/servers.txt"
write_servers() {
  # Slots reserve their port in a <worktree>.port file; the clones and the shared
  # services have fixed ones (services.sh owns that table). Together these turn a
  # bare port number into "who is this".
  local portmap="3000=aih;3001=c1;3002=c2;3003=c3;3004=c4;3005=c5;3006=m1;3007=m2;"
  portmap+="3008=m3;3009=m4;3010=m5;3011=hre;3036=vite;5432=postgres;6379=redis;" 
  local f
  for f in "$HOME"/code/dvddgn/aih-wt-*.port; do
    [[ -f "$f" ]] || continue
    portmap+="$(cat "$f")=wt-$(basename "$f" .port | sed 's/^aih-wt-//');"
  done
  {
    printf 'PORT\tPID\tPROCESS\tOWNER\tURL\tDIRECTORY\n'
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {
        split($9, a, ":"); port = a[length(a)]
        key = port "|" $2
        if (seen[key]++) next
        gsub(/\\x20.*/, "", $1)
        printf "%s\t%s\t%s\n", port, $2, $1
      }' | sort -n -u | while IFS=$'\t' read -r port pid proc; do
        owner=$(echo "$portmap" | tr ';' '\n' | awk -F= -v p="$port" '$1==p {print $2}')
        # The process's own working directory - what identifies the rows the port
        # table cannot name. One lsof per pid, which is cheap at this scale.
        dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
        dir=${dir/#$HOME/\~}
        # A URL only means something for something serving HTTP.
        local url="http://localhost:$port"
        case "$proc" in postgres|redis-ser|mysqld|mongod) url="-" ;; esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$port" "$pid" "$proc" "${owner:--}" "$url" "${dir:--}"
      done
  } | column -t -s$'\t' > "$SERVERS"
}

cmd_restore_tmux() {
  [[ -f "$MAP" ]] || die "no snapshot at $MAP - run 'cs snapshot' while the sessions are up"
  local rebuilt=0 skipped=0
  while read -r sess cwd title; do
    [[ -z "$sess" || "$sess" == "SESSION" ]] && continue
    # A row is either a session, or session:window for a second-or-later agent
    # window in that session. Both have to come back.
    local base="${sess%%:*}" win=""
    [[ "$sess" == *:* ]] && win="${sess#*:}"

    if [[ -z "$win" ]]; then
      tmux has-session -t "$base" 2>/dev/null && { skipped=$((skipped + 1)); continue; }
    else
      tmux list-windows -t "$base" -F '#{window_name}' 2>/dev/null | grep -qx "$win" \
        && { skipped=$((skipped + 1)); continue; }
    fi

    [[ -d "$cwd" ]] || { echo "  $sess: directory gone ($cwd)"; continue; }
    if [[ -z "$win" ]]; then
      tmux new-session -d -s "$base" -c "$cwd"
    else
      tmux has-session -t "$base" 2>/dev/null || tmux new-session -d -s "$base" -c "$cwd"
      tmux new-window -d -t "$base" -n "$win" -c "$cwd"
    fi
    rebuilt=$((rebuilt + 1))
    # A kebab-case title is a name passed to `claude -n`, so --resume takes it.
    # Anything with spaces is a generated summary; fall back to finding it by text.
    if [[ "$title" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      echo "  $sess: rebuilt — resume: tmux send-keys -t $sess 'claude --resume $title' C-m"
    else
      echo "  $sess: rebuilt — unnamed; find it with: cd $cwd && cs -g '${title%% *}'"
    fi
  done < "$MAP"
  echo
  echo "$rebuilt rebuilt, $skipped already up. Agents are not resumed - the lines above do that."
}

# ---- resume -------------------------------------------------------------------
[[ "${1:-}" == "snapshot" ]] && { cmd_snapshot; exit 0; }
[[ "${1:-}" == "restore"  ]] && { cmd_restore_tmux; exit 0; }

if [[ "${1:-}" == "r" || "${1:-}" == "resume" ]]; then
  shift
  TARGET="${1:?usage: cs r <index-or-session-id> [--model X|--opus|--sonnet]}"; shift
  PROJ=$(proj_dir "$PWD")
  # A bare number means "the Nth row of the last listing"; anything else is an id.
  if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    [[ -f "$PROJ/.cs-index" ]] || die "run 'cs' first so an index exists"
    TARGET=$(sed -n "${TARGET}p" "$PROJ/.cs-index")
    [[ -n "$TARGET" ]] || die "no session at that index"
  fi
  MODEL=""
  ARGS=()
  for a in "$@"; do
    case "$a" in
      --opus) MODEL=opus ;;
      --sonnet) MODEL=sonnet ;;
      --model) MODEL=__next__ ;;
      *) [[ "$MODEL" == "__next__" ]] && MODEL="$a" || ARGS+=("$a") ;;
    esac
  done
  echo "Resuming $TARGET${MODEL:+ on $MODEL}"
  exec claude --resume "$TARGET" --dangerously-skip-permissions ${MODEL:+--model "$MODEL"} "${ARGS[@]}"
fi

# ---- list ---------------------------------------------------------------------
DIR="$PWD"; LIMIT=20; FILTER=""
while (($#)); do
  case "$1" in
    -n) LIMIT="${2:?-n needs a number}"; shift 2 ;;
    -g) FILTER="${2:?-g needs a pattern}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) DIR="$1"; shift ;;
  esac
done
list_sessions "$(proj_dir "$DIR")" "$LIMIT" "$FILTER"
echo
echo "  cs r <n>   to resume one"
