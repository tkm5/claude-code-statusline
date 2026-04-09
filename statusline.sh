#!/bin/bash

set -euo pipefail

command -v jq &>/dev/null || { echo "Missing: jq"; exit 1; }

# ─── Config ───

OAUTH_CACHE="/tmp/oauth-usage-cache.json"
OAUTH_TTL=60
CCUSAGE_CACHE="/tmp/ccusage-cache.json"
CCUSAGE_TTL=300
TOKEN_LIMIT=43000000

# ─── ANSI Colors (using $'...' for real escape bytes) ───

C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_ORANGE=$'\033[1;38;5;208m'
C_RED=$'\033[1;31m'
C_CYAN=$'\033[36m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'

_rate_color() {
  local pct_int="$1"
  if [ "$pct_int" -lt 20 ]; then echo -n "$C_GREEN"
  elif [ "$pct_int" -lt 40 ]; then echo -n "$C_YELLOW"
  elif [ "$pct_int" -lt 60 ]; then echo -n "$C_ORANGE"
  else echo -n "$C_RED"
  fi
}

# ─── Parse Claude input (single jq call) ───

claude_input=$(cat)
IFS='|' read -r model_name cwd ctx_remaining <<< \
  "$(echo "$claude_input" | jq -r '[
    (.model.display_name // ""),
    (.cwd // ""),
    (.context_window.remaining_percentage // 100 | tostring)
  ] | join("|")')"

# Compact cwd: ~/first_char/.../last_dir
_compact_cwd() {
  local tilde="~"
  local p="${1/#$HOME/$tilde}"
  # 3 segments or fewer (e.g. ~/src/foo) — show as-is
  local depth
  depth=$(echo "$p" | tr -cd '/' | wc -c | tr -d ' ')
  if [ "$depth" -le 2 ]; then
    echo -n "$p"
    return
  fi
  # ~/first_char/.../last_dir
  local first last
  first=$(echo "$p" | cut -d'/' -f1-2 | sed 's|/\(.\).*|/\1|')
  last=$(basename "$p")
  echo -n "${first}/.../${last}"
}
cwd_str="${C_CYAN}$(_compact_cwd "$cwd")${C_RESET}"


# Separator: dim pipe (space after reset to prevent ANSI bleed)
SEP="${C_DIM} │${C_RESET} "

# ─── OAuth Usage API ───

_get_access_token() {
  local raw
  raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
  [ -z "$raw" ] && return 1

  local json
  if [[ "$raw" == "{"* ]]; then
    json="$raw"
  else
    json=$(echo "$raw" | xxd -r -p 2>/dev/null) || return 1
  fi

  echo "$json" \
    | grep -o '"accessToken":"[^"]*"' \
    | head -1 \
    | sed 's/"accessToken":"//;s/"$//'
}

_fetch_oauth_usage() {
  local access_token
  access_token=$(_get_access_token) || return 1
  [ -z "$access_token" ] && return 1

  curl --silent --max-time 5 \
    --header "Authorization: Bearer ${access_token}" \
    --header "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
}

_oauth_cache_fresh() {
  [ -f "$OAUTH_CACHE" ] || return 1
  local now mtime
  now=$(date +%s)
  mtime=$(stat -f "%m" "$OAUTH_CACHE" 2>/dev/null) \
    || mtime=$(stat -c "%Y" "$OAUTH_CACHE" 2>/dev/null) \
    || return 1
  [ $((now - mtime)) -lt "$OAUTH_TTL" ]
}

_iso8601_to_epoch() {
  local ts="$1"
  local stripped
  stripped=$(echo "$ts" | sed 's/\.[0-9]*//')
  local normalized="${stripped/+00:00/+0000}"
  normalized="${normalized/Z/+0000}"
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$normalized" "+%s" 2>/dev/null \
    || date -d "$stripped" "+%s" 2>/dev/null \
    || echo ""
}

_build_oauth_rate_str() {
  [ -f "$OAUTH_CACHE" ] || return 1

  local five_util resets_at
  IFS='|' read -r five_util resets_at <<< \
    "$(jq -r '[
      (.five_hour.utilization // ""),
      (.five_hour.resets_at // "")
    ] | join("|")' "$OAUTH_CACHE" 2>/dev/null || echo "|")"

  [ -z "$five_util" ] && return 1

  local usage_pct usage_int color
  usage_pct=$(awk "BEGIN { printf \"%.1f\", ${five_util} }")
  usage_int=${usage_pct%%.*}
  color=$(_rate_color "$usage_int")

  local rate_time=""
  if [ -n "$resets_at" ]; then
    local reset_epoch now_epoch diff_sec
    reset_epoch=$(_iso8601_to_epoch "$resets_at")
    now_epoch=$(date +%s)
    if [ -n "$reset_epoch" ] && [ "$reset_epoch" -gt "$now_epoch" ]; then
      diff_sec=$((reset_epoch - now_epoch))
      local h=$((diff_sec / 3600))
      local m=$(((diff_sec % 3600) / 60))
      rate_time=" ${C_DIM}(${h}h ${m}m)${C_RESET}"
    fi
  fi

  local seven_util seven_str=""
  seven_util=$(jq -r '.seven_day.utilization // ""' "$OAUTH_CACHE" 2>/dev/null || echo "")
  if [ -n "$seven_util" ]; then
    local seven_usage seven_int seven_color
    seven_usage=$(awk "BEGIN { printf \"%.1f\", ${seven_util} }")
    seven_int=${seven_usage%%.*}
    seven_color=$(_rate_color "$seven_int")
    seven_str="${SEP}${C_DIM}7d${C_RESET} ${seven_color}${seven_usage}%${C_RESET}"
  fi

  echo -n "${color}${usage_pct}%${C_RESET}${rate_time}${seven_str}"
}

# ─── Rate limit remaining (OAuth API with ccusage fallback) ───

session_str_rate=""

if [ "${CLAUDE_CODE_USE_BEDROCK:-0}" = "0" ]; then
  if _oauth_cache_fresh; then
    session_str_rate=$(_build_oauth_rate_str 2>/dev/null || echo "")
  else
    if [ -f "$OAUTH_CACHE" ]; then
      session_str_rate=$(_build_oauth_rate_str 2>/dev/null || echo "")
    fi
    (
      result=$(_fetch_oauth_usage 2>/dev/null) || exit 0
      echo "$result" | jq -e '.five_hour' &>/dev/null || exit 0
      echo "$result" > "${OAUTH_CACHE}.tmp" \
        && mv "${OAUTH_CACHE}.tmp" "$OAUTH_CACHE"
    ) & disown 2>/dev/null
  fi

  # Fallback to ccusage if OAuth produced no output
  if [ -z "$session_str_rate" ] && command -v ccusage &>/dev/null; then
    cache_age_ok=false
    if [ -f "$CCUSAGE_CACHE" ]; then
      now=$(date +%s)
      mtime=$(stat -f "%m" "$CCUSAGE_CACHE" 2>/dev/null) \
        || mtime=$(stat -c "%Y" "$CCUSAGE_CACHE" 2>/dev/null) \
        || mtime=0
      has_data=$(jq -r '.blocks | length > 0' "$CCUSAGE_CACHE" 2>/dev/null || echo "false")
      local_ttl=$CCUSAGE_TTL
      [ "$has_data" = "true" ] || local_ttl=30
      [ $((now - mtime)) -lt "$local_ttl" ] && cache_age_ok=true
    fi

    if [ -f "$CCUSAGE_CACHE" ]; then
      IFS='|' read -r total_tokens remaining_minutes <<< \
        "$(jq -r '([.blocks[] | select(.isActive == true)][0] // null) | if . == null then "|" else [(.totalTokens // 0 | tostring), (.projection.remainingMinutes // "" | tostring)] | join("|") end' "$CCUSAGE_CACHE" 2>/dev/null || echo "|")"

      if [ -n "$total_tokens" ] && [ "$total_tokens" != "0" ] && [ "$total_tokens" != "null" ]; then
        remaining_pct=$(awk "BEGIN { printf \"%.1f\", ($total_tokens / $TOKEN_LIMIT) * 100 }")
        rate_int=${remaining_pct%%.*}
        color=$(_rate_color "$rate_int")

        rate_time=""
        if [ -n "$remaining_minutes" ] && [ "$remaining_minutes" != "null" ]; then
          int_min=${remaining_minutes%%.*}
          h=$((int_min / 60))
          m=$((int_min % 60))
          rate_time=" ${C_DIM}(${h}h ${m}m)${C_RESET}"
        fi

        session_str_rate="${color}${remaining_pct}%${C_RESET}${rate_time}"
      fi
    fi

    if ! $cache_age_ok; then
      (ccusage blocks --active --offline --json > "${CCUSAGE_CACHE}.tmp" 2>/dev/null \
        && mv "${CCUSAGE_CACHE}.tmp" "$CCUSAGE_CACHE") & disown 2>/dev/null
    fi
  fi
fi

# ─── Context window indicator ───

ctx_usage=$(awk "BEGIN { printf \"%.1f\", 100 - ${ctx_remaining} }")
ctx_int=${ctx_usage%%.*}
ctx_color=$(_rate_color "$ctx_int")
ctx_str="${C_DIM}CTX${C_RESET} ${ctx_color}${ctx_usage}%${C_RESET}"

# ─── Output ───

if [ "${CLAUDE_CODE_USE_BEDROCK:-0}" != "0" ]; then
  echo -n "${cwd_str}${SEP}${ctx_str}"
else
  rate_segment=""
  [ -n "$session_str_rate" ] && rate_segment="${session_str_rate}${SEP}"

  echo -n "${cwd_str}${SEP}${rate_segment}${ctx_str}"
fi
