#!/bin/bash
# install-auto-sync.sh - install (or reinstall) the hourly com.dvddgn.auto-sync LaunchAgent on
# this Mac, then run it once so a broken install shows up now rather than in an hour.
# The job itself is `sync.sh --auto`; see the --auto section of bin/sync.sh.
#
# A LaunchAgent rather than cron: writing the crontab from an agent session hangs on a TCC
# prompt nobody sees (~/.claude/CLAUDE.md, "crontab writes HANG").

set -euo pipefail
LABEL=com.dvddgn.auto-sync
SRC="$HOME/code/dvddgn/dotfiles/launchd/$LABEL.plist"
DST="$HOME/Library/LaunchAgents/$LABEL.plist"

plutil -lint "$SRC" >/dev/null
command cp -f "$SRC" "$DST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed $LABEL - first run started; log: ~/Library/Logs/auto-sync.log"
