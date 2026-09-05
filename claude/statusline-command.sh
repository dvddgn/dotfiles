#!/usr/bin/env bash
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
session_name=$(echo "$input" | jq -r '.session_name // ""')
session_id=$(echo "$input" | jq -r '.session_id // ""')

# Shorten home directory to ~
short_dir="${cwd/#$HOME/~}"

# Truncate long paths: keep last 2 path segments, prefix with ...
# e.g. ~/foo/bar/baz/qux → .../baz/qux
path_depth=$(echo "$short_dir" | tr -cd '/' | wc -c | tr -d ' ')
if [ "$path_depth" -gt 3 ]; then
  seg1=$(echo "$short_dir" | rev | cut -d'/' -f2 | rev)
  seg2=$(echo "$short_dir" | rev | cut -d'/' -f1 | rev)
  short_dir=".../${seg1}/${seg2}"
fi

# Git branch
git_branch=""
if git -C "$cwd" rev-parse --git-dir --no-optional-locks &>/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# Context bar - 20 chars wide
bar_width=20
filled=$(( used * bar_width / 100 ))
empty=$(( bar_width - filled ))

# Color: green <50%, yellow 50-79%, red 80%+
if [ "$used" -ge 80 ]; then
  bar_color="\033[31m"  # red
elif [ "$used" -ge 50 ]; then
  bar_color="\033[33m"  # yellow
else
  bar_color="\033[32m"  # green
fi

bar="${bar_color}"
for ((i=0; i<filled; i++)); do bar+="█"; done
for ((i=0; i<empty; i++)); do bar+="░"; done
bar+="\033[0m"

# Line 1: path
printf "\033[36m%s\033[0m\n" "$short_dir"

# Line 2: session name (if set) - truncate to prevent wrapping
if [ -n "$session_name" ]; then
  if [ ${#session_name} -gt 50 ]; then
    session_name="${session_name:0:47}..."
  fi
  printf "\033[33m%s\033[0m\n" "$session_name"
fi

# Line 2: git branch  ·  model
line3=""
if [ -n "$git_branch" ]; then
  line3+="\033[35m${git_branch}\033[0m  \033[90m·\033[0m  "
fi
line3+="\033[90m${model}\033[0m"
printf "%b\n" "$line3"

# Line 4: context bar
printf "%b \033[90m%s%% used\033[0m\n" "$bar" "$used"

# Recap bullets - set by `recap` (~/bin/recap), keyed to this session.
# Falls back to a directory-scoped recap when the session has none of its own.
recap_file="$HOME/.claude/recap/${session_id}.txt"
if [ ! -s "$recap_file" ]; then
  recap_file="$HOME/.claude/recap/dir$(printf '%s' "$cwd" | sed 's|/|-|g').txt"
fi
if [ -s "$recap_file" ]; then
  while IFS= read -r bullet || [ -n "$bullet" ]; do
    [ -n "$bullet" ] || continue
    if [ ${#bullet} -gt 72 ]; then bullet="${bullet:0:69}..."; fi
    printf "\033[90m  \xe2\x96\xb8\033[0m \033[37m%s\033[0m\n" "$bullet"
  done < <(head -5 "$recap_file")
fi
