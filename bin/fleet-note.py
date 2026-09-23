#!/usr/bin/env python3
"""fleet-note.py - regenerate the "All Sessions Reference" Notion page from live tmux.

DD uses that page for one thing: seeing which sessions are open so he can triage.
So it is generated, never hand-written. Every run overwrites the page wholesale.

What it reads, all of it live:
  tmux list-windows -a          session / window / pane inventory
  ~/.claude/status/sessions.txt agent session name per tmux session (cs snapshot)
  tmux capture-pane             each session's model, context %, and recap bullets

The recap bullets are the point. `recap` is what a session writes for DD to read at
a glance - "what he cannot already see" - so surfacing them per session IS the triage
view. Nothing here is editorial.

Usage:
  fleet-note.py              regenerate and push to Notion
  fleet-note.py --dry-run    print the markdown, push nothing
  fleet-note.py --page <id>  override the target page

Anything that must outlive a session does NOT belong on this page - it belongs on a
workspace project. The next run deletes it.
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime, timezone, timedelta

PAGE_ID = os.environ.get("FLEET_NOTE_PAGE", "3d2c82ec-26a6-81f1-8104-da87c42e0777")
NOTION = os.path.expanduser("~/.openclaw/workspace/scripts/notion.py")
SESSIONS_TXT = os.path.expanduser("~/.claude/status/sessions.txt")
BANGKOK = timezone(timedelta(hours=7))

# A pane running an agent reports its version as the command (2.1.263, …) for
# Claude Code, or node for a Cursor/Codex wrapper. A bare shell is zsh/bash.
AGENT_CMD = re.compile(r"^(\d+\.\d+\.\d+|node)$")


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return ""


def tmux_inventory():
    fmt = "#{session_name}|#{window_index}|#{window_name}|#{pane_current_command}|#{pane_current_path}"
    out = sh("tmux", "list-windows", "-a", "-F", fmt)
    rows = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) == 5:
            rows.append(dict(zip(("session", "idx", "window", "cmd", "path"), parts)))
    return rows


def session_names():
    """tmux session -> agent session name, from the cs snapshot."""
    names = {}
    if not os.path.exists(SESSIONS_TXT):
        return names
    for line in open(SESSIONS_TXT).read().splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3:
            names[parts[0].split(":")[0]] = " ".join(parts[2:])
    return names


def pane_facts(target):
    """Model, context %, and recap bullets, read from the pane's own status footer.

    The footer is the reliable instrument: if it is drawn, an agent is running.
    pane_current_command is not - a wrapper reports bash/zsh while the agent lives.
    """
    text = sh("tmux", "capture-pane", "-t", target, "-p")
    model, pct, recap = None, None, []
    for line in text.splitlines():
        s = line.strip()
        m = re.search(r"\b(Opus [\d.]+|Sonnet [\d.]+|Fable [\d.]+|Haiku [\d.]+)\b", s)
        if m and not model:
            model = m.group(1)
        m = re.search(r"\b(Cursor Grok [\d.]+ \w+|Grok [\d.]+ \w+|GPT-[\d.]+\S*)", s)
        if m and not model:
            model = m.group(1)
        m = re.search(r"(\d+(?:\.\d+)?)%\s*(used)?", s)
        if m and pct is None and ("used" in s or "·" in s):
            pct = m.group(1)
        if s.startswith("▸"):
            recap.append(s.lstrip("▸ ").strip())
    return model, pct, recap


def classify(session):
    if session == "_orchestrator":
        return "orchestrator"
    if session.startswith("agent-"):
        return "agent"
    if session.startswith(("wt-", "wsw-")):
        return "worktree"
    if session.startswith(("ops-", "prj-")):
        return "standing"
    return "repo"


def build():
    rows = tmux_inventory()
    names = session_names()
    sessions = {}
    for r in rows:
        sessions.setdefault(r["session"], []).append(r)

    agents_running = sum(1 for r in rows if AGENT_CMD.match(r["cmd"]))
    now = datetime.now(BANGKOK).strftime("%-d %b %Y, %H:%M")

    out = []
    out.append(
        "_Generated %s (Bangkok) by `fleet-note.py` from live tmux. "
        "**Do not hand-edit** - the next run overwrites the whole page. "
        "Anything that must outlive a session belongs on a workspace project, not here._"
        % now
    )
    out.append("**%d sessions · %d windows · %d running an agent**"
               % (len(sessions), len(rows), agents_running))

    groups = {}
    for s in sessions:
        groups.setdefault(classify(s), []).append(s)

    # ---- agents: one heading each, with their recap ----
    agents = sorted(groups.get("agent", []))
    if agents:
        out.append("## Agents (%d)" % len(agents))
        for s in agents:
            win = sessions[s][0]
            model, pct, recap = pane_facts("%s:%s" % (s, win["idx"]))
            head = s
            bits = [b for b in (model, pct and pct + "%") if b]
            if bits:
                head += " - " + " · ".join(bits)
            out.append("### " + head)
            for line in recap or ["_no recap set_"]:
                out.append("- " + line)
            named = names.get(s)
            tail = "`%s`" % win["path"].replace(os.path.expanduser("~"), "~")
            if named and named != s.replace("agent-", ""):
                tail += " · session `%s`" % named
            out.append("- " + tail)

    # ---- worktree slots ----
    wts = sorted(groups.get("worktree", []))
    if wts:
        out.append("## Worktree slots (%d)" % len(wts))
        for s in wts:
            wins = sessions[s]
            model, pct, recap = pane_facts("%s:%s" % (s, wins[0]["idx"]))
            svc = [w["window"] for w in wins if w["cmd"] in ("ruby", "node")]
            head = "%s - %d windows" % (s, len(wins))
            if model:
                head += " · %s%s" % (model, pct and " " + pct + "%" or "")
            out.append("### " + head)
            if names.get(s):
                out.append("- session `%s`" % names[s])
            out.append("- up: %s" % (", ".join(svc) if svc else "no services running"))
            for line in recap[:4]:
                out.append("- " + line)

    # ---- everything else, one line each ----
    for key, title in (("repo", "Repo environments"),
                       ("standing", "Standing personal"),
                       ("orchestrator", "Orchestrator")):
        members = sorted(groups.get(key, []))
        if not members:
            continue
        out.append("## %s (%d)" % (title, len(members)))
        for s in members:
            wins = sessions[s]
            # Window names in these sessions are often the agent's version string
            # ("2.1.263") or "[tmux]", which tells DD nothing. Report liveness instead.
            running = sum(1 for w in wins if AGENT_CMD.match(w["cmd"]))
            state = ("agent running" if running == 1
                     else "%d agents" % running if running else "idle")
            out.append("- `%s` - %d window%s · %s"
                       % (s, len(wins), "" if len(wins) == 1 else "s", state))

    out.append("---")
    out.append("_Open one from whichever Mac you are on: `rcs tab <session>`, "
               "or `rcs --all tab <session>` for a worktree slot._")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--page", default=PAGE_ID)
    args = ap.parse_args()

    md = build()
    if args.dry_run:
        print(md)
        return 0

    p = subprocess.run([sys.executable, NOTION, "replace", args.page, "--content", md],
                       capture_output=True, text=True,
                       cwd=os.path.expanduser("~/.openclaw/workspace"))
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
