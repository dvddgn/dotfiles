#!/bin/bash
# Session-scoped Workspace project context for tmux.
#
# A bound session gets three status rows:
#   1. session + complete window menu + time
#   2. Workspace project name + terminal-safe short URL
#   3. active window purpose + live pane working directory
#
# Bindings survive tmux/server restarts in ~/.claude/status/tmux-projects.tsv.
# Sessions without a project use an inferred REPO, AREA, or SYSTEM context.

set -uo pipefail

STATUS_DIR="${TMUX_PROJECT_STATUS_DIR:-$HOME/.claude/status}"
STATE_FILE="$STATUS_DIR/tmux-projects.tsv"
STATE_LOCK="${STATE_FILE}.lock"
CONTEXT_FILE="$STATUS_DIR/tmux-contexts.tsv"
CONTEXT_LOCK="${CONTEXT_FILE}.lock"
RESOLVER="${TMUX_PROJECT_RESOLVER:-$HOME/code/dvddgn/workspace-app/scripts/resolve-ref.js}"

ROW_0='#[align=left bg=#1e3a5f fg=white] #S  #{W:#[bg=#1e3a5f fg=white] #I:#W ,#[bg=white fg=#1e3a5f bold] #I:#W }#[align=right bg=#1e3a5f fg=white nobold] %H:%M '
ROW_1_URL='#[align=left,bg=#102a43,fg=#7dd3fc] #{@context_label_display}  #{=/#{?#{>:#{e|-:#{e|-:#{client_width},#{n:#{@context_url}}},15},3},#{e|-:#{e|-:#{client_width},#{n:#{@context_url}}},15},3}/…:#{@context_name}} #[align=right,bg=#102a43,fg=#7dd3fc] · #{@context_url} '
ROW_1_NO_URL='#[align=left,bg=#102a43,fg=#7dd3fc] #{@context_label_display}  #{@context_name} '
ROW_2='#[align=left,bg=#172f49,fg=#f7c873] WINDOW   #W  ·  #[fg=#d5e2ed]#{@window_purpose} #[align=right,fg=#9fb3c8] #{pane_current_path} '

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  tmux-project bind [--force] [session] <project-ref>
  tmux-project context [--url <url>] [session] <repo|area|system> <name>
  tmux-project resolve <project-ref>
  tmux-project apply [session|--all]
  tmux-project purposes [session|--all]
  tmux-project purpose <session:window> <description>
  tmux-project clear [session]          # clear project; inferred/custom context remains
  tmux-project clear-context [session]  # clear manual context; inference remains
  tmux-project forget <session>
  tmux-project rename <old-session> <new-session>
  tmux-project list
  tmux-project status [session]

Examples:
  tmux-project bind wt-pdp project:project-detail-pages-update-live
  tmux-project bind project:project-detail-pages-update-live   # current session
  tmux-project context m1 repo "Advice Innovation Hub · manual workspace"
  tmux-project context ops-budget area "Budget operations"
  tmux-project purpose wt-pdp:claude2 "Parallel investigation"
EOF
}

current_session() {
  if [[ -n "${TMUX_PANE:-}" ]]; then
    tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null
  else
    tmux display-message -p '#S' 2>/dev/null
  fi
}

ensure_state() {
  mkdir -p "$STATUS_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'SESSION\tPROJECT REF\tPROJECT NAME\tSHORT URL\n' > "$STATE_FILE"
  fi
}

acquire_state_lock() {
  local lock=$1 attempts=0
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ "$attempts" -ge 100 ]]; then
      # A write holds this for milliseconds. After five seconds an empty lock is
      # from an interrupted process, not a legitimate long-running update.
      rmdir "$lock" 2>/dev/null || die "tmux context state is locked at $lock"
      mkdir "$lock" 2>/dev/null || die "could not acquire tmux context state lock"
      break
    fi
    sleep 0.05
  done
}

release_state_lock() {
  rmdir "$1" 2>/dev/null || true
}

clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

state_record() {
  local session=$1
  [[ -f "$STATE_FILE" ]] || return 1
  awk -F '\t' -v session="$session" 'NR > 1 && $1 == session { print; exit }' "$STATE_FILE"
}

