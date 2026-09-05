#!/bin/zsh
#
# Tests the `backup` and `symlink` helpers in install.sh against a throwaway
# $HOME. The helpers are extracted from install.sh itself rather than copied,
# so this test cannot drift away from the code it is testing.
#
#   ./test/install-helpers-test.sh
#
# The case that motivated it: mac-setup section 14 clones `dvddgn/claude-config`
# into ~/.claude, and that repo tracks statusline-command.sh as a symlink into
# `dotfiles`. Until `dotfiles` is cloned (section 24) that link is broken, and
# the old `symlink` helper announced a link it then failed to create.

set -u
SCRIPT_DIR=${0:a:h}
REPO_DIR=${SCRIPT_DIR:h}

# Extract the two helpers from install.sh and define them here.
eval "$(awk '/^(backup|symlink)\(\) \{/,/^\}/' "$REPO_DIR/install.sh")"
if ! typeset -f backup > /dev/null || ! typeset -f symlink > /dev/null; then
  echo "FAIL: could not extract backup/symlink from $REPO_DIR/install.sh"
  exit 1
fi

pass=0
fail=0
ok()   { pass=$((pass+1)); echo "  ok   - $1" }
nope() { fail=$((fail+1)); echo "  FAIL - $1" }
check() { if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (expected '$3', got '$2')"; fi }

FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"' EXIT
SRC="$FAKE_HOME/dotfiles/claude/statusline-command.sh"
mkdir -p "$FAKE_HOME/dotfiles/claude"
echo '#!/bin/bash' > "$SRC"

# --- 1. no link present -> created --------------------------------------------
echo "1. no link present"
L="$FAKE_HOME/case1/statusline-command.sh"; mkdir -p "${L:h}"
out=$(symlink "$SRC" "$L")
check "link is created"                "$(readlink "$L")" "$SRC"
check "link resolves to a real file"   "$([ -f "$L" ] && echo yes || echo no)" "yes"
check "it says so"                     "$(print -r -- "$out" | grep -c 'Symlinking your new')" "1"

# --- 2. correct link present -> left alone ------------------------------------
echo "2. correct link already present"
L="$FAKE_HOME/case2/statusline-command.sh"; mkdir -p "${L:h}"
ln -s "$SRC" "$L"
before=$(stat -f %m%i "$L")
out=$(symlink "$SRC" "$L")
check "still points at the source"     "$(readlink "$L")" "$SRC"
check "link untouched (mtime + inode)" "$(stat -f %m%i "$L")" "$before"
check "says nothing"                   "$out" ""

# --- 3. BROKEN link at the dotfiles path -> replaced --------------------------
# This is the claude-config case: the link text is already what we want, but the
# target did not exist when the link was made.
echo "3. broken link pointing at the dotfiles path (the claude-config case)"
L="$FAKE_HOME/case3/statusline-command.sh"; mkdir -p "${L:h}"
MISSING="$FAKE_HOME/not-cloned-yet/claude/statusline-command.sh"
ln -s "$MISSING" "$L"
check "precondition: link is broken"   "$([ -L "$L" ] && [ ! -e "$L" ] && echo yes || echo no)" "yes"
out=$(symlink "$SRC" "$L")
check "link now points at the source"  "$(readlink "$L")" "$SRC"
check "and resolves to a real file"    "$([ -f "$L" ] && echo yes || echo no)" "yes"
check "it says it replaced it"         "$(print -r -- "$out" | grep -c 'Replacing the broken symlink')" "1"

# --- 4. valid link to a third location -> left alone, with a message ----------
echo "4. valid link to somewhere else"
L="$FAKE_HOME/case4/statusline-command.sh"; mkdir -p "${L:h}"
OTHER="$FAKE_HOME/elsewhere.sh"; echo 'deliberate' > "$OTHER"
ln -s "$OTHER" "$L"
out=$(symlink "$SRC" "$L")
check "deliberate link is not clobbered" "$(readlink "$L")" "$OTHER"
check "and it says why"                  "$(print -r -- "$out" | grep -c 'leaving it alone')" "1"

# --- 5. real file present -> backup() moves it, symlink() then links ----------
echo "5. real file present (existing backup+symlink behaviour)"
L="$FAKE_HOME/case5/statusline-command.sh"; mkdir -p "${L:h}"
echo 'hand-copied' > "$L"
backup "$L" > /dev/null
symlink "$SRC" "$L" > /dev/null
check "old file kept as .backup"       "$(cat "$L.backup")" "hand-copied"
check "link created over it"           "$(readlink "$L")" "$SRC"

# --- 6. backup() still ignores symlinks --------------------------------------
echo "6. backup() leaves symlinks alone (unchanged behaviour)"
L="$FAKE_HOME/case6/statusline-command.sh"; mkdir -p "${L:h}"
ln -s "$SRC" "$L"
backup "$L" > /dev/null
check "no .backup was made"            "$([ -e "$L.backup" ] && echo yes || echo no)" "no"
check "link untouched"                 "$(readlink "$L")" "$SRC"

# --- 7. same file reached by a different path spelling -> left alone ---------
echo "7. link text differs but resolves to the same file"
L="$FAKE_HOME/case7/statusline-command.sh"; mkdir -p "${L:h}"
ALIAS="$FAKE_HOME/dotfiles/claude/../claude/statusline-command.sh"
ln -s "$ALIAS" "$L"
out=$(symlink "$SRC" "$L")
check "not relinked"                   "$(readlink "$L")" "$ALIAS"
check "and not warned about"           "$out" ""

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
