#!/bin/bash
# Status line based on oh-my-bash "vscode" theme PS1,
# plus model, context usage, and rate limits
input=$(cat)
IFS=$'\x1f' read -r cwd model ctx_used ctx_size ctx_pct h5_pct h5_reset d7_pct d7_reset sp_pct sp_reset < <(
  echo "$input" | jq -r '[
    (.workspace.current_dir // .cwd),
    (.model.display_name // ""),
    (.context_window.total_input_tokens // ""),
    (.context_window.context_window_size // ""),
    (.context_window.used_percentage // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.rate_limits.spend_limit.used_percentage // ""),
    (.rate_limits.spend_limit.resets_at // "")
  ] | map(tostring) | join("\u001f")')

user=$(whoami)
dir="$cwd"
case "$dir" in "$HOME"*) dir="~${dir#$HOME}";; esac

# 12345 -> 12.3k, 1000000 -> 1M
fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) { s = sprintf("%.1f", n/1000000); sub(/\.0$/, "", s); print s "M" }
    else if (n >= 1000) { s = sprintf("%.1f", n/1000); sub(/\.0$/, "", s); print s "k" }
    else print n
  }'
}

# Color a percentage: green < 50, yellow < 80, red otherwise
pct_color() {
  local p=${1%.*}
  if [ "${p:-0}" -ge 80 ]; then printf '\033[1;31m'
  elif [ "${p:-0}" -ge 50 ]; then printf '\033[0;33m'
  else printf '\033[0;32m'; fi
}

# Seconds until an epoch time -> "2h13m" / "3d4h" / "45m"
until_reset() {
  local s=$(( $1 - $(date +%s) ))
  [ "$s" -le 0 ] && return
  if [ "$s" -ge 86400 ]; then printf '%dd%dh' $((s/86400)) $((s%86400/3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh%dm' $((s/3600)) $((s%3600/60))
  else printf '%dm' $((s/60)); fi
}

rate() {  # label pct reset
  [ -z "$2" ] && return
  printf ' \033[0;90m│\033[0m %s ' "$1"
  pct_color "$2"; printf '%.0f%%\033[0m' "$2"
  if [ -n "$3" ]; then
    local r; r=$(until_reset "${3%.*}")
    [ -n "$r" ] && printf ' \033[0;90m↻%s\033[0m' "$r"
  fi
}

# PS1 part
branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
printf '\033[0;32m%s \033[0m➜ \033[1;34m%s' "$user" "$dir"
if [ -n "$branch" ]; then
  printf ' \033[0;36m(\033[1;31m%s' "$branch"
  if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | head -n1)" ]; then
    printf ' \033[1;33m✗'
  fi
  printf '\033[0;36m)'
fi
printf '\033[0m'

# Model
[ -n "$model" ] && printf ' \033[0;90m│\033[0m \033[0;35m%s\033[0m' "$model"

# Context: used/size (pct)
if [ -n "$ctx_size" ]; then
  printf ' \033[0;90m│\033[0m ctx %s/%s' "$(fmt_tokens "${ctx_used:-0}")" "$(fmt_tokens "$ctx_size")"
  if [ -n "$ctx_pct" ]; then
    printf ' ('; pct_color "$ctx_pct"; printf '%.0f%%\033[0m)' "$ctx_pct"
  fi
fi

# Rate limits (only present for Pro/Max after first API response)
rate 5h "$h5_pct" "$h5_reset"
rate 7d "$d7_pct" "$d7_reset"
rate spend "$sp_pct" "$sp_reset"
