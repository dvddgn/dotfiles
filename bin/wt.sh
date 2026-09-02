#!/bin/bash
# wt.sh — create or tear down a complete AIH worktree slot in one command.
#
# A slot is: the git worktree, its .env, a copy-on-write node_modules, an entry
# in the shared VS Code workspace, a tmux session, the seven windows a slot always
# ends up needing, its own VS Code window, an iTerm2 tab attached to the session,
# and a dedicated Chrome window (an overview page as the front tab, plus the
# Workspace project, GitHub and the running app) — so none of it is assembled a
# step at a time later. None of these are optional extras: a slot exists to be
# worked in by hand (nothing automated creates one), so it is not finished until
# there is somewhere to work in it.
# --no-ui skips all three, for a batch of slots or a session with no GUI.
#
# Usage:
#   wt new    <slug> [branch] [--project <ref>] [--claudes N] [--monitor N] [--no-rails] [--no-ui]
#   wt agent  <slug> [window-name]
#   wt project <slug> <project-ref>       # bind/change the Workspace project
#   wt project <slug> --clear             # remove the project binding
#   wt restore [slug] [--rails]        # after a reboot: rebuild the tmux sessions
#   wt done   <slug> [--force]
#   wt rename <old-slug> <new-slug> [new-branch]
#   wt rm     <slug> [--force]
#   wt ls
#   wt audit
#
# Examples:
#   wt new dropzone                                  # branch feature/dropzone off origin/main
#   wt new dropzone feature/property-profile-upload-ux
#   wt new review-79 feature/profile-79-review --claudes 2
#   wt new review-79 feature/profile-79-review --monitor 1   # open on display #1, then snap
#   wt done dropzone                                 # the whole close-out, once the PR is merged
#   wt rm  dropzone                                  # teardown alone, merged or not
#
# --monitor N (0-based, matches window_report.js's display index - #0 is the
# main display) moves the new VS Code window onto that display before sending
# Magnet's snap shortcut, since Magnet itself snaps within whichever display a
# window is already on. Omit it and the window snaps on whatever display it
# opened on, as before. Silently ignored (with a note) if N is out of range.
#
# `done` is the one to reach for after a merge: it refuses unless the branch is
# actually in origin/main, then deletes the local and remote branch and tears the
# slot down. `rm` skips the merge check, for a slot being abandoned.
#
# NEITHER can be run from inside the slot. git will remove a worktree from within
# itself quite happily, leaving every shell in that session in a directory that no
# longer exists - `fatal: Unable to read current working directory` on every command
# afterwards, blaming git rather than naming the cause. Both refuse instead.
#
# Windows created in session wt-<slug>, in this order:
#   claude   the agent (ccp <project-slug> to launch one with project context)
#   rails    driven by services.sh / srv; started automatically unless --no-rails
#   sidekiq  left idle until needed. Each checkout has its own Redis queue, so
#            workers may run concurrently when they have an allocated database.
#   vite     left idle too — assets build on demand via autoBuild, so this is
#            only needed for frontend work
#   shell    a free terminal at the worktree root
#
# Ports are allocated by services.sh (3012 upward, recorded in <worktree>.port
# beside the worktree). This script never allocates one itself — it starts rails
# through services.sh and reads the file back.

set -uo pipefail