write_record() {
  local session=$1 ref=$2 name=$3 url=$4 tmp
  ensure_state
  session=$(clean_field "$session")
  ref=$(clean_field "$ref")
  name=$(clean_field "$name")
  url=$(clean_field "$url")
  acquire_state_lock "$STATE_LOCK"
  tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || { release_state_lock "$STATE_LOCK"; die "could not create state temp file"; }
  {
    printf 'SESSION\tPROJECT REF\tPROJECT NAME\tSHORT URL\n'
    awk -F '\t' -v session="$session" 'NR > 1 && $1 != session { print }' "$STATE_FILE"
    printf '%s\t%s\t%s\t%s\n' "$session" "$ref" "$name" "$url"
  } > "$tmp"
  mv "$tmp" "$STATE_FILE"
  release_state_lock "$STATE_LOCK"
}

forget_record() {
  local session=$1 tmp
  [[ -f "$STATE_FILE" ]] || return 0
  acquire_state_lock "$STATE_LOCK"
  tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || { release_state_lock "$STATE_LOCK"; die "could not create state temp file"; }
  awk -F '\t' -v session="$session" 'NR == 1 || $1 != session { print }' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  release_state_lock "$STATE_LOCK"
}

ensure_context_state() {
  mkdir -p "$STATUS_DIR"
  if [[ ! -f "$CONTEXT_FILE" ]]; then
    printf 'SESSION\tLABEL\tNAME\tURL\n' > "$CONTEXT_FILE"
  fi
}

context_record() {
  local session=$1
  [[ -f "$CONTEXT_FILE" ]] || return 1
  awk -F '\t' -v session="$session" 'NR > 1 && $1 == session { print; exit }' "$CONTEXT_FILE"
}

write_context_record() {
  local session=$1 label=$2 name=$3 url=$4 tmp
  ensure_context_state
  session=$(clean_field "$session")
  label=$(clean_field "$label")
  name=$(clean_field "$name")
  url=$(clean_field "$url")
  acquire_state_lock "$CONTEXT_LOCK"
  tmp=$(mktemp "${CONTEXT_FILE}.tmp.XXXXXX") || { release_state_lock "$CONTEXT_LOCK"; die "could not create context temp file"; }
  {
    printf 'SESSION\tLABEL\tNAME\tURL\n'
    awk -F '\t' -v session="$session" 'NR > 1 && $1 != session { print }' "$CONTEXT_FILE"
    printf '%s\t%s\t%s\t%s\n' "$session" "$label" "$name" "$url"
  } > "$tmp"
  mv "$tmp" "$CONTEXT_FILE"
  release_state_lock "$CONTEXT_LOCK"
}

forget_context_record() {
  local session=$1 tmp
  [[ -f "$CONTEXT_FILE" ]] || return 0
  acquire_state_lock "$CONTEXT_LOCK"
  tmp=$(mktemp "${CONTEXT_FILE}.tmp.XXXXXX") || { release_state_lock "$CONTEXT_LOCK"; die "could not create context temp file"; }
  awk -F '\t' -v session="$session" 'NR == 1 || $1 != session { print }' "$CONTEXT_FILE" > "$tmp"
  mv "$tmp" "$CONTEXT_FILE"
  release_state_lock "$CONTEXT_LOCK"
}

humanise_slug() {
  printf '%s\n' "$1" | tr '_-' '  ' | awk '
    {
      for (i = 1; i <= NF; i++) {
        lower = tolower($i)
        if (lower == "aih" || lower == "ai" || lower == "uwc" || lower == "us" || lower == "api" || lower == "dd") {
          word = toupper(lower)
        } else if (i == 1) {
          word = toupper(substr(lower, 1, 1)) substr(lower, 2)
        } else {
          word = lower
        }
        printf "%s%s", (i == 1 ? "" : " "), word
      }
      printf "\n"
    }'
}

