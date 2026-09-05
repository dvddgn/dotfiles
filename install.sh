#!/bin/zsh

# Define a function which rename a `target` file to `target.backup` if the file
# exists and if it's a 'real' file, ie not a symlink
backup() {
  target=$1
  if [ -e "$target" ]; then
    if [ ! -L "$target" ]; then
      mv "$target" "$target.backup"
      echo "-----> Moved your old $target config file to $target.backup"
    fi
  fi
}

# Define a function which symlinks `file` to `link`.
#
# A pre-existing symlink at `link` needs care. `[ ! -e "$link" ]` follows the
# link, so it is *true* for a broken one - the old shape announced the symlink
# and then `ln -s` failed with "File exists", leaving a link pointing nowhere
# and an exit status of 0. That is exactly what a fresh machine hits: the
# `claude-config` clone (mac-setup section 14) brings its own symlink to
# `dotfiles/claude/statusline-command.sh`, which is broken until `dotfiles`
# itself is cloned. So: replace a broken link, leave a correct one alone, and
# never clobber a working link that points somewhere else deliberately.
symlink() {
  file=$1
  link=$2
  if [ -L "$link" ]; then
    current=`readlink "$link"`
    if [ ! -e "$link" ]; then
      echo "-----> Replacing the broken symlink at $link (pointed at $current)"
      rm -f "$link"
      ln -s "$file" "$link"
    elif [ "$current" = "$file" ] || [ "$link" -ef "$file" ]; then
      : # already points where we want it - nothing to do
    else
      echo "-----> $link is a symlink to $current, not $file - leaving it alone"
    fi
  elif [ ! -e "$link" ]; then
    echo "-----> Symlinking your new $link"
    ln -s "$file" "$link"
  fi
}

# For all files `$name` in the present folder except `*.sh`, `README.md`, `settings.json`,
# and `config`, backup the target file located at `~/.$name` and symlink `$name` to `~/.$name`
for name in aliases gitconfig irbrc pryrc rspec zprofile zshrc; do
  if [ ! -d "$name" ]; then
    target="$HOME/.$name"
    backup $target
    symlink $PWD/$name $target
  fi
done

# Symlink the dev scripts in `bin/` back into ~/code/dvddgn, where the shell
# aliases and the scripts themselves reference them by that path. Tracking them
# here is what backs them up; the symlinks are what keep every existing
# reference working.
DEV_BIN="$HOME/code/dvddgn"
if [ -d "$DEV_BIN" ]; then
  for name in bin/*.sh; do
    target="$DEV_BIN/$(basename $name)"
    backup $target
    symlink $PWD/$name $target
  done
fi

# Symlink the extension-less scripts in `bin/` into ~/bin, which is what is on
# PATH for them. `recap`, `mdopen`, `diffopen` and `codeopen` are typed as bare
# commands, unlike the `*.sh` dev scripts above, which are referenced by path.
USER_BIN="$HOME/bin"
mkdir -p "$USER_BIN"
for name in bin/*; do
  case "$name" in
    *.sh) continue ;;
  esac
  if [ ! -d "$name" ]; then
    target="$USER_BIN/$(basename $name)"
    backup $target
    symlink $PWD/$name $target
  fi
done

# Install the Claude Code statusline. The renderer is versioned here and gets
# symlinked like everything else; the `statusLine` key that points Claude Code
# at it lives in ~/.claude/settings.json, which is NOT symlinked - that file
# also carries machine-specific plugins and permissions, so the key is added to
# it in place, and only when it is absent.
CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
STATUSLINE_KEY='"statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }'
mkdir -p "$CLAUDE_DIR"
chmod +x $PWD/claude/statusline-command.sh
target="$CLAUDE_DIR/statusline-command.sh"
backup $target
symlink $PWD/claude/statusline-command.sh $target

if ! command -v jq > /dev/null 2>&1; then
  echo "-----> jq is not installed, so $CLAUDE_SETTINGS was left alone."
  echo "       Add this key to it by hand to switch the statusline on:"
  echo "         $STATUSLINE_KEY"
elif [ ! -e "$CLAUDE_SETTINGS" ]; then
  echo "-----> Creating $CLAUDE_SETTINGS with the statusLine key"
  echo "{ $STATUSLINE_KEY }" | jq . > "$CLAUDE_SETTINGS"
elif ! jq empty "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
  echo "-----> $CLAUDE_SETTINGS is not valid JSON, so it was left alone."
  echo "       Add this key to it by hand to switch the statusline on:"
  echo "         $STATUSLINE_KEY"
elif [ "$(jq -r 'has("statusLine")' "$CLAUDE_SETTINGS")" = "true" ]; then
  echo "-----> $CLAUDE_SETTINGS already has a statusLine key, leaving it alone"
else
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.backup"
  echo "-----> Copied your old $CLAUDE_SETTINGS to $CLAUDE_SETTINGS.backup"
  if jq '. + { statusLine: { type: "command", command: "bash ~/.claude/statusline-command.sh" } }' \
       "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" \
     && jq empty "$CLAUDE_SETTINGS.tmp" > /dev/null 2>&1; then
    mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
    echo "-----> Added the statusLine key to $CLAUDE_SETTINGS"
  else
    rm -f "$CLAUDE_SETTINGS.tmp"
    echo "-----> Could not add the statusLine key to $CLAUDE_SETTINGS."
    echo "       Add it by hand to switch the statusline on:"
    echo "         $STATUSLINE_KEY"
  fi
fi

# Install zsh-syntax-highlighting plugin
CURRENT_DIR=`pwd`
ZSH_PLUGINS_DIR="$HOME/.oh-my-zsh/custom/plugins"
mkdir -p "$ZSH_PLUGINS_DIR" && cd "$ZSH_PLUGINS_DIR"
if [ ! -d "$ZSH_PLUGINS_DIR/zsh-syntax-highlighting" ]; then
  echo "-----> Installing zsh plugin 'zsh-syntax-highlighting'..."
  git clone https://github.com/zsh-users/zsh-autosuggestions
  git clone https://github.com/zsh-users/zsh-syntax-highlighting
fi
cd "$CURRENT_DIR"

# Symlink VS Code settings and keybindings to the present `settings.json` and `keybindings.json` files
# If it's a macOS
if [[ `uname` =~ "Darwin" ]]; then
  CODE_PATH=~/Library/Application\ Support/Code/User
# Else, it's a Linux
else
  CODE_PATH=~/.config/Code/User
  # If this folder doesn't exist, it's a WSL
  if [ ! -e $CODE_PATH ]; then
    CODE_PATH=~/.vscode-server/data/Machine
  fi
fi

for name in settings.json keybindings.json; do
  target="$CODE_PATH/$name"
  backup $target
  symlink $PWD/$name $target
done

# Symlink SSH config file to the present `config` file for macOS and add SSH passphrase to the keychain
if [[ `uname` =~ "Darwin" ]]; then
  target=~/.ssh/config
  backup $target
  symlink $PWD/config $target
  ssh-add --apple-use-keychain ~/.ssh/id_ed25519
fi

# Refresh the current terminal with the newly installed configuration
exec zsh

echo "👌 Carry on with git setup!"
