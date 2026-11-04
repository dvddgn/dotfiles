#!/bin/zsh
#
# Tests that bin/sync.sh skips a shared checkout that is off its default branch, in both
# `sync --auto` and manual `sync`, against a throwaway $HOME with local bare remotes.
#
#   ./test/sync-off-default-test.sh
#
# The case that motivated it: on 2026-11-03 ~/.claude/skills (the agent-skills checkout) sat on
# feature/artifacts-on-boards-and-notebooks for 44 minutes. That branch had an upstream and an
# open PR, so an hourly `sync --auto` in that window would have committed every loose file onto
# it and pushed them into the PR.

set -u
SCRIPT_DIR=${0:a:h}
SYNC=${SCRIPT_DIR:h}/bin/sync.sh

pass=0
fail=0
ok()   { pass=$((pass+1)); echo "  ok   - $1" }
nope() { fail=$((fail+1)); echo "  FAIL - $1" }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else nope "$1 (no '$3' in output)"; echo "$2" | sed 's/^/         /'; fi }
hasnt() { if grep -qF -- "$3" <<<"$2"; then nope "$1 ('$3' in output)"; echo "$2" | sed 's/^/         /'; else ok "$1"; fi }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
mkdir -p $HOME/code/dvddgn $T/bin $T/remotes
git config --file $GIT_CONFIG_GLOBAL user.name test
git config --file $GIT_CONFIG_GLOBAL user.email test@example.com
git config --file $GIT_CONFIG_GLOBAL init.defaultBranch main
# No desktop notifications from a test run.
printf '#!/bin/sh\nexit 0\n' > $T/bin/osascript; chmod +x $T/bin/osascript
export PATH=$T/bin:$PATH
# --auto requires a live ssh-agent socket; any unix socket satisfies the check.
python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" $T/agent.sock
export SSH_AUTH_SOCK=$T/agent.sock

# Each repo: a bare remote whose default branch is main, and a clone of it at the real path.
for name in claude agent-skills dotfiles; do
  git init -q --bare $T/remotes/$name.git
  git clone -q $T/remotes/$name.git $T/seed-$name 2>/dev/null
  git -C $T/seed-$name commit -q --allow-empty -m init
  git -C $T/seed-$name push -q origin HEAD:main
done
git clone -q $T/remotes/claude.git $HOME/.claude
git clone -q $T/remotes/agent-skills.git $HOME/code/dvddgn/agent-skills
git clone -q $T/remotes/dotfiles.git $HOME/code/dvddgn/dotfiles
echo status/ > $HOME/.claude/.gitignore
git -C $HOME/.claude add .gitignore && git -C $HOME/.claude commit -q -m ignore && git -C $HOME/.claude push -q
SK=$HOME/code/dvddgn/agent-skills
MARKER=$HOME/.claude/status/auto-sync-failure.txt

echo "1. everything on its default branch"
out=$(bash $SYNC --auto 2>&1)
has   "--auto reports ok" "$out" "  ok"
[[ ! -e $MARKER ]] && ok "no failure marker" || nope "failure marker written"

echo "2. agent-skills on a feature branch with an upstream, and a loose file"
git -C $SK switch -q -c feature/x
git -C $SK commit -q --allow-empty -m "feature work"
git -C $SK push -q -u origin feature/x 2>/dev/null
before=$(git --git-dir=$T/remotes/agent-skills.git rev-parse feature/x)
echo stray > $SK/stray.txt
out=$(bash $SYNC --auto 2>&1)
has   "--auto names the branch" "$out" "agent-skills: on feature/x, not main"
[[ -s $MARKER ]] && grep -qF "on feature/x" $MARKER && ok "marker names it (statusline goes red)" || nope "marker missing or wrong"
[[ -n "$(git -C $SK status --porcelain -- stray.txt)" ]] && ok "stray file left uncommitted" || nope "stray file was committed"
after=$(git --git-dir=$T/remotes/agent-skills.git rev-parse feature/x)
[[ "$before" == "$after" ]] && ok "nothing pushed to feature/x" || nope "feature/x moved on the remote"
has   "the other repos still sync" "$out" "~/.claude: pulled"

echo "3. manual sync while off the default branch"
out=$(bash $SYNC 2>&1); rc=$?
has   "manual sync names the branch" "$out" "on feature/x, not main"
[[ $rc -ne 0 ]] && ok "manual sync exits non-zero" || nope "manual sync exited 0"

echo "4. detached HEAD"
git -C $SK switch -q --detach main
out=$(bash $SYNC --auto 2>&1)
has   "detached HEAD is skipped" "$out" "on a detached HEAD, not main"

echo "5. no origin/HEAD: falls back to origin/main rather than switching the guard off"
git -C $SK switch -q feature/x
git -C $SK remote set-head origin -d
out=$(bash $SYNC --auto 2>&1)
has   "still skipped with no origin/HEAD" "$out" "on feature/x, not main"

echo "6. back on main"
rm $SK/stray.txt
git -C $SK switch -q main
out=$(bash $SYNC --auto 2>&1)
has   "--auto reports ok" "$out" "  ok"
[[ ! -e $MARKER ]] && ok "failure marker cleared" || nope "failure marker still there"
hasnt "no warning" "$out" "not main"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
