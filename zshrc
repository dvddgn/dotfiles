# To reload the file run
# source ~/.zshrc
# or just open a new terminal window

ZSH=$HOME/.oh-my-zsh

# You can change the theme with another one from https://github.com/robbyrussell/oh-my-zsh/wiki/themes
ZSH_THEME="robbyrussell"

# Useful oh-my-zsh plugins for Le Wagon bootcamps
# Base plugins
plugins=(git gitfast last-working-dir common-aliases history-substring-search ssh-agent)

# Add zsh-syntax-highlighting if it exists
if [[ -d "${ZSH}/custom/plugins/zsh-syntax-highlighting" ]] || [[ -d "${ZSH}/plugins/zsh-syntax-highlighting" ]]; then
    plugins+=(zsh-syntax-highlighting)
fi

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
# Start PostgreSQL if available (skip in Docker containers)
if [[ ! -f /.dockerenv ]] && [[ -z "${DEVCONTAINER}" ]]; then
    # Only attempt to start PostgreSQL if not in a container
    if command -v psql &> /dev/null || command -v postgres &> /dev/null; then
        if [[ -f /etc/init.d/postgresql ]]; then
            sudo /etc/init.d/postgresql start 2>/dev/null
        elif command -v service &> /dev/null; then
            sudo service postgresql start 2>/dev/null
        elif command -v systemctl &> /dev/null; then
            sudo systemctl start postgresql 2>/dev/null
        fi
    fi
fi
export PATH="$PATH:/snap/bin"
export DISPLAY=:0
export DISPLAY=:0
export WAYLAND_DISPLAY=""
export XDG_RUNTIME_DIR="/tmp"

# Created by `pipx` on 2025-07-27 15:31:25
export PATH="$PATH:/home/deegan/.local/bin"

# OS-specific editor aliases
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - VS Code CLI is installed via "Shell Command: Install 'code' command in PATH"
    # No aliases needed - the native `code` command will work
    :
elif [[ -n "$WSL_DISTRO_NAME" ]]; then
    # WSL - use Windows paths
    alias code="/mnt/c/Users/david/AppData/Local/Programs/Microsoft\ VS\ Code/bin/code"
    alias code-insiders="/mnt/c/Users/david/AppData/Local/Programs/Microsoft\ VS\ Code\ Insiders/bin/code-insiders"
    alias cursor="/mnt/c/Users/david/AppData/Local/Programs/cursor/resources/app/bin/code"
fi

# Claude aliases
alias cc="claude --dangerously-skip-permissions"
alias ccc="claude --dangerously-skip-permissions --continue"
alias cx="codex --dangerously-bypass-approvals-and-sandbox"

# Start tmux sessions + open VS Code (per repo)
# up m1                → start m1 session + open VS Code
# up m1 m2 ws          → multiple
# up m1 --no-code      → tmux only, no VS Code
alias up="~/code/dvddgn/startup.sh"

# Open a project in tmux with Claude Code + context
alias op="~/code/dvddgn/workspace-app/ai-builder/scripts/open-project.sh"

# List all named Claude Code sessions across all folders
alias sess="~/code/dvddgn/workspace-app/ai-builder/scripts/sessions.sh"

# Create or attach a tmux session — use to spin up isolated tmux per VS Code terminal
# cct                → auto-named session (sess-HHMMSS)
# cct my-feature     → create or attach to "my-feature"
cct() {
  local name="${1:-sess-$(date +%H%M%S)}"
  tmux new-session -A -s "$name"
}

# Open VS Code workspace by session name
vs() {
  local base="$HOME/code/dvddgn"
  case "$1" in
    aih)  code "$base/advice-innovation-hub/aih.code-workspace" ;;
    c[1-5]) code "$base/advice-innovation-hub-clone-${1#c}/${1}.code-workspace" ;;
    m1|m2) code "$base/advice-innovation-hub-${1}/${1}.code-workspace" ;;
    ws)   code "$base/workspace-app/ws.code-workspace" ;;
    claw) code "$HOME/.openclaw/workspace/claw.code-workspace" ;;
    *)    echo "Usage: vs <aih|c1-c5|m1|m2|ws|claw>" ;;
  esac
}

# Dev services (start/stop/restart rails/sidekiq/vite in tmux)
# srv m1              → restart all
# srv m1 rails        → restart just rails
# srv stop m1         → stop all
# srv stop m1 vite    → stop just vite
srv() {
  if [[ "$1" == "stop" ]]; then
    ~/code/dvddgn/services.sh "${2:?Usage: srv stop <session> [service]}" stop "${3:-all}"
  elif [[ "$1" == "start" ]]; then
    ~/code/dvddgn/services.sh "${2:?Usage: srv start <session> [service]}" start "${3:-all}"
  else
    ~/code/dvddgn/services.sh "${1:?Usage: srv <session> [service]}" restart "${2:-all}"
  fi
}

# Script shortcuts for Advice Innovation Hub
alias sshs='ssh -i ~/.ssh/aih-staging-key.pem ec2-user@16.176.107.106' # Staging
alias sshp='ssh -i ~/.ssh/aih-production-key.pem ec2-user@54.66.154.73' # Production
alias ds='kamal deploy -d staging'
alias dp='kamal deploy -d production'
alias stops='/workspaces/advice-innovation-hub/scripts/aws/stop-staging.sh'
alias starts='/workspaces/advice-innovation-hub/scripts/aws/start-staging.sh'
alias statuss='/workspaces/advice-innovation-hub/scripts/aws/status-staging.sh'
alias logsp='kamal app logs -d production -f'
alias logss='kamal app logs -d staging -f'
alias logs50p='kamal app logs -d production --lines 50'
alias logs50s='kamal app logs -d staging --lines 50'
alias logs100p='kamal app logs -d production --lines 100'
alias logs100s='kamal app logs -d staging --lines 100'

alias todo='cd ~/.openclaw/workspace && python3 scripts/tasks-overview.py'

. "$HOME/.local/bin/env"
export PATH="$HOME/Library/Python/3.14/bin:$PATH"
export PATH="$HOME/bin:$PATH"
alias fav="$HOME/.openclaw/workspace/scripts/fav"

# Claude Code Project — start/resume sessions with project context
alias ccp="bash ~/code/dvddgn/workspace-app/ai-builder/scripts/ccp.sh"