BASE="$HOME/code/dvddgn"
# The clone the worktrees hang off. Every slot's .git file points into
# $PARENT/.git/worktrees/, so this clone is load-bearing: it must keep existing,
# and its own checkout should stay on main and idle. Override for a different
# clone or repo - existing slots stay bound to whichever parent created them.
PARENT="${AIH_PARENT:-$BASE/advice-innovation-hub-m1}"
SERVICES="$BASE/services.sh"
CS="$BASE/cs.sh"
TMUX_PROJECT="$BASE/dotfiles/bin/tmux-project.sh"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Removing the worktree you are standing in succeeds, and leaves the shell in a
# directory that no longer exists. Refuse, and say where to run it from.
assert_outside() {
  local wt=$1 here real
  here=$(pwd -P 2>/dev/null) || return 0   # already in a phantom dir; nothing to protect
  real=$(cd "$wt" 2>/dev/null && pwd -P) || real="$wt"
  if [[ "$here" == "$real" || "$here" == "$real"/* ]]; then
    echo "Error: you are inside $real" >&2
    echo "       A slot cannot tear itself down - the directory would vanish under this shell." >&2
    echo "       Run it from somewhere else, e.g.:  cd $PARENT && wt ${ACTION:-rm} $(basename "$wt" | sed 's/^aih-wt-//')" >&2
    exit 1
  fi
}

# ---- workspace file -----------------------------------------------------------
# A small .code-workspace INSIDE the worktree, purely so `code <path>.code-workspace`
# opens it as its own window with a real title - "wt · <slug>" in the macOS Window
# menu and the title bar - instead of the bare folder name a plain `code <path>`
# gives you. *.code-workspace is already in .git/info/exclude, which every worktree
# shares with the parent's .git, so this never shows up in `git status` and needs no
# cleanup on teardown - it goes with the directory.
write_standalone_ws() {
  local slug=$1 branch=$2 wt=$3
  python3 - "$wt/$slug.code-workspace" "$slug" "$branch" <<'PY'
import json, sys
path, slug, branch = sys.argv[1:4]
short = branch.removeprefix("feature/")
ws = {
    "folders": [{"name": f"{slug} · {short}", "path": "."}],
    "settings": {
        "window.title": f"wt · {slug} — ${{activeEditorShort}}",
        "workbench.colorCustomizations": {
            "titleBar.activeBackground": "#0f4c5c",
            "titleBar.activeForeground": "#ffffff",
        },
        "window.zoomLevel": 0,
        "terminal.integrated.hideOnStartup": "never",
        "workbench.panel.defaultLocation": "left",
        "terminal.integrated.profiles.osx": {
            f"tmux-wt-{slug}": {
                "path": "/bin/zsh",
                "args": [
                    "-c",
                    f"tmux attach -t wt-{slug} 2>/dev/null || echo 'No tmux session. Run: wt restore {slug}' && exec zsh",
                ],
            }
        },
        "terminal.integrated.defaultProfile.osx": f"tmux-wt-{slug}",
    },
}
open(path, "w").write(json.dumps(ws, indent=2, ensure_ascii=False) + "\n")
print(f"  standalone workspace written ({path.split('/')[-1]})")
PY
}

# Magnet only responds to its own keyboard shortcut, and that shortcut snaps
# within whichever display the window is CURRENTLY on - there is no "snap onto
# display N" shortcut. So targeting a display means moving the window there
# first (a plain position set, not a Magnet action) and only then sending the
# snap keystroke. Same math as the window-layout skill's window_report.js:
# NSScreen frames are bottom-left origin (y-up); Accessibility's `set position`
# wants top-left origin (y-down), so screen 0's height is used to flip every
# other screen's y. Prints "x y" (a point just inside the display, not its
# origin exactly) on success, nothing on an out-of-range index.
display_origin() {
  local idx=$1
  osascript -l JavaScript -e '
    ObjC.import("Cocoa");
    function run(argv) {
      var idx = parseInt(argv[0], 10);
      var screens = $.NSScreen.screens;
      var n = screens.count;
      if (idx < 0 || idx >= n) { return ""; }
      var raw = [];
      for (var i = 0; i < n; i++) {
        var f = screens.objectAtIndex(i).frame;
        raw.push({x: f.origin.x, y: f.origin.y, w: f.size.width, h: f.size.height});
      }
      var primaryH = raw[0].h;
      var d = raw[idx];
      var flippedY = primaryH - (d.y + d.h);
      return Math.round(d.x + 80) + " " + Math.round(flippedY + 80);
    }
  ' "$idx" 2>/dev/null
}

# Magnet (window snapping) only responds to its own global keyboard shortcut -
# there is no CLI or URL scheme - so this raises the just-opened window and sends
# the shortcut as a keystroke via System Events. DD routinely has a dozen-plus VS
# Code windows open across slots, so this deliberately does NOT do the obvious
# thing (`tell application "Code" to activate` then snap whatever is frontmost) -
# a brand-new window takes a beat to render (extension host, this workspace's
# first-time Claude Code sidebar per "The standalone window" section), and firing
# too early would grab and move an unrelated window DD is actively using instead
# of the new one. Poll for the window by the TITLE write_standalone_ws gave it
# ("wt · <slug> — ...") and raise that one specifically, up to 6s, before
# snapping. ⌃⌥T is Magnet's default "right two-thirds" - see the window-layout
# skill if that has been customised.
#
# $2, if given, is a 0-based display index (window_report.js's numbering): the
# window is moved onto that display - via `set position`, not a Magnet action -
# after being raised and before the snap keystroke fires, so Magnet computes
# the two-thirds region against the RIGHT display. An out-of-range index (or a
# monitor setup that changed since) is reported and falls back to snapping in
# place rather than failing the whole slot over window placement.
snap_vscode_window() {
  local slug=$1 monitor=${2:-}
  local moveblock=""
  if [[ -n "$monitor" ]]; then
    local origin tx ty
    origin=$(display_origin "$monitor")
    if [[ -n "$origin" ]]; then
      tx=${origin% *}; ty=${origin#* }
      moveblock="tell process \"Code\" to set position of targetWin to {$tx, $ty}
  delay 0.2"
    else
      echo "  (display $monitor not found - snapping on the window's current display instead)" >&2
    fi
  fi
  # If the window is never found within the poll, the script errors out instead
  # of falling through to the keystroke - the whole point is never sending Magnet's
  # shortcut to whatever happens to be frontmost when the target was not confirmed.
  osascript <<OSA >/dev/null 2>&1
tell application "System Events"
  set foundWin to false
  repeat 20 times
    if exists (first process whose name is "Code") then
      tell process "Code"
        if exists (first window whose name starts with "wt · $slug") then
          set targetWin to (first window whose name starts with "wt · $slug")
          set frontmost to true
          perform action "AXRaise" of targetWin
          set foundWin to true
          exit repeat
        end if
      end tell
    end if
    delay 0.3
  end repeat
  if not foundWin then error "wt · $slug window never appeared"
  delay 0.3
  $moveblock
  keystroke "t" using {control down, option down}
end tell
OSA
}

# ---- windows ------------------------------------------------------------------
# The session shape, in one place, so `new` and `restore` cannot drift apart. The
# names are load-bearing: services.sh drives windows called rails/sidekiq/vite,
# and bin/sidekiq refuses to run unless the session has one named sidekiq.
# How many agent windows a session is scaffolded with. Clone sessions get three
# (startup.sh's cc1/cc2/cc3); slots got one, which meant every extra agent had to
# be added by hand at the moment it was wanted. Override with WT_CLAUDES.
CLAUDES_DEFAULT=${WT_CLAUDES:-3}

make_windows() {
  local session=$1 wt=$2 claudes=${3:-$CLAUDES_DEFAULT} i
  tmux new-session -d -s "$session" -c "$wt" -n claude
  for ((i = 2; i <= claudes; i++)); do
    tmux new-window -d -t "$session" -n "claude$i" -c "$wt"
  done
  tmux new-window -d -t "$session" -n rails   -c "$wt"
  tmux new-window -d -t "$session" -n sidekiq -c "$wt"
  tmux new-window -d -t "$session" -n vite    -c "$wt"
  tmux new-window -d -t "$session" -n shell   -c "$wt"
  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$session" >/dev/null 2>&1 || true
  echo "  tmux session $session: $(tmux list-windows -t "$session" -F '#{window_name}' | paste -sd' ' -)"
}

# The orchestrator is not a slot: it has no checkout of its own and drives the
# others from the parent clone, so it gets agent windows and a shell and none of
# the service windows. Listed here so `wt restore` brings it back after a reboot
# along with everything else - nothing else creates it. Named "_orchestrator"
# (leading underscore) so it sorts to the top of the iTerm2 tab list.
EXTRA_SESSIONS=(_orchestrator)
extra_session_dir() {
  case "$1" in
    _orchestrator) echo "$PARENT" ;;
    *) return 1 ;;
  esac
}

make_agent_windows() {
  local session=$1 dir=$2 n=${3:-$CLAUDES_DEFAULT} i
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "  $session: session already up"
    return 0
  fi
  tmux new-session -d -s "$session" -c "$dir" -n claude
  for ((i = 2; i <= n; i++)); do
    tmux new-window -d -t "$session" -n "claude$i" -c "$dir"
  done
  tmux new-window -d -t "$session" -n shell -c "$dir"
  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$session" >/dev/null 2>&1 || true
  echo "  $session: $(tmux list-windows -t "$session" -F '#{window_name}' | paste -sd' ' -)"
}

# ---- vite ---------------------------------------------------------------------
# config/vite.json pins every checkout to 3036, and only one process can hold a
# port - so whoever starts Vite first serves JavaScript to every other checkout,
# silently, because Rails proxies /vite-dev/* to whatever port it is told. A slot
# therefore needs its own, derived from its Rails port so it cannot collide.
#
# Rails reads this from .env on boot. `bin/vite dev` does NOT - dotenv only loads
# inside Rails - so services.sh passes it on the command line as well.
set_vite_port() {
  local wt=$1 railsport=$2 viteport
  [[ "$railsport" =~ ^[0-9]+$ ]] || return 0
  # Only if this checkout's vite.config.ts honours the variable (PR #769). Against
  # a config that still hardcodes 3036, naming a port here sends Rails to someone
  # else's Vite while this one fails to bind.
  grep -q 'VITE_RUBY_PORT' "$wt/vite.config.ts" 2>/dev/null || return 0
  viteport=$((railsport + 30))          # 3012+ -> 3042+, clear of 3036/3037
  grep -q '^VITE_RUBY_PORT=' "$wt/.env" 2>/dev/null && return 0
  {
    echo ""
    echo "# This checkout's own Vite dev server. Without it every checkout shares"
    echo "# 3036 and the first one to start serves JavaScript to all the others."
    echo "VITE_RUBY_PORT=$viteport"
  } >> "$wt/.env"
  echo "  vite port $viteport (in .env)"
}

# ---- memory -------------------------------------------------------------------
# Claude Code keys its memory directory off the working directory's path, so a new
# slot starts with an empty one and an agent there loses every accumulated lesson.
# The clones already solve this by symlinking to a single canonical store keyed on
# the base clone; slots join the same convention rather than inventing another.
CANONICAL_MEMORY="$HOME/.claude/projects/-Users-daviddeegan-code-dvddgn-advice-innovation-hub/memory"

link_memory() {
  local wt=$1
  [[ -d "$CANONICAL_MEMORY" ]] || { echo "  (no canonical memory store — skipping)"; return 0; }
  # Dots are encoded as dashes too, same as separators.
  local proj="$HOME/.claude/projects/$(echo "$wt" | sed 's|[/.]|-|g')"
  mkdir -p "$proj"
  if [[ -e "$proj/memory" && ! -L "$proj/memory" ]]; then
    echo "  memory: left alone — $proj/memory already exists as a real directory"
    return 0
  fi
  [[ -L "$proj/memory" ]] && rm "$proj/memory"
  ln -s "$CANONICAL_MEMORY" "$proj/memory" \
    && echo "  memory linked ($(ls "$CANONICAL_MEMORY"/*.md 2>/dev/null | wc -l | tr -d ' ') entries)"
}

# ---- new ----------------------------------------------------------------------
# The terminal-profile list - the entries in VS Code's terminal dropdown that drop
# you straight into a slot's tmux session - is GENERATED from the live tmux
# sessions by cs.sh, never written entry by entry, so a slot appearing or
# disappearing leaves the dropdown out of date until something runs `cs snapshot`.
# Do it here rather than leaving it to be noticed later.
#
# A slot no longer earns a FOLDER entry anywhere - it gets its own standalone
# window (write_standalone_ws + code, below) instead of living inside the shared
# aih-worktrees.code-workspace alongside every other slot. That file grew to
# 15+ full worktree roots, and VS Code's git-status polling and file watching
# cost scales with the total size of every root open in one window - a real,
# measured slowdown on git diffs and PR review, not a hypothetical one. Fixed
# 2026-08-30 by giving every active repo (worktrees, m1, claw, workspace-app,
# hre, ...) its own dedicated window and leaving the shared file for genuinely
# lightweight reference-only folders (dotfiles, agent-skills, Claude config,
# Drive folders) that carry none of that cost.
#
# Quiet on purpose. This is a side effect of the command the caller actually asked
# for, and cs.sh prints half a dozen lines about Claude sessions and listening
# servers that would bury the output of that command.
refresh_profiles() {
  [[ -x "$CS" ]] || return 0
  "$CS" snapshot >/dev/null 2>&1 && echo "  terminal profiles refreshed"
}

# Killing a tmux session does NOT close whatever iTerm2 tab was attached to it -
# it leaves a dead plain shell behind for DD to notice and ask about later (see
# the iterm skill's "Known fragility"). $1 is the tty captured via
# `tmux list-clients` BEFORE the session is killed - list-clients returns
# nothing once it's gone, so the caller must capture this first. Silent no-op
# if there was no attached client, or iTerm2 isn't reachable at all - a slot
# torn down from a headless/no-GUI context is not an error.
close_iterm_tab() {
  local tty=$1
  [[ -n "$tty" ]] || return 0
  osascript -e "
  tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of (current session of t)) is \"$tty\" then
            close t
            return \"closed\"
          end if
        end try
      end repeat
    end repeat
  end tell
  " 2>/dev/null | grep -q closed
}

# Closes the slot's standalone window by clicking its own close button - the same
# gesture DD's mouse would perform - NOT a forced/silent close and NOT `quit`.
# That matters because a dirty-tree check only sees changes already written to
# disk; a genuinely unsaved editor buffer (never saved, so git never saw it)
# would otherwise be silently discarded the moment the worktree directory
# vanishes under it. Clicking the real close button lets VS Code raise its own
# "do you want to save?" prompt exactly as if DD had closed it himself, rather
# than bypassing that protection. Matches by the window's own title, same as
# snap_vscode_window - other worktree windows are not this slot's business to
# touch. Silent no-op if Code is not running or the window is not found.
close_vscode_window() {
  local slug=$1
  osascript <<OSA 2>/dev/null | grep -q closed
tell application "System Events"
  if exists (first process whose name is "Code") then
    tell process "Code"
      set targetWins to (windows whose name starts with "wt · $slug")
      repeat with w in targetWins
        click button 1 of w
      end repeat
      if (count of targetWins) > 0 then return "closed"
    end tell
  end if
end tell
OSA
}

# ---- browser workspace ---------------------------------------------------------
# A slot's Chrome window mirrors the standalone VS Code window: a small generated
# page as the front tab so the window is identifiable at a glance (Chrome has no
# real per-window title API, so the front tab's <title> is the closest thing to
# "named like the worktree"), plus whichever of the Workspace project, GitHub and
# the running app actually exist for this slot. *.overview.html lives BESIDE the
# worktree, same as the port/brief/context files - anything inside would show up
# in every `git status`.
write_overview_html() {
  local slug=$1 branch=$2 wt=$3 app_url=$4 project_name=$5 project_url=$6 pr_url=$7
  python3 - "$wt.overview.html" "$slug" "$branch" "$app_url" "$project_name" "$project_url" "$pr_url" <<'PY'
import sys, html
out, slug, branch, app_url, project_name, project_url, pr_url = sys.argv[1:8]
def esc(s): return html.escape(s or "")
cards = []
if project_url:
    cards.append(("Workspace project", project_name or project_url, project_url))
if pr_url:
    cards.append(("GitHub", pr_url, pr_url))
if app_url:
    cards.append(("App", app_url, app_url))
cards_html = "\n".join(
    f'<a class="card" href="{esc(u)}" target="_blank" rel="noopener">'
    f'<span class="label">{esc(l)}</span><span class="value">{esc(v)}</span></a>'
    for l, v, u in cards
) or '<p class="empty">Nothing bound yet - no Workspace project, no PR, no server.</p>'
page = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>wt · {esc(slug)}</title>
<style>
  body {{ font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; background: #0f172a;
          color: #e2e8f0; margin: 0; padding: 40px; }}
  h1 {{ font-size: 20px; margin: 0 0 4px; }}
  .branch {{ color: #7dd3fc; font-family: ui-monospace, monospace; margin: 0 0 28px; }}
  .card {{ display: flex; flex-direction: column; gap: 2px; padding: 14px 16px; margin-bottom: 10px;
           background: #1e293b; border-radius: 8px; text-decoration: none; color: inherit; }}
  .card:hover {{ background: #263449; }}
  .label {{ font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #94a3b8; }}
  .value {{ font-family: ui-monospace, monospace; word-break: break-all; }}
  .empty {{ color: #64748b; }}
  ul {{ padding-left: 18px; color: #cbd5e1; }}
  li {{ margin-bottom: 6px; }}
  code {{ background: #1e293b; padding: 1px 5px; border-radius: 4px; }}
  h2 {{ font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #94a3b8;
        margin: 28px 0 10px; }}
</style></head>
<body>
<h1>wt · {esc(slug)}</h1>
<p class="branch">{esc(branch)}</p>
{cards_html}
<h2>Next steps</h2>
<ul>
  <li>Attach: <code>tmux attach -t wt-{esc(slug)}</code></li>
  <li>Push before handing the branch to Codex or asking for review - a review or the loop only
      sees what is on origin</li>
  <li>Pull explicitly if another agent owns the branch:
      <code>git -C ~/code/dvddgn/aih-wt-{esc(slug)} pull --ff-only</code></li>
  <li>Close out from OUTSIDE the slot once merged: <code>wt done {esc(slug)}</code></li>
</ul>
</body></html>
"""
open(out, "w").write(page)
print(f"  overview page written ({out.split('/')[-1]})")
PY
}

# GitHub and the Workspace project need DD's work identity (david@adviceinnovationhub.com)
# to already be signed in, so the window opens under that Chrome profile rather than
# whatever profile happened to be active. Chrome assigns an opaque directory name
# ("Profile 4", ...) per profile and can renumber them across profile
# additions/removals, so look it up by identity in Local State rather than
# hardcoding the directory - the same "check the capability, don't assume the
# version" reasoning CLAUDE.md documents for tooling that depends on local state.
CHROME_LOCAL_STATE="$HOME/Library/Application Support/Google/Chrome/Local State"
chrome_aih_profile_dir() {
  [[ -f "$CHROME_LOCAL_STATE" ]] || return 1
  python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for key, info in d.get("profile", {}).get("info_cache", {}).items():
    if info.get("user_name") == "david@adviceinnovationhub.com":
        print(key)
        break
' "$CHROME_LOCAL_STATE" 2>/dev/null
}

# `open -n` starts a genuinely new Chrome window rather than adding tabs to
# whichever window is already frontmost; `--new-window` is Chrome's own flag for
# the same thing and matters when Chrome is not yet running at all. Degrades
# silently if Chrome is not installed or `open` fails - a slot must never fail to
# build because a browser did not cooperate.
open_browser_workspace() {
  local overview=$1; shift
  [[ -d "/Applications/Google Chrome.app" ]] || { echo "  (Google Chrome not found - skipping browser workspace)"; return 1; }
  local urls=("file://$overview") u
  for u in "$@"; do [[ -n "$u" ]] && urls+=("$u"); done
  local profile_dir chrome_args=(--new-window)
  profile_dir=$(chrome_aih_profile_dir)
  if [[ -n "$profile_dir" ]]; then
    chrome_args+=(--profile-directory="$profile_dir")
  else
    echo "  (could not find the AIH Chrome profile - opening in whatever profile is active)"
  fi
  if open -na "Google Chrome" --args "${chrome_args[@]}" "${urls[@]}" 2>/dev/null; then
    echo "  browser workspace opened (${#urls[@]} tab$([[ ${#urls[@]} == 1 ]] || echo s))"
    return 0
  else
    echo "  (Chrome would not open - by hand: open -a 'Google Chrome' --args ${chrome_args[*]} ${urls[*]})"
    return 1
  fi
}

cmd_new() {
  local slug="" branch="" project_ref="" claudes=$CLAUDES_DEFAULT start_rails=true open_ui=true monitor=""
  while (($#)); do
    case "$1" in
      --claudes) claudes="${2:?--claudes needs a number}"; shift 2 ;;
      --project) project_ref="${2:?--project needs a Workspace project reference}"; shift 2 ;;
      --monitor) monitor="${2:?--monitor needs a display index}"; shift 2 ;;
      --no-rails) start_rails=false; shift ;;
      --no-ui) open_ui=false; shift ;;
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$slug" ]]; then slug=$1; elif [[ -z "$branch" ]]; then branch=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  [[ -n "$slug" ]] || usage 1
  [[ -z "$monitor" || "$monitor" =~ ^[0-9]+$ ]] || die "--monitor needs a non-negative display index, got '$monitor'"

  # tmux reads dots and colons as window and pane separators, so the slug cannot
  # contain them. DD types this name, so keep it short.
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lowercase letters, digits and hyphens: '$slug'"
  branch="${branch:-feature/$slug}"

  local wt="$BASE/aih-wt-$slug" session="wt-$slug"
  [[ -e "$wt" ]] && die "$wt already exists"
  tmux has-session -t "$session" 2>/dev/null && die "tmux session $session already exists"
  [[ -d "$PARENT" ]] || die "parent clone not found at $PARENT"

  # Resolved once, here, rather than re-resolved later for the browser workspace -
  # resolution is a Supabase round trip and the ref does not change mid-command.
  local project_name="" project_url=""
  if [[ -n "$project_ref" ]]; then
    [[ -x "$TMUX_PROJECT" ]] || die "tmux project helper not found at $TMUX_PROJECT"
    local resolved
    resolved=$("$TMUX_PROJECT" resolve "$project_ref") || die "Workspace project did not resolve: $project_ref"
    project_name=$(sed -n '1p' <<<"$resolved" | sed -E 's/ \([^)]*\)$//')
    project_url=$(sed -n '2p' <<<"$resolved" | sed -E 's/^ *//')
  fi

  echo "Creating slot '$slug' on branch $branch"
  git -C "$PARENT" fetch origin main --quiet

  # An existing branch is checked out; otherwise one is cut from origin/main.
  # A branch can only be checked out in one worktree, which is what stops two
  # agents ending up on the same branch in two trees.
  if git -C "$PARENT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "  local branch $branch"
    git -C "$PARENT" worktree add "$wt" "$branch" --quiet || die "worktree add failed"
  elif git -C "$PARENT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    echo "  tracking origin/$branch"
    git -C "$PARENT" fetch origin "$branch" --quiet
    git -C "$PARENT" worktree add "$wt" --track -b "$branch" "origin/$branch" --quiet || die "worktree add failed"
  else
    echo "  new branch off origin/main"
    git -C "$PARENT" worktree add -b "$branch" "$wt" origin/main --quiet || die "worktree add failed"
  fi

  # The only untracked file the app needs. A slot must not inherit the parent's
  # Sidekiq queue: services.sh allocates and records its own Redis database on
  # first service start. Other shared development settings (notably
  # SECRET_KEY_BASE) stay intact.
  cp "$PARENT/.env" "$wt/.env" \
    && sed -i '' '/^REDIS_URL=/d' "$wt/.env" \
    && echo "  .env copied (Redis allocation deferred)"

  # Copy, never symlink: Vite writes its cache into node_modules/.vite and two
  # worktrees sharing that directory collide. -Rc is APFS copy-on-write, so
  # 300MB of files costs a few MB of real disk.
  if [[ -d "$PARENT/node_modules" ]]; then
    cp -Rc "$PARENT/node_modules" "$wt/node_modules" && echo "  node_modules cloned (copy-on-write)"
  fi

  write_standalone_ws "$slug" "$branch" "$wt"
  link_memory "$wt"

  make_windows "$session" "$wt" "$claudes"
  if [[ -n "$project_ref" ]]; then
    "$TMUX_PROJECT" bind "$session" "$project_ref" \
      || echo "  project status could not be applied; retry with: wt project $slug $project_ref"
  fi
  refresh_profiles

  local urlline port=""
  if $start_rails; then
    "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    sleep 1
    port=$(cat "$wt.port" 2>/dev/null || echo "?")
    echo "  rails starting on port $port"
    urlline="  url       http://localhost:$port"
    set_vite_port "$wt" "$port"
  else
    urlline="  url       no server — start one with: srv $session rails --keep-others"
  fi

  # A slot is interactive by definition - nothing automated creates one (the
  # ai-builder loop works on a branch inside the AIH clone, and this script has no
  # programmatic callers), so there is no "is this for a person?" to decide and no
  # flag to make anyone decide it. Open the window and the tab every time.
  #
  # The asymmetry settles it: opening these when they were not wanted costs
  # closing a window and a tab, while not opening them costs DD a slot he cannot
  # get into and has to know was supposed to be there in order to notice. --no-ui
  # exists for the batch case and for a session with no GUI; it is an escape
  # hatch, not a routine choice.
  #
  # cs.sh degrades rather than failing when iTerm2 is unreachable, and `code` is
  # guarded the same way - a slot must never fail to build because a window
  # manager did not cooperate.
  local uiline
  if $open_ui; then
    echo "  opening the standalone VS Code window and an iTerm2 tab"
    if command -v code >/dev/null 2>&1; then
      if code "$wt/$slug.code-workspace" >/dev/null 2>&1; then
        snap_vscode_window "$slug" "$monitor" \
          && echo "  VS Code window snapped to the right two-thirds (Magnet)${monitor:+ on display $monitor}"
      else
        echo "  (VS Code would not open it - by hand: code $wt/$slug.code-workspace)"
      fi
    else
      echo "  (no 'code' on PATH - by hand: code $wt/$slug.code-workspace)"
    fi
    # cs.sh prints its own by-hand instruction on every unhappy path; the exit
    # code is only read so this summary does not claim a tab that is not there.
    local tab_rc=0
    [[ -x "$CS" ]] && { "$CS" tab "$session"; tab_rc=$?; }
    if [[ $tab_rc -eq 0 ]]; then
      uiline="  window    VS Code window and iTerm2 tab opened — drag the tab left if you want it sorted"
    else
      uiline="  window    VS Code window opened; the iTerm2 tab needs a hand — see the note above"
    fi
  else
    uiline="  window    code $wt/$slug.code-workspace   then: cs tab $session"
  fi

  # Same gate as the VS Code window and iTerm tab, for the same reason - a slot is
  # interactive by definition, so there is nothing for --no-ui to be an alternative
  # to except itself. GitHub is looked up here (not earlier) so the network call
  # only happens when it is actually going to be used.
  local browserline
  if $open_ui; then
    local repo="" pr_url=""
    repo=$(git -C "$wt" remote get-url origin 2>/dev/null \
      | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
    if [[ -n "$repo" ]] && command -v gh >/dev/null 2>&1; then
      # `.[0].url` alone prints the literal string "null" on no match (gh's -q is
      # jq under the hood) - `// empty` is what actually makes this empty.
      pr_url=$(gh pr list --repo "$repo" --head "$branch" --json url -q '.[0].url // empty' 2>/dev/null)
    fi
    # No open PR yet - a ready-to-open compare link beats nothing, and costs
    # nothing extra to build once $repo is known.
    [[ -z "$pr_url" && -n "$repo" ]] && pr_url="https://github.com/$repo/compare/main...$branch?expand=1"

    write_overview_html "$slug" "$branch" "$wt" "${port:+http://localhost:$port}" \
      "$project_name" "$project_url" "$pr_url"
    if open_browser_workspace "$wt.overview.html" "$project_url" "$pr_url" "${port:+http://localhost:$port}"; then
      browserline="  browser   Chrome window opened (overview, project, GitHub, app)"
    else
      browserline="  browser   see the note above — by hand: open $wt.overview.html"
    fi
  else
    browserline="  browser   not opened (--no-ui) — by hand: open $wt.overview.html   (not written either)"
  fi

  # The attach command goes last and unlabelled, on its own line, because it is
  # the one line DD copies. Everything above it is reference.
  cat <<EOF

Slot ready.
  path      $wt
  branch    $branch
$urlline
  agent     tmux send-keys -t $session:claude 'ccp <project-slug>' C-m
  sidekiq   window is idle on purpose — only one Sidekiq may run across all clones
  vite      window is idle too — it binds 3036 exclusively; assets autoBuild without it
$uiline
$browserline

Attach:
  tmux attach -t $session
EOF
}

# ---- rm -----------------------------------------------------------------------
cmd_rm() {
  local slug="" force=false
  while (($#)); do
    case "$1" in
      --force) force=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) slug=$1; shift ;;
    esac
  done
  [[ -n "$slug" ]] || usage 1

  local wt="$BASE/aih-wt-$slug" session="wt-$slug"
  ACTION=rm assert_outside "$wt"
  echo "Removing slot '$slug'"

  if tmux has-session -t "$session" 2>/dev/null; then
    local tty
    tty=$(tmux list-clients -t "$session" -F "#{client_tty}" 2>/dev/null | head -1)
    "$SERVICES" "$session" stop all >/dev/null 2>&1
    sleep 1
    tmux kill-session -t "$session" && echo "  tmux session killed"
    close_iterm_tab "$tty" && echo "  iTerm2 tab closed"
  fi

  # Not nested in the block above - the window's lifetime is not tied to the
  # tmux session's, so this runs even if the session was already gone.
  close_vscode_window "$slug" && echo "  VS Code window closed"

  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" forget "$session" >/dev/null 2>&1 || true

  refresh_profiles
  rm -f "$wt.port" && echo "  port file removed"
  rm -f "$wt.redisdb" && echo "  Redis allocation marker removed"
  # A brief/context file lives BESIDE the worktree so `git worktree remove`
  # cannot take it with the directory - which is also why nothing else ever
  # did. They are small and outside every `git status`, so they accumulate
  # silently: three orphans had built up by 2026-08-30.
  for side in "$wt.brief.md" "$wt.context.md" "$wt.overview.html"; do
    [[ -f "$side" ]] && rm -f "$side" && echo "  $(basename "$side") removed"
  done

  if [[ -d "$wt" ]]; then
    local branch
    branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    if $force; then
      # `--force` still refuses when it cannot clear the directory (a server was
      # writing to log/, node_modules is busy), and it leaves the registration
      # behind while reporting failure. Take the files ourselves: --force has
      # already accepted the loss of anything uncommitted, and `done` checked for
      # unpushed commits before it got here.
      if git -C "$PARENT" worktree remove --force "$wt"; then
        echo "  worktree removed (forced)"
      else
        rm -rf "$wt"
        git -C "$PARENT" worktree prune
        if [[ -d "$wt" ]]; then
          echo "  worktree NOT removed - $wt is still on disk"
        else
          echo "  worktree removed (git left files behind; cleared them)"
        fi
      fi
    else
      git -C "$PARENT" worktree remove "$wt" && echo "  worktree removed" \
        || echo "  worktree NOT removed — uncommitted work? re-run with --force once you have checked"
    fi
    # `done` deletes the branch itself a moment later; only `rm` needs the hint.
    [[ -n "$branch" && "${ACTION:-rm}" != "done" ]] && \
      echo "  branch $branch still exists: git -C $PARENT branch -d $branch"
  fi
}

# ---- done ---------------------------------------------------------------------
# The close-out: verify the branch really is in origin/main, delete it locally and
# on the remote, then tear the slot down. The merge check is the point - `rm` will
# happily bin a slot whose work never landed.
cmd_done() {
  local slug="" force=false
  while (($#)); do
    case "$1" in
      --force) force=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) slug=$1; shift ;;
    esac
  done
  [[ -n "$slug" ]] || usage 1

  local wt="$BASE/aih-wt-$slug" session="wt-$slug"
  ACTION=done assert_outside "$wt"
  [[ -d "$wt" ]] || die "no worktree at $wt"

  local branch
  branch=$(git -C "$wt" branch --show-current) || die "cannot read the branch in $wt"
  echo "Closing out '$slug' ($branch)"

  # Uncommitted or unpushed work is lost with the worktree, so say so before it is.
  if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
    $force || die "uncommitted changes in $wt - commit, stash or re-run with --force"
    echo "  WARNING: discarding uncommitted changes (--force)"
  fi

  git -C "$PARENT" fetch origin main --quiet
  local unpushed
  unpushed=$(git -C "$wt" log --oneline "origin/main..HEAD" 2>/dev/null | wc -l | tr -d ' ')

  # A merge commit or fast-forward leaves the branch an ancestor of main. A squash
  # or rebase merge does not, so fall back to asking GitHub whether a PR landed.
  local merged_via=""
  if git -C "$PARENT" merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
    merged_via="in origin/main"
  elif command -v gh >/dev/null 2>&1; then
    local pr repo
    # `gh repo view` with no --repo infers the repo from the CURRENT DIRECTORY,
    # and `wt done` is required to run from OUTSIDE the slot (assert_outside,
    # above) - so the caller could be sitting anywhere. Ask git directly, via the
    # worktree's own remote (same as cmd_new's PR lookup does), rather than
    # trusting wherever the shell happens to be.
    repo=$(git -C "$wt" remote get-url origin 2>/dev/null \
      | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
    # `.[0].number` alone prints the literal string "null" on no match (gh's -q is
    # jq under the hood), which is truthy to `[[ -n ]]` - so without `// empty` an
    # UNMERGED branch reads as "PR #null (squashed...)" and this refuses nothing.
    # See the same gotcha, caught before it shipped, in cmd_new's PR lookup.
    [[ -n "$repo" ]] && pr=$(gh pr list --repo "$repo" \
           --head "$branch" --state merged --json number -q '.[0].number // empty' 2>/dev/null)
    [[ -n "$pr" ]] && merged_via="PR #$pr (squashed or rebased, so not an ancestor)"
  fi

  if [[ -z "$merged_via" ]]; then
    if $force; then
      echo "  WARNING: $branch is NOT merged - proceeding anyway (--force)"
      [[ "$unpushed" != "0" ]] && echo "  WARNING: $unpushed commit(s) not in origin/main will be lost"
    else
      echo "Error: $branch is not merged into origin/main." >&2
      [[ "$unpushed" != "0" ]] && echo "       It has $unpushed commit(s) that main does not." >&2
      echo "       Merge it first, or use \`wt rm $slug\` to abandon the slot deliberately." >&2
      exit 1
    fi
  else
    echo "  merged: $merged_via"
  fi

  ACTION=done cmd_rm "$slug" --force

  # Branch deletion comes after the worktree is gone - git refuses to delete a
  # branch that is still checked out somewhere.
  if git -C "$PARENT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$PARENT" branch -D "$branch" >/dev/null && echo "  local branch deleted"
  fi
  if git -C "$PARENT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git -C "$PARENT" push origin --delete "$branch" --quiet && echo "  remote branch deleted"
  else
    echo "  remote branch already gone"
  fi

  echo
  # Never claim a clean close-out without looking. A removal that failed prints an
  # error of its own, and a success line underneath it is worse than no line.
  if [[ -d "$wt" ]]; then
    echo "NOT fully closed out: $wt is still on disk ($(du -sh "$wt" 2>/dev/null | cut -f1 | tr -d " "))." >&2
    echo "Everything else for '$slug' is gone. Check what is holding it, then: rm -rf $wt" >&2
    exit 1
  fi
  echo "Closed out. Nothing left for '$slug'."
}

# ---- agent --------------------------------------------------------------------
# Several agents can share one slot as long as none of them edits files - scoping
# and review sessions read code and write to the workspace, so they conflict over
# nothing. This adds another correctly named and correctly placed agent window.
cmd_agent() {
  local slug="" name=""
  while (($#)); do
    case "$1" in
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$slug" ]]; then slug=$1; elif [[ -z "$name" ]]; then name=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  [[ -n "$slug" ]] || die "usage: wt agent <slug> [window-name]"

  # Accept a slot slug (scoping -> wt-scoping) or a session name outright, so this
  # works for the orchestrator and any other long-lived session, not only slots.
  local session=""
  if tmux has-session -t "wt-$slug" 2>/dev/null; then session="wt-$slug"
  elif tmux has-session -t "$slug" 2>/dev/null; then session="$slug"
  else die "no tmux session 'wt-$slug' or '$slug'"; fi

  # Default to the next free claude/claudeN. A name is better when the windows
  # hold different subjects - three windows called claude2/3/4 tell you nothing.
  if [[ -z "$name" ]]; then
    local n=2
    while tmux list-windows -t "$session" -F "#{window_name}" | grep -qx "claude$n"; do n=$((n + 1)); done
    name="claude$n"
  fi
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "window name must be lowercase letters, digits and hyphens"
  tmux list-windows -t "$session" -F "#{window_name}" | grep -qx "$name" && die "window $name already exists in $session"

  # A slot has a known directory; any other session takes its current pane path.
  local wt="$BASE/aih-wt-$slug"
  [[ -d "$wt" ]] || wt=$(tmux display-message -t "$session" -p '#{pane_current_path}' 2>/dev/null)
  [[ -d "$wt" ]] || die "cannot resolve a working directory for $session"

  # Insert after the last agent window so the agents stay together, ahead of the
  # service windows. tmux -a inserts after the target index and renumbers.
  local after
  after=$(tmux list-windows -t "$session" -F "#{window_index} #{window_name}" \
          | awk '$2 ~ /^claude/ {i=$1} END {print i+0}')
  if [[ "$after" -gt 0 ]]; then
    tmux new-window -d -a -t "${session}:${after}" -n "$name" -c "$wt"
  else
    tmux new-window -d -t "$session" -n "$name" -c "$wt"
  fi
  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$session" >/dev/null 2>&1 || true

  echo "Added $name to $session"
  tmux list-windows -t "$session" -F "  #{window_index}: #{window_name}"
  cat <<EOF

  agent   tmux send-keys -t ${session}:${name} 'ccp <project-slug>' C-m

Attach:
  tmux attach -t $session
EOF
}

# ---- rename -------------------------------------------------------------------
# Exploration starts before a project exists, so a slot is often named for an idea
# and then turns into something. This moves the directory, branch, tmux session,
# port file and workspace entry together, so none of them is left describing the
# old thing.
cmd_rename() {
  local old="" new="" branch=""
  while (($#)); do
    case "$1" in
      -*) die "unknown flag $1" ;;
      *) if [[ -z "$old" ]]; then old=$1; elif [[ -z "$new" ]]; then new=$1
         elif [[ -z "$branch" ]]; then branch=$1; else die "unexpected argument $1"; fi; shift ;;
    esac
  done
  [[ -n "$old" && -n "$new" ]] || die "usage: wt rename <old-slug> <new-slug> [new-branch]"
  [[ "$new" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lowercase letters, digits and hyphens: '$new'"

  local owt="$BASE/aih-wt-$old" nwt="$BASE/aih-wt-$new"
  ACTION=rename assert_outside "$owt"
  [[ -d "$owt" ]] || die "no worktree at $owt"
  [[ -e "$nwt" ]] && die "$nwt already exists"
  tmux has-session -t "wt-$new" 2>/dev/null && die "tmux session wt-$new already exists"

  echo "Renaming slot '$old' -> '$new'"

  # git worktree move keeps the administrative link intact. The directory keeps its
  # inode, so a shell sitting inside it survives - its `pwd` reads stale, but the
  # directory is still there. Unlike removal, which leaves it pointing at nothing.
  git -C "$PARENT" worktree move "$owt" "$nwt" || die "worktree move failed"
  echo "  directory moved"

  if [[ -n "$branch" ]]; then
    local current
    current=$(git -C "$nwt" branch --show-current)
    if [[ "$current" != "$branch" ]]; then
      git -C "$PARENT" branch -m "$current" "$branch" && echo "  branch $current -> $branch"
    fi
  fi
  local finalbranch
  finalbranch=$(git -C "$nwt" branch --show-current)

  tmux has-session -t "wt-$old" 2>/dev/null && {
    tmux rename-session -t "wt-$old" "wt-$new" && echo "  tmux session wt-$old -> wt-$new"
  }
  [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" rename "wt-$old" "wt-$new" >/dev/null 2>&1 || true

  [[ -f "$owt.port" ]] && mv "$owt.port" "$nwt.port" && echo "  port file moved"
  [[ -f "$owt.redisdb" ]] && mv "$owt.redisdb" "$nwt.redisdb" && echo "  Redis allocation marker moved"
  # Same reason as the port file: named for the slug, so a rename would strand
  # them under the old one and teardown would no longer find them.
  for ext in brief.md context.md overview.html; do
    [[ -f "$owt.$ext" ]] && mv "$owt.$ext" "$nwt.$ext" && echo "  $ext file moved"
  done
  rm -f "$nwt/$old.code-workspace"
  write_standalone_ws "$new" "$finalbranch" "$nwt"

  refresh_profiles

  cat <<EOF

Renamed.
  path      $nwt
  branch    $finalbranch

A session already running inside the slot keeps working - the directory kept its
inode, so only its \`pwd\` reads stale. Tell it to \`cd $nwt\` when convenient.

Attach:
  tmux attach -t wt-$new
EOF
}

# ---- restore ------------------------------------------------------------------
# tmux does not survive a reboot - there is no resurrect/continuum here, so the
# server dies with every session in it. The worktrees do survive, and so do the
# Claude transcripts (they live in ~/.claude/projects, not in the worktree). So a
# restart loses the sessions and nothing else, and this rebuilds them.
#
# It does NOT resume the agents. Restarting eight of them unasked is expensive and
# usually wrong; it prints the command for each instead, newest session first.
cmd_restore() {
  local start_rails=false slug_filter=""
  while (($#)); do
    case "$1" in
      --rails) start_rails=true; shift ;;
      -*) die "unknown flag $1" ;;
      *) slug_filter=$1; shift ;;
    esac
  done

  local wt slug session found=0 extras=0 extra dir
  for extra in "${EXTRA_SESSIONS[@]}"; do
    [[ -n "$slug_filter" && "$slug_filter" != "$extra" ]] && continue
    dir=$(extra_session_dir "$extra") || continue
    make_agent_windows "$extra" "$dir"
    extras=$((extras + 1))
  done

  shopt -s nullglob
  for wt in "$BASE"/aih-wt-*/; do
    wt="${wt%/}"
    # A directory matching the glob is not necessarily a real worktree - a
    # `git worktree move` whose old path still had an open file (a running
    # rails/sidekiq/vite server's log or pid file) can leave a `.vite`-cache
    # husk behind with no `.git` file, indistinguishable from a real slot by
    # name alone. Cost a real bug: this loop treated four such leftovers from
    # a batch of `wt rename` calls as live slots and stood up bogus tmux
    # sessions for them (found and cleaned up 2026-08-30). `git worktree list`
    # is the only source of truth for what is actually a worktree.
    [[ -e "$wt/.git" ]] || continue
    slug="${wt##*/aih-wt-}"
    [[ -n "$slug_filter" && "$slug" != "$slug_filter" ]] && continue
    found=$((found + 1))
    session="wt-$slug"

    if tmux has-session -t "$session" 2>/dev/null; then
      echo "  $slug: session already up"
    else
      make_windows "$session" "$wt"
      link_memory "$wt" >/dev/null
      $start_rails && "$SERVICES" "$session" start rails --keep-others >/dev/null 2>&1
    fi
    [[ -x "$TMUX_PROJECT" ]] && "$TMUX_PROJECT" apply "$session" >/dev/null 2>&1 || true

    # Backfill for slots created before standalone workspace files existed.
    if [[ ! -f "$wt/$slug.code-workspace" ]]; then
      local rbranch
      rbranch=$(git -C "$wt" branch --show-current 2>/dev/null)
      write_standalone_ws "$slug" "${rbranch:-$slug}" "$wt" >/dev/null
    fi

    # The transcript directory is the working directory path with / replaced by -.
    local proj latest
    proj="$HOME/.claude/projects/$(echo "$wt" | sed 's|/|-|g')"
    latest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
      echo "     resume: cd $wt && cc --resume $(basename "$latest" .jsonl)"
    fi
  done

  [[ "$found" == "0" && "$extras" == "0" ]] && { echo "No slots found."; return 0; }
  [[ "$found" == "0" ]] && return 0
  cat <<EOF

$found slot(s). Sessions rebuilt; agents are not resumed - run a resume line above,
or start fresh with: ccp <project-slug> --opus "<brief>"
EOF
}

# ---- Workspace project --------------------------------------------------------
cmd_project() {
  local slug=${1:-} ref=${2:-}
  [[ -n "$slug" && -n "$ref" ]] || die "usage: wt project <slug> <project-ref|--clear>"
  [[ -x "$TMUX_PROJECT" ]] || die "tmux project helper not found at $TMUX_PROJECT"
  local session=$slug
  if [[ "$session" != wt-* ]]; then
    if tmux has-session -t "$session" 2>/dev/null; then
      : # An explicit live non-worktree session, such as m1.
    elif [[ -d "$BASE/aih-wt-$slug" ]]; then
      session="wt-$slug"
    fi
  fi
  if [[ "$ref" == "--clear" ]]; then
    "$TMUX_PROJECT" clear "$session"
  else
    "$TMUX_PROJECT" bind --force "$session" "$ref"
  fi
}

# ---- ls -----------------------------------------------------------------------
cmd_ls() {
  local wt slug branch port session
  shopt -s nullglob
  for wt in "$BASE"/aih-wt-*/; do
    wt="${wt%/}"
    slug="${wt##*/aih-wt-}"
    branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo '?')
    port=$(cat "$wt.port" 2>/dev/null || echo '-')
    session="wt-$slug"
    tmux has-session -t "$session" 2>/dev/null && session="$session (up)" || session="$session (down)"
    printf '%-14s %-42s %-6s %s\n' "$slug" "$branch" "$port" "$session"
  done
}

# `wt audit` is deliberately NOT part of `cs snapshot`'s exceptions.txt (which runs
# unattended every 30 minutes via launchd). Two reasons: it needs network calls
# (`git fetch`, `gh pr list`) that don't belong in a fast, frequent, offline-safe
# job, and "merged" is a candidate for a human to look at, not a fact a script can
# safely act on - `wt-77` looked exactly like a merge candidate (0 commits ahead of
# main) on 2026-08-31 and was in fact deliberately kept open per its project's
# own up_next note ("wt-77 stays available for future profile-77 work"). Run this
# by hand, or ask an agent to, when doing a periodic worktree cleanup pass - never
# let anything tear a slot down off the back of it without DD confirming per slot.
cmd_audit() {
  local wt slug branch dirty ahead pr_line
  shopt -s nullglob
  echo "Fetching origin/main..."
  git -C "$PARENT" fetch origin main --quiet 2>/dev/null
  printf '%-16s %-46s %-6s %-10s %s\n' "SLUG" "BRANCH" "AHEAD" "DIRTY" "PR STATE"
  for wt in "$BASE"/aih-wt-*/; do
    wt="${wt%/}"
    [[ -e "$wt/.git" ]] || continue
    slug="${wt##*/aih-wt-}"
    branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo '?')
    ahead=$(git -C "$wt" rev-list --count "origin/main..$branch" 2>/dev/null || echo '?')
    dirty=$(git -C "$wt" status --short 2>/dev/null | wc -l | tr -d ' ')
    [[ "$dirty" == "0" ]] && dirty="clean" || dirty="$dirty file(s)"
    pr_line=$(cd "$wt" && gh pr list --head "$branch" --state all --json number,state,mergedAt 2>/dev/null \
      | python3 -c "
import json,sys
try:
  d = json.load(sys.stdin)
except Exception:
  d = []
if not d:
  print('no PR')
else:
  p = d[0]
  state = 'MERGED' if p.get('mergedAt') else p['state']
  print(f\"#{p['number']} {state}\")
" 2>/dev/null)
    [[ -z "$pr_line" ]] && pr_line="? (gh error)"
    printf '%-16s %-46s %-6s %-10s %s\n' "$slug" "$branch" "$ahead" "$dirty" "$pr_line"
  done
  echo
  echo "AHEAD=0 + MERGED/no-PR is a candidate to review for 'wt done <slug>' - check the"
  echo "slug's Workspace project up_next first, it may be deliberately kept open."
  echo "DIRTY != clean means uncommitted work sits in that slot - commit or stash it"
  echo "before any teardown, or it will be lost."
}

case "${1:-}" in
  new)    shift; cmd_new "$@" ;;
  agent)  shift; cmd_agent "$@" ;;
  project) shift; cmd_project "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  done)   shift; cmd_done "$@" ;;
  rename) shift; cmd_rename "$@" ;;
  rm)     shift; cmd_rm "$@" ;;
  ls)     shift; cmd_ls "$@" ;;
  audit)  shift; cmd_audit "$@" ;;
  ""|-h|--help) usage ;;
  *) die "unknown command '$1' (use new, agent, project, restore, done, rename, rm, ls or audit)" ;;
esac
