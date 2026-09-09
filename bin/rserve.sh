#!/bin/bash
# rserve.sh — expose a worktree slot's dev server to the tailnet, so a browser on another
# machine can reach it.
#
# Rails, Vite and Next dev servers all bind 127.0.0.1 only (services.sh runs
# `bin/rails server -p PORT` with no -b), so a laptop pointed at this Mac's tailnet address
# gets connection-refused even though Tailscale routes there fine. `tailscale serve --tcp`
# proxies from the tailnet interface to loopback, which needs no change to how any server
# is started, no -b 0.0.0.0 (which would also expose it to the LAN), and no sudo.
#
# Raw TCP rather than --http on purpose: it forwards bytes untouched, so websockets (Vite
# HMR, ActionCable) work and the browser's Host header stays the IP. That matters — Rails'
# development host allowlist accepts any IP but NOT a .ts.net name, so browsing to the
# MagicDNS name would hit "Blocked hosts" while the IP just works.
#
# Usage:
#   rserve <slug>            # expose that slot's Rails port (reads <worktree>.port)
#   rserve <slug> --vite     # also expose its Vite port (Rails port + 30)
#   rserve <port>            # expose a port directly
#   rserve ls                # what is currently exposed
#   rserve off               # stop exposing everything
#
# Slots are AIH (aih-wt-<slug>, ports from 3012) or workspace-app (workspace-app-wt-<slug>,
# from 3100). The port lives BESIDE the worktree in <dir>.port so it never shows up as an
# untracked file — same convention services.sh uses.

set -uo pipefail
CODE="$HOME/code/dvddgn"
die() { echo "Error: $*" >&2; exit 1; }

ts() {
  local c
  for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale \
           /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  die "tailscale CLI not found"
}
TS=$(ts) || exit 1

expose() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ ]] || die "not a port: $port"
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "warning: nothing is listening on $port yet — exposing anyway, start the server and it will work" >&2
  fi
  "$TS" serve --bg --tcp "$port" "tcp://localhost:$port" >/dev/null || die "tailscale serve failed for $port"
  echo "  http://$("$TS" ip -4 2>/dev/null | head -1):$port"
}

slot_port() {
  local slug=$1 f
  for f in "$CODE/aih-wt-$slug.port" "$CODE/workspace-app-wt-$slug.port"; do
    [[ -f "$f" ]] && { cat "$f"; return 0; }
  done
  return 1
}

case "${1:-ls}" in
  ls|"")
    "$TS" serve status 2>&1 | sed 's/^/  /' ;;
  off)
    "$TS" serve reset && echo "  all tailnet exposure removed" ;;
  *)
    arg=$1; shift
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
      echo "Exposed:"; expose "$arg"
    else
      port=$(slot_port "$arg") \
        || die "no .port file for slot '$arg'. Is it created, and has its server been started once? (wt ls / wsw ls)"
      echo "Exposed for slot '$arg':"
      expose "$port"
      [[ "${1:-}" == "--vite" ]] && expose "$((port + 30))"
    fi
    echo
    echo "Open that on the other machine. Use the IP, not the .ts.net name —"
    echo "Rails' dev host allowlist accepts IPs but not .ts.net, and would show 'Blocked hosts'."
    ;;
esac
