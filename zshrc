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


# List all named Claude Code sessions across all folders
alias sess="~/code/dvddgn/workspace-app/ai-builder/scripts/sessions.sh"

# Create or attach a tmux session — use to spin up isolated tmux per VS Code terminal
# cct                                      → auto-named session (sess-HHMMSS)
# cct my-feature                           → create or attach to "my-feature"
# cct my-feature --project project:<slug>  → bind a Workspace project first
cct() {
  local name="" project_ref=""
  while (($#)); do
    case "$1" in
      --project) project_ref="${2:?--project needs a Workspace project reference}"; shift 2 ;;
      -*) echo "Unknown cct flag: $1" >&2; return 1 ;;
      *) [[ -z "$name" ]] && name=$1 || { echo "Unexpected cct argument: $1" >&2; return 1; }; shift ;;
    esac
  done
  name="${name:-sess-$(date +%H%M%S)}"
  if ! tmux has-session -t "$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$PWD" || return
  fi
  local helper="$HOME/code/dvddgn/dotfiles/bin/tmux-project.sh"
  if [[ -n "$project_ref" ]]; then
    "$helper" bind "$name" "$project_ref" || return
  elif [[ -x "$helper" ]]; then
    "$helper" apply "$name" >/dev/null 2>&1
  fi
  tmux attach-session -t "$name"
}

# Attach to a tmux session from a phone (or any small screen) without shrinking the
# same session's desktop iTerm2 tabs.
#
# tmux's `window-size` is `latest` (the stock default, and what this setup uses): the
# client with the most recent activity sets the window size, so a plain `tmux attach`
# from a phone reflows every desktop tab showing that session. `-f ignore-size` takes
# this client out of that calculation entirely, so the desktop is untouched and the
# phone just sees the top-left of a too-big window. `-f active-pane` gives the phone its
# own active pane, so moving around on it doesn't move the desktop's cursor.
#
# Deliberately NOT fixed with a global `window-size largest` in ~/.tmux.conf: that would
# crop whichever desktop client is the smaller of two attached to the same session (the
# `aih` session routinely has a 90-col and a 115-col client at once).
#
#   pt          → list sessions
#   pt m1       → attach to m1, phone-safe
#
# Already attached and forgot? `tmux refresh-client -f ignore-size,active-pane`.
pt() {
  # Delegates to bin/tattach.sh so that typing `pt` by hand and rcs's on-connect
  # command make the SAME sizing decision. The flags are not unconditional: see the
  # comment block in that script for why attaching alone must NOT use ignore-size.
  "$HOME/code/dvddgn/dotfiles/bin/tattach.sh" "$@"
}

# Already attached and the window is stranded at a size smaller than this terminal?
# (Symptom: content fills only the top-left of the window, dead space around it.) That
# happens when the only client is an ignore-size one, so tmux has no client to size from.
# `fit` resizes the CURRENT window to this client. It refuses when others are attached,
# because growing the window there is exactly the reflow ignore-size exists to prevent.
fit() {
  [[ -n "${TMUX:-}" ]] || { echo "fit: not inside tmux" >&2; return 1; }
  local sess win others cw ch rows
  sess=$(tmux display -p '#{session_name}')
  win=$(tmux display -p '#{session_name}:#{window_index}')
  others=$(tmux list-clients -t "$sess" -F '#{client_flags}' | grep -cv 'ignore-size')
  if [[ "${others:-0}" -gt 0 && "${1:-}" != "-f" ]]; then
    echo "fit: $others other client(s) on '$sess' would be reflowed. Re-run 'fit -f' to do it anyway." >&2
    return 1
  fi
  cw=$(tmux display -p '#{client_width}')
  ch=$(tmux display -p '#{client_height}')
  rows=$(tmux show-options -t "$sess" -v status 2>/dev/null); [[ "$rows" =~ ^[0-9]+$ ]] || rows=1
  tmux resize-window -t "$win" -x "$cw" -y "$((ch - rows))" || return 1
  tmux set-window-option -t "$win" -u window-size 2>/dev/null   # back to automatic
  echo "fit: $win -> ${cw}x$((ch - rows))"
}

# Open VS Code workspace by session name
vs() {
  local base="$HOME/code/dvddgn"
  case "$1" in
    aih)  code "$base/advice-innovation-hub/aih.code-workspace" ;;
    c[1-5]) code "$base/advice-innovation-hub-clone-${1#c}/${1}.code-workspace" ;;
    m[1-5]) code "$base/advice-innovation-hub-${1}/${1}.code-workspace" ;;
    wt)   code "$base/aih-worktrees.code-workspace" ;;
    ws)   code "$base/workspace-app/ws.code-workspace" ;;
    hre)  code "$base/horizons-real-estate/hre.code-workspace" ;;
    claw) code "$HOME/.openclaw/workspace/claw.code-workspace" ;;
    .)
      # For a worktree slot's own shell window, where you're already sitting in
      # its directory and just want its standalone workspace without typing the
      # slug - `wt new`/`wt rename` always leave exactly one *.code-workspace
      # file at the worktree root.
      local -a found=(*.code-workspace(N))
      case ${#found[@]} in
        0) echo "No *.code-workspace file in $(pwd) - not a worktree root?" ;;
        1) code "${found[1]}" ;;
        *) echo "Multiple *.code-workspace files here, pick one: ${found[*]}" ;;
      esac
      ;;
    *)    echo "Usage: vs <aih|c1-c5|m1-m5|wt|ws|hre|claw|.>" ;;
  esac
}

