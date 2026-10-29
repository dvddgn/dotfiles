#!/bin/bash
# install-rc-server.sh - install (or reinstall) the com.dvddgn.rc-server LaunchAgent on this Mac,
# then run it once so a broken install shows up now. Home Mac only: it is the machine that stays
# on. The job itself is bin/ensure-rc-server.sh.
#
# First run of `claude rc` on a machine asks "Enable Remote Control? (y/n)" once, and in a new
# folder asks for a spawn mode. Answer those by hand first (`pt rc-server`); a detached session
# would otherwise sit at the prompt.

set -euo pipefail
LABEL=com.dvddgn.rc-server
SRC="$HOME/code/dvddgn/dotfiles/launchd/$LABEL.plist"
DST="$HOME/Library/LaunchAgents/$LABEL.plist"

chmod 755 "$HOME/code/dvddgn/dotfiles/bin/ensure-rc-server.sh"
plutil -lint "$SRC" >/dev/null
command cp -f "$SRC" "$DST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed $LABEL - first run started; log: ~/Library/Logs/rc-server.log"