infer_context() {
  local session=$1 path repo base title
  path=$(tmux display-message -p -t "$session" '#{session_path}' 2>/dev/null || true)
  case "$session" in
    _orchestrator) printf 'SYSTEM\tAI Builder orchestration\t\n' ;;
    aih) printf 'REPO\tAdvice Innovation Hub · loop runner\t\n' ;;
    c[1-5]) printf 'REPO\tAdvice Innovation Hub · Codex clone %s\t\n' "$session" ;;
    m[1-5]) printf 'REPO\tAdvice Innovation Hub · manual workspace %s\t\n' "$session" ;;
    m1-notes) printf 'REPO\tAgent Skills · process notes\t\n' ;;
    ws) printf 'REPO\tWorkspace App\t\n' ;;
    hre) printf 'REPO\tHorizons Real Estate\t\n' ;;
    claw) printf 'REPO\tOpenClaw workspace\t\n' ;;
    claw-*) printf 'AREA\tOpenClaw ad-hoc session\t\n' ;;
    ops-*) printf 'AREA\t%s\t\n' "$(humanise_slug "${session#ops-}")" ;;
    prj-*) printf 'AREA\t%s\t\n' "$(humanise_slug "${session#prj-}")" ;;
    wt-*) printf 'REPO\tAdvice Innovation Hub · worktree %s\t\n' "${session#wt-}" ;;
    sess-*|[0-9]*) printf 'AREA\tAd-hoc terminal session\t\n' ;;
    *)
      repo=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$repo" ]]; then
        base=${repo##*/}
        title=$(humanise_slug "$base")
        printf 'REPO\t%s\t\n' "$title"
      else
        printf 'AREA\t%s\t\n' "$(humanise_slug "$session")"
      fi
      ;;
  esac
}

purpose_for() {
  local session=$1 index=$2 name=$3 command=$4
  case "$name" in
    shell|zsh) echo "Git, tests and quick commands" ;;
    rails) echo "Local Rails application server" ;;
    sidekiq) echo "Background jobs and queue processing" ;;
    vite) echo "Frontend assets and hot reload" ;;
    css) echo "Tailwind CSS watch" ;;
    health) echo "Workspace health checks" ;;
    localhost) echo "Workspace development server" ;;
    claude|claude1|cc1) echo "Primary Claude planning and implementation" ;;
    claude2|cc2) echo "Parallel Claude investigation" ;;
    claude3|cc3) echo "Claude review and follow-up" ;;
    claude[4-9]*|cc[4-9]*) echo "Additional Claude workstream" ;;
    codex|cx[0-9]*) echo "Codex implementation and code review" ;;
    bash)
      if [[ "$session" == wt-* && "$index" == "1" ]]; then
        echo "Primary Claude planning and implementation"
      else
        echo "Shell commands and project work"
      fi
      ;;
    *)
      case "$command" in
        codex) echo "Codex implementation and code review" ;;
        claude|[0-9]*.[0-9]*) echo "Claude project session" ;;
        ruby) echo "Ruby process" ;;
        node) echo "Node.js process" ;;
        *)
          case "$session" in
            ops-*) echo "Standing operations workspace" ;;
            prj-*) echo "Focused project workspace" ;;
            wt-*) echo "Project work" ;;
            *) echo "Working terminal" ;;
          esac
          ;;
      esac
      ;;
  esac
}

apply_purposes() {
  local session=$1 index name command existing purpose
  tmux has-session -t "$session" 2>/dev/null || return 0
  while IFS=$'\t' read -r index name command existing; do
    [[ -n "$index" || -n "$name" ]] || continue
    [[ -n "$existing" ]] && continue
    purpose=$(purpose_for "$session" "$index" "$name" "$command")
    tmux set-window-option -q -t "$session:$index" @window_purpose "$purpose"
  done < <(tmux list-windows -t "$session" -F "#{window_index}$(printf '\t')#{window_name}$(printf '\t')#{pane_current_command}$(printf '\t')#{@window_purpose}")
}

apply_context() {
  local session=$1 label=$2 name=$3 url=$4 source=$5 label_display row
  printf -v label_display '%-7s' "$label"
  [[ -n "$url" ]] && row=$ROW_1_URL || row=$ROW_1_NO_URL
  tmux set-option -q -t "$session" @context_label "$label" \; \
    set-option -q -t "$session" @context_label_display "$label_display" \; \
    set-option -q -t "$session" @context_name "$name" \; \
    set-option -q -t "$session" @context_url "$url" \; \
    set-option -q -t "$session" @context_source "$source" \; \
    set-option -q -t "$session" status 3 \; \
    set-option -q -t "$session" 'status-format[0]' "$ROW_0" \; \
    set-option -q -t "$session" 'status-format[1]' "$row" \; \
    set-option -q -t "$session" 'status-format[2]' "$ROW_2"
}

apply_project_record() {
  local record=$1 session ref name url
  IFS=$'\t' read -r session ref name url <<< "$record"
  tmux has-session -t "$session" 2>/dev/null || return 0
  tmux set-option -q -t "$session" @project_ref "$ref" \; \
    set-option -q -t "$session" @project_name "$name" \; \
    set-option -q -t "$session" @project_url "$url"
  apply_context "$session" PROJECT "$name" "$url" project
}

