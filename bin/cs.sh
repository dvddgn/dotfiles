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
  local proj=$1 limit=$2 filter=$3
  [[ -d "$proj" ]] || die "no sessions recorded for that directory ($proj)"
  python3 - "$proj" "$limit" "$filter" <<'PY'
import glob, json, os, sys, time
proj, limit, filt = sys.argv[1], int(sys.argv[2]), sys.argv[3].lower()
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
    rows = [r for r in rows if filt in r[3].lower()]
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

# ---- resume -------------------------------------------------------------------
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