# Worktree slots (worktree + .env + node_modules + own standalone VS Code window + tmux windows)
# wt new <slug> [branch] [--claudes N] [--no-rails] | wt rm <slug> | wt ls
alias wt="~/code/dvddgn/wt.sh"

# The same idea for workspace-app, and deliberately much smaller - no Rails,
# no Sidekiq, no Vite, no services.sh. Sessions are wsw-<slug>, NOT wt-<slug>:
# that namespace is AIH's and cs.sh classifies it as an AIH slot.
# wsw new <slug> [branch] [--no-dev] | wsw rm <slug> | wsw ls | wsw restore
alias wsw="~/code/dvddgn/wsw.sh"

# Claude sessions for a directory, labelled: cs | cs -g email | cs r 3
alias cs="~/code/dvddgn/cs.sh"

# The same tab layout, but for the HOME Mac's tmux sessions reached over Tailscale SSH —
# so the portable Mac gets the familiar Work/Personal window pair with one named tab per
# session. `rcs` lists, `rcs iterm` builds the layout, `rcs tab <session>` opens one.
# On the home Mac itself it refuses with an explanation rather than trying to SSH to
# itself — including when run inside an SSH session, where the shell IS the home Mac's.
alias rcs="~/code/dvddgn/dotfiles/bin/rcs.sh"

# Expose a worktree slot's dev server to the tailnet, so a browser on the laptop can reach
# a Rails/Next server running here. Rails binds 127.0.0.1 only, so Tailscale routing alone
# is not enough — `tailscale serve --tcp` bridges the tailnet interface to loopback.
#   rserve tsdemo        rserve tsdemo --vite       rserve 3012
#   rserve ls            rserve off
alias rserve="~/code/dvddgn/dotfiles/bin/rserve.sh"

# remote — print the copy-paste commands for reaching something on this Mac from the laptop
# or phone. Runs here; prints commands to run THERE. Added 2026-09-10: every capability
# already existed (ssh, rcs, rserve, VS Code Remote-SSH, vnc) but nothing assembled them
# into a handoff, so each one was reconstructed by hand and usually incompletely.
#   remote               list connectable sessions and slots
#   remote tsdemo        a worktree slot: app URL, VS Code workspace, its tmux session
#   remote remote-aih    a tmux session: its windows, and two ways to attach
alias remote="~/code/dvddgn/dotfiles/bin/remote.sh"

# Dev services (start/stop/restart rails/sidekiq/vite in tmux)
# srv m1              → restart all
# srv m1 rails        → restart just rails
# srv stop m1         → stop all
# srv stop m1 vite    → stop just vite
# Other checkouts are left alone by default; --take stops the same service
# elsewhere first, which is only needed for a checkout that still shares a port.
srv() {
  # Trailing flags (e.g. --take) are passed through to services.sh.
  if [[ "$1" == "stop" ]]; then
    local sess="${2:?Usage: srv stop <session> [service] [--keep-others]}"
    local svc="${3:-all}"; shift 3 2>/dev/null
    ~/code/dvddgn/services.sh "$sess" stop "$svc" "$@"
  elif [[ "$1" == "start" ]]; then
    local sess="${2:?Usage: srv start <session> [service] [--keep-others]}"
    local svc="${3:-all}"; shift 3 2>/dev/null
    ~/code/dvddgn/services.sh "$sess" start "$svc" "$@"
  else
    local sess="${1:?Usage: srv <session> [service] [--keep-others]}"
    local svc="${2:-all}"
    # Handle the case where $2 is a flag, not a service name
    if [[ "$svc" == --* ]]; then svc="all"; shift 1; else shift 2 2>/dev/null; fi
    ~/code/dvddgn/services.sh "$sess" restart "$svc" "$@"
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

[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"
export PATH="$HOME/Library/Python/3.14/bin:$PATH"
export PATH="$HOME/bin:$PATH"
alias fav="$HOME/.openclaw/workspace/scripts/fav"

# Claude Code Project — start/resume sessions with project context
alias ccp="bash ~/code/dvddgn/workspace-app/ai-builder/scripts/ccp.sh"
alias tmux-project="$HOME/code/dvddgn/dotfiles/bin/tmux-project.sh"

# Per-machine overrides (not tracked - PATH entries, machine-specific aliases)
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