clear_project_options() {
  local session=$1
  tmux set-option -qu -t "$session" @project_ref \; \
    set-option -qu -t "$session" @project_name \; \
    set-option -qu -t "$session" @project_url 2>/dev/null || true
}

apply_session() {
  local session=$1 record label name url
  tmux has-session -t "$session" 2>/dev/null || return 0
  apply_purposes "$session"
  record=$(state_record "$session" 2>/dev/null || true)
  if [[ -n "$record" ]]; then
    apply_project_record "$record"
    return 0
  fi

  clear_project_options "$session"
  record=$(context_record "$session" 2>/dev/null || true)
  if [[ -n "$record" ]]; then
    IFS=$'\t' read -r _ label name url <<< "$record"
    apply_context "$session" "$label" "$name" "$url" manual
  else
    record=$(infer_context "$session")
    IFS=$'\t' read -r label name url <<< "$record"
    apply_context "$session" "$label" "$name" "$url" inferred
  fi
  return 0
}

apply_all() {
  local session
  while IFS= read -r session; do
    [[ -n "$session" ]] && apply_session "$session"
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

resolve_project() {
  local ref=$1 json
  [[ -f "$RESOLVER" ]] || die "project resolver not found at $RESOLVER"
  json=$(node "$RESOLVER" --json "$ref") || return 1
  printf '%s' "$json" | node -e '
    let input = "";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const value = JSON.parse(input);
      if (value.type !== "project") {
        console.error(`Expected a project reference, got ${value.type}`);
        process.exit(2);
      }
      const fields = [value.ref, value.name, value.short_url];
      process.stdout.write(fields.map(v => String(v || "").replace(/[\t\r\n]/g, " ")).join("\t"));
    });'
}

bind_project() {
  local force=false session="" ref="" resolved canonical name url existing
  while (($#)); do
    case "$1" in
      --force) force=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$session" ]]; then session=$1; elif [[ -z "$ref" ]]; then ref=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  if [[ -z "$ref" ]]; then
    ref=$session
    session=$(current_session) || die "no current tmux session; pass a session name"
  fi
  [[ -n "$session" && -n "$ref" ]] || die "usage: tmux-project bind [--force] [session] <project-ref>"
  resolved=$(resolve_project "$ref") || exit $?
  IFS=$'\t' read -r canonical name url <<< "$resolved"
  existing=$(state_record "$session" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    local existing_ref
    existing_ref=$(printf '%s\n' "$existing" | awk -F '\t' '{print $2}')
    if [[ "$existing_ref" != "$canonical" && "$force" != true ]]; then
      die "$session is already bound to $existing_ref; use --force to replace it"
    fi
  fi

  write_record "$session" "$canonical" "$name" "$url"
  apply_session "$session"
  echo "$session -> $name ($canonical)"
  echo "  $url"
}

cmd_clear() {
  local session=${1:-}
  [[ -n "$session" ]] || session=$(current_session) || die "no current tmux session; pass a session name"
  forget_record "$session"
  apply_session "$session"
  echo "$session: project binding cleared; session context restored"
}

cmd_context() {
  local url="" session="" label="" name=""
  while (($#)); do
    case "$1" in
      --url) url="${2:?--url needs a value}"; shift 2 ;;
      -*) die "unknown flag $1" ;;
      *)
        if [[ -z "$session" ]]; then session=$1
        elif [[ -z "$label" ]]; then label=$1
        elif [[ -z "$name" ]]; then name=$1
        else die "unexpected argument $1"
        fi
        shift
        ;;
    esac
  done
  if [[ -z "$name" ]]; then
    name=$label
    label=$session
    session=$(current_session) || die "no current tmux session; pass a session name"
  fi
  label=$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')
  case "$label" in
    REPO|AREA|SYSTEM) ;;
    *) die "context label must be repo, area, or system" ;;
  esac
  [[ -n "$name" ]] || die "usage: tmux-project context [--url <url>] [session] <repo|area|system> <name>"
  write_context_record "$session" "$label" "$name" "$url"
  apply_session "$session"
  if state_record "$session" >/dev/null 2>&1; then
    echo "$session: saved $label $name; the Workspace project remains active until it is cleared"
  else
    echo "$session -> $label $name"
  fi
  [[ -n "$url" ]] && echo "  $url"
  return 0
}

