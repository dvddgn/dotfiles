ZSH=$HOME/.oh-my-zsh

# You can change the theme with another one from https://github.com/robbyrussell/oh-my-zsh/wiki/themes
ZSH_THEME="robbyrussell"

# Useful oh-my-zsh plugins for Le Wagon bootcamps
plugins=(git gitfast last-working-dir common-aliases zsh-syntax-highlighting history-substring-search ssh-agent)

# (macOS-only) Prevent Homebrew from reporting - https://github.com/Homebrew/brew/blob/master/docs/Analytics.md
export HOMEBREW_NO_ANALYTICS=1

# Disable warning about insecure completion-dependent directories
ZSH_DISABLE_COMPFIX=true

# Actually load Oh-My-Zsh
source "${ZSH}/oh-my-zsh.sh"
unalias rm # No interactive rm by default (brought by plugins/common-aliases)
unalias lt # we need `lt` for https://github.com/localtunnel/localtunnel

# Load rbenv if installed (to manage your Ruby versions)
export PATH="${HOME}/.rbenv/bin:${PATH}" # Needed for Linux/WSL
type -a rbenv > /dev/null && eval "$(rbenv init -)"

# Load pyenv (to manage your Python versions)
export PYENV_VIRTUALENV_DISABLE_PROMPT=1
type -a pyenv > /dev/null && eval "$(pyenv init -)" && eval "$(pyenv virtualenv-init - 2> /dev/null)" && RPROMPT+='[🐍 $(pyenv version-name)]'

# Load nvm (to manage your node versions)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# Call `nvm use` automatically in a directory with a `.nvmrc` file
autoload -U add-zsh-hook
load-nvmrc() {
  if nvm -v &> /dev/null; then
    local node_version="$(nvm version)"
    local nvmrc_path="$(nvm_find_nvmrc)"

    if [ -n "$nvmrc_path" ]; then
      local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

      if [ "$nvmrc_node_version" = "N/A" ]; then
        nvm install
      elif [ "$nvmrc_node_version" != "$node_version" ]; then
        nvm use --silent
      fi
    elif [ "$node_version" != "$(nvm version default)" ]; then
      nvm use default --silent
    fi
  fi
}
type -a nvm > /dev/null && add-zsh-hook chpwd load-nvmrc
type -a nvm > /dev/null && load-nvmrc

# Rails and Ruby uses the local `bin` folder to store binstubs.
# So instead of running `bin/rails` like the doc says, just run `rails`
# Same for `./node_modules/.bin` and nodejs
export PATH="./bin:./node_modules/.bin:${PATH}:/usr/local/sbin"

# Store your own aliases in the ~/.aliases file and load the here.
[[ -f "$HOME/.aliases" ]] && source "$HOME/.aliases"

# Encoding stuff for the terminal
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

export BUNDLER_EDITOR=code
export EDITOR=code

# Set ipdb as the default Python debugger
export PYTHONBREAKPOINT=ipdb.set_trace
# Start PostgreSQL if available
if [ -f /etc/init.d/postgresql ]; then
    sudo /etc/init.d/postgresql start
fi
export PATH="$PATH:/snap/bin"
export DISPLAY=:0
export DISPLAY=:0
export WAYLAND_DISPLAY=""
export XDG_RUNTIME_DIR="/tmp"

# Aliases for opening editors
alias code="/mnt/c/Users/david/AppData/Local/Programs/Microsoft\ VS\ Code/bin/code"
alias code-insiders="/mnt/c/Users/david/AppData/Local/Programs/Microsoft\ VS\ Code\ Insiders/bin/code-insiders"
alias cursor="/mnt/c/Users/david/AppData/Local/Programs/cursor/resources/app/bin/code"

# Create worktrees

# Remove any existing alias
unalias create-worktree 2>/dev/null

# Usage: create-worktree <feature-name>
# Example: create-worktree user-authentication
create-worktree() {
    if [ $# -eq 0 ]; then
        echo "Usage: create-worktree <feature-name>"
        return 1
    fi

    # Get the current repo name from the directory
    REPO_NAME=$(basename $(git rev-parse --show-toplevel))
    FEATURE_NAME=$1
    BRANCH_NAME="feature/$FEATURE_NAME"
    WORKTREE_DIR="../${REPO_NAME}-$FEATURE_NAME"
    ORIGINAL_DIR=$(pwd)

    echo "🌳 Creating worktree for: $FEATURE_NAME in $REPO_NAME"
    git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" || return 1

    cd "$WORKTREE_DIR"

    # Check what type of project it is and run appropriate commands
    if [ -f "Gemfile" ]; then
        echo "📦 Ruby project detected - running bundle install"
        bundle install
    fi

    if [ -f "package.json" ]; then
        echo "📦 Node project detected - running npm install"
        npm install
    fi

    if [ -f "bin/rails" ]; then
        echo "🗄️  Rails project detected - running migrations"
        bin/rails db:migrate
        bin/rails db:seed
    fi

    cursor .

    cd "$ORIGINAL_DIR"
    echo "✅ Complete! Worktree created at $WORKTREE_DIR"
}

# Cleanup worktrees

# Remove any existing alias
unalias cleanup-worktree 2>/dev/null

# Usage: cleanup-worktree <feature-name>
# Example: cleanup-worktree user-authentication
cleanup-worktree() {
    if [ $# -eq 0 ]; then
        echo "Usage: cleanup-worktree <feature-name>"
        return 1
    fi

    # Get the current repo name from the directory
    REPO_NAME=$(basename $(git rev-parse --show-toplevel))
    FEATURE_NAME=$1
    WORKTREE_DIR="../${REPO_NAME}-$FEATURE_NAME"

    git worktree remove "$WORKTREE_DIR"
    echo "✅ Removed worktree: $WORKTREE_DIR"
}

# Created by `pipx` on 2025-07-27 15:31:25
export PATH="$PATH:/home/deegan/.local/bin"
export PATH=$PATH:~/.local/bin

# Claude aliases
alias cc="claude --dangerously-skip-permissions"
alias ccc="claude --dangerously-skip-permissions --continue"