cmd_clear_context() {
  local session=${1:-}
  [[ -n "$session" ]] || session=$(current_session) || die "no current tmux session; pass a session name"
  forget_context_record "$session"
  apply_session "$session"
  echo "$session: manual context cleared; effective context reapplied"
}

cmd_forget() {
  local session=${1:?usage: tmux-project forget <session>}
  forget_record "$session"
  forget_context_record "$session"
  echo "$session: saved project binding and manual context removed"
}

cmd_rename() {
  local old=${1:?usage: tmux-project rename <old-session> <new-session>}
  local new=${2:?usage: tmux-project rename <old-session> <new-session>}
  local record ref label name url moved=false
  record=$(state_record "$old" 2>/dev/null || true)
  if [[ -n "$record" ]]; then
    IFS=$'\t' read -r _ ref name url <<< "$record"
    forget_record "$old"
    write_record "$new" "$ref" "$name" "$url"
    moved=true
  fi
  record=$(context_record "$old" 2>/dev/null || true)
  if [[ -n "$record" ]]; then
    IFS=$'\t' read -r _ label name url <<< "$record"
    forget_context_record "$old"
    write_context_record "$new" "$label" "$name" "$url"
    moved=true
  fi
  [[ "$moved" == true ]] || return 0
  apply_session "$new"
  echo "$old -> $new: saved tmux context moved"
}

cmd_purposes() {
  local target=${1:-}
  if [[ "$target" == "--all" ]]; then
    local session
    while IFS= read -r session; do apply_purposes "$session"; done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  else
    [[ -n "$target" ]] || target=$(current_session) || die "no current tmux session; pass a session name"
    apply_purposes "$target"
  fi
}

cmd_purpose() {
  local target=${1:?usage: tmux-project purpose <session:window> <description>}
  shift
  (($#)) || die "usage: tmux-project purpose <session:window> <description>"
  tmux set-window-option -q -t "$target" @window_purpose "$*"
}

cmd_apply() {
  local target=${1:-}
  if [[ "$target" == "--all" ]]; then
    apply_all
  else
    [[ -n "$target" ]] || target=$(current_session) || die "no current tmux session; pass a session name"
    apply_session "$target"
  fi
}

cmd_list() {
  ensure_state
  ensure_context_state
  echo "Workspace project bindings:"
  if command -v column >/dev/null 2>&1; then column -t -s $'\t' "$STATE_FILE"; else cat "$STATE_FILE"; fi
  echo
  echo "Manual session contexts:"
  if command -v column >/dev/null 2>&1; then column -t -s $'\t' "$CONTEXT_FILE"; else cat "$CONTEXT_FILE"; fi
}

cmd_status() {
  local session=${1:-}
  [[ -n "$session" ]] || session=$(current_session) || die "no current tmux session; pass a session name"
  local record label name url
  record=$(state_record "$session" 2>/dev/null || true)
  if [[ -n "$record" ]]; then
    printf '%s\n' "$record" | awk -F '\t' '{printf "%s -> PROJECT %s (%s)\n  %s\n", $1, $3, $2, $4}'
    return 0
  fi
  record=$(context_record "$session" 2>/dev/null || true)
  if [[ -n "$record" ]]; then
    IFS=$'\t' read -r _ label name url <<< "$record"
    printf '%s -> %s %s [manual]\n' "$session" "$label" "$name"
  else
    IFS=$'\t' read -r label name url <<< "$(infer_context "$session")"
    printf '%s -> %s %s [inferred]\n' "$session" "$label" "$name"
  fi
  [[ -n "$url" ]] && printf '  %s\n' "$url"
  return 0
}

cmd_resolve() {
  local ref=${1:?usage: tmux-project resolve <project-ref>}
  local resolved canonical name url
  resolved=$(resolve_project "$ref") || exit $?
  IFS=$'\t' read -r canonical name url <<< "$resolved"
  echo "$name ($canonical)"
  echo "  $url"
}

case "${1:-}" in
  bind) shift; bind_project "$@" ;;
  context) shift; cmd_context "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  purposes) shift; cmd_purposes "$@" ;;
  purpose) shift; cmd_purpose "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  clear-context) shift; cmd_clear_context "$@" ;;
  forget) shift; cmd_forget "$@" ;;
  rename) shift; cmd_rename "$@" ;;
  list) shift; cmd_list "$@" ;;
  status) shift; cmd_status "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown command '$1'" ;;
esac
