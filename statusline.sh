#!/bin/bash

# ─────────────────────────────────────────
# Claude Code Statusline + Obsidian Logger
# https://github.com/blushdas/claude-code-statusline
# ─────────────────────────────────────────
#
# Environment variables:
#   OBSIDIAN_VAULT              — Path to your Obsidian vault (optional, enables logging)
#   ANTHROPIC_ADMIN_API_KEY     — Anthropic Admin API key (optional, enables API spend tracking)
#   ANTHROPIC_BILLING_START_DAY — Day of month your billing cycle starts (default: 01)
#   CLAUDE_STATUSLINE_DEBUG     — Set to 1 to log diagnostics to ~/.claude/.statusline_debug.log
#
# Context rot thresholds based on Claude Opus 4.6 Context Management Spec v1.0:
#   0-50%: Healthy | 50-75%: Attention | 75-90%: Checkpoint | 90-95%: Critical | 95%+: Emergency

# ── Debug helper ──
DEBUG_LOG="$HOME/.claude/.statusline_debug.log"
debug() { [ -n "$CLAUDE_STATUSLINE_DEBUG" ] && echo "[$(date -u +%H:%M:%S)] $*" >> "$DEBUG_LOG"; }

# ── Float comparison helpers (replaces bc dependency) ──
_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# ── Test mode: bash statusline.sh --test-api ──
if [ "${1}" = "--test-api" ]; then
  if [ -z "$ANTHROPIC_ADMIN_API_KEY" ]; then
    echo "ERROR: ANTHROPIC_ADMIN_API_KEY is not set"; exit 1
  fi
  BILLING_DAY="${ANTHROPIC_BILLING_START_DAY:-01}"
  START_DATE=$(date -u +"%Y-%m-${BILLING_DAY}T00:00:00Z")
  END_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "Fetching org-wide cost report: $START_DATE → $END_DATE"
  TOTAL_CENTS=0; PAGE=""; PAGE_NUM=0
  while true; do
    PAGE_PARAM=""; [ -n "$PAGE" ] && PAGE_PARAM="&page=${PAGE}"
    RESPONSE=$(curl -sf --max-time 10 \
      "https://api.anthropic.com/v1/organizations/cost_report?starting_at=${START_DATE}&ending_at=${END_DATE}&bucket_width=1d&limit=31${PAGE_PARAM}" \
      --header "anthropic-version: 2023-06-01" \
      --header "x-api-key: $ANTHROPIC_ADMIN_API_KEY")
    [ $? -ne 0 ] && echo "ERROR: curl failed on page $((PAGE_NUM+1))" && exit 1
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
    [ -n "$ERROR" ] && echo "API ERROR: $ERROR" && exit 1
    PAGE_NUM=$((PAGE_NUM + 1))
    PAGE_CENTS=$(echo "$RESPONSE" | jq '[.data[].results[]?.amount // "0" | tonumber] | add // 0' 2>/dev/null)
    echo "  Page $PAGE_NUM: $PAGE_CENTS cents"
    TOTAL_CENTS=$(awk -v a="$TOTAL_CENTS" -v b="${PAGE_CENTS:-0}" 'BEGIN{print a+b}')
    HAS_MORE=$(echo "$RESPONSE" | jq -r '.has_more // false' 2>/dev/null)
    [ "$HAS_MORE" != "true" ] && break
    PAGE=$(echo "$RESPONSE" | jq -r '.next_page // empty' 2>/dev/null)
    [ -z "$PAGE" ] && break
  done
  TOTAL=$(echo "$TOTAL_CENTS" | awk '{printf "%.2f", $1 / 100}')
  echo "Org total: \$$TOTAL (from $PAGE_NUM page(s), $TOTAL_CENTS cents raw)"
  CC_SESSIONS="$HOME/.claude/.cc_sessions.json"
  if [ -f "$CC_SESSIONS" ]; then
    CC_MTD=$(jq '[.[]] | add // 0' "$CC_SESSIONS" 2>/dev/null | awk '{printf "%.4f", $1}')
    SESSION_COUNT=$(jq 'keys | length' "$CC_SESSIONS" 2>/dev/null || echo "?")
    echo "CC key total: \$$CC_MTD (from $SESSION_COUNT sessions, locally tracked)"
  fi
  exit 0
fi

input=$(cat)

# ── Extract session ID (used by Astra SDK) ──
SESSION_ID=$(echo "$input" | jq -r '.session_id // ""')

# ── Extract core fields from JSON ──
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
SESSION_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
SESSION_DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# ── Token count (sum all types) ──
USED_TOKENS=$(echo "$input" | jq -r '
  ((.context_window.current_usage.input_tokens // 0) +
   (.context_window.current_usage.cache_creation_input_tokens // 0) +
   (.context_window.current_usage.cache_read_input_tokens // 0) +
   (.context_window.current_usage.output_tokens // 0))
')

# ── Cost per 1k tokens (real-time) ──
if [ "$USED_TOKENS" -gt 0 ] && _gt "${SESSION_COST:-0}" 0; then
  COST_PER_1K=$(echo "$SESSION_COST $USED_TOKENS" | awk '{printf "%.4f", ($1 / $2) * 1000}')
else
  COST_PER_1K="0.0000"
fi

SESSION_COST_FMT=$(printf "%.4f" "$SESSION_COST")
SESSION_COST_SHORT=$(printf "%.2f" "$SESSION_COST")

# ── Token display with smart precision (e.g. 1.2k not 1k for <10k) ──
TOKEN_DISPLAY=$(echo "$USED_TOKENS" | awk '{
  v = $1/1000;
  if (v < 10) printf "%.1fk", v;
  else printf "%dk", v;
}')

# ── Context window size in k ──
CTX_LIMIT_K=$(echo "$CTX_SIZE" | awk '{printf "%dk", $1/1000}')

# ── Session cost alert thresholds ──
COST_ALERT=""
if _ge "${SESSION_COST:-0}" 5; then
  COST_ALERT="\033[41;37;1m ⚠ \$${SESSION_COST_FMT} BURN \033[0m"
elif _ge "${SESSION_COST:-0}" 3; then
  COST_ALERT="\033[31m ⚠ \$${SESSION_COST_FMT}\033[0m"
fi

# ── GitHub username (cached 60 min) ──
GH_CACHE="$HOME/.claude/.gh_user_cache"
if [ ! -f "$GH_CACHE" ] || [ "$(find "$GH_CACHE" -mmin +60 2>/dev/null | wc -l)" -gt 0 ]; then
  GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")
  echo "$GH_USER" > "$GH_CACHE"
else
  GH_USER=$(cat "$GH_CACHE" 2>/dev/null || echo "")
fi

# ── Local CC cost accumulator (per-key, month-to-date) ──
# Tracks Claude Code session costs locally — accurate per API key, no Admin API needed.
# Resets each billing cycle. Each session's peak cost is stored; sum = MTD total.
CC_SESSIONS="$HOME/.claude/.cc_sessions.json"
CC_BILLING_MONTH_FILE="$HOME/.claude/.cc_billing_month"
BILLING_DAY="${ANTHROPIC_BILLING_START_DAY:-01}"

CURRENT_YYYYMM=$(date +%Y%m)
CURRENT_DAY=$(date +%-d 2>/dev/null || date +%d | sed 's/^0//')
# If we haven't reached the billing day this month, billing period is still "last month"
if [ "$CURRENT_DAY" -lt "$BILLING_DAY" ] 2>/dev/null; then
  CURRENT_YYYYMM=$(date -v-1m +%Y%m 2>/dev/null || date -d "1 month ago" +%Y%m 2>/dev/null || echo "$CURRENT_YYYYMM")
fi

STORED_YYYYMM=$(cat "$CC_BILLING_MONTH_FILE" 2>/dev/null || echo "")
if [ "$STORED_YYYYMM" != "$CURRENT_YYYYMM" ]; then
  echo '{}' > "$CC_SESSIONS"
  echo "$CURRENT_YYYYMM" > "$CC_BILLING_MONTH_FILE"
fi

[ ! -f "$CC_SESSIONS" ] && echo '{}' > "$CC_SESSIONS"

# Update current session's peak cost
if [ -n "$SESSION_ID" ] && _gt "${SESSION_COST:-0}" 0; then
  EXISTING=$(jq -r --arg sid "$SESSION_ID" '.[$sid] // "0"' "$CC_SESSIONS" 2>/dev/null || echo "0")
  if _gt "${SESSION_COST}" "${EXISTING}"; then
    TMP_SESSIONS=$(mktemp)
    jq --arg sid "$SESSION_ID" --argjson cost "$SESSION_COST" '.[$sid] = $cost' "$CC_SESSIONS" > "$TMP_SESSIONS" 2>/dev/null && mv "$TMP_SESSIONS" "$CC_SESSIONS"
  fi
fi

CC_MTD=$(jq '[.[]] | add // 0' "$CC_SESSIONS" 2>/dev/null | awk '{printf "%.2f", $1}')
[ -z "$CC_MTD" ] && CC_MTD="0.00"

# ── Today's cost from claudelytics (cached 5 min, background refresh) ──
CLYTICS_CACHE="$HOME/.claude/.claudelytics_today_cache"
CLYTICS_LOCK="$HOME/.claude/.claudelytics_refreshing"
TODAY_COST="?"
[ -f "$CLYTICS_CACHE" ] && TODAY_COST=$(cat "$CLYTICS_CACHE" 2>/dev/null)
[ -z "$TODAY_COST" ] && TODAY_COST="?"

if command -v claudelytics &>/dev/null; then
  CLYTICS_STALE=0
  [ ! -f "$CLYTICS_CACHE" ] && CLYTICS_STALE=1
  [ "$CLYTICS_STALE" = "0" ] && [ "$(find "$CLYTICS_CACHE" -mmin +5 2>/dev/null | wc -l)" -gt 0 ] && CLYTICS_STALE=1
  if [ "$CLYTICS_STALE" = "1" ] && [ ! -f "$CLYTICS_LOCK" ]; then
    (
      touch "$CLYTICS_LOCK"
      result=$(claudelytics cost --today 2>/dev/null | awk '/^Cost:/ {gsub(/\$/,"",$2); printf "%.0f",$2; exit}')
      [ -n "$result" ] && echo "$result" > "$CLYTICS_CACHE"
      rm -f "$CLYTICS_LOCK"
    ) &
  fi
fi

# ── RTK savings today (from SQLite, cached 5 min, background refresh) ──
RTK_DB="$HOME/Library/Application Support/rtk/history.db"
RTK_CACHE="$HOME/.claude/.rtk_today_cache"
RTK_LOCK="$HOME/.claude/.rtk_refreshing"
RTK_SAVED=""
[ -f "$RTK_CACHE" ] && RTK_SAVED=$(cat "$RTK_CACHE" 2>/dev/null)

if [ -f "$RTK_DB" ] && command -v sqlite3 &>/dev/null; then
  RTK_STALE=0
  [ ! -f "$RTK_CACHE" ] && RTK_STALE=1
  [ "$RTK_STALE" = "0" ] && [ "$(find "$RTK_CACHE" -mmin +5 2>/dev/null | wc -l)" -gt 0 ] && RTK_STALE=1
  if [ "$RTK_STALE" = "1" ] && [ ! -f "$RTK_LOCK" ]; then
    (
      touch "$RTK_LOCK"
      # Use awk to get a clean integer from sqlite3 (strips newlines, handles empty)
      saved=$(sqlite3 "$RTK_DB" "SELECT COALESCE(SUM(saved_tokens),0) FROM commands WHERE date(timestamp,'localtime')=date('now','localtime')" 2>/dev/null | awk 'NR==1{print int($1+0)}')
      saved="${saved:-0}"
      if [ "$saved" -gt 0 ] 2>/dev/null; then
        awk -v n="$saved" 'BEGIN{
          v=n/1000;
          if(v<10) printf "%.1fk",v;
          else if(v<1000) printf "%dk",v;
          else printf "%.1fM",v/1000;
        }' > "$RTK_CACHE"
      else
        echo "" > "$RTK_CACHE"
      fi
      rm -f "$RTK_LOCK"
    ) &
  fi
fi

# ── Build colored context progress bar ──
BAR_WIDTH=12
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

# ANSI color codes based on threshold tier
if [ "$PCT" -ge 95 ]; then
  BAR_COLOR="\033[41;37;1m"  # red bg, white bold (flash effect)
elif [ "$PCT" -ge 90 ]; then
  BAR_COLOR="\033[31m"       # red
elif [ "$PCT" -ge 75 ]; then
  BAR_COLOR="\033[38;5;208m" # orange
elif [ "$PCT" -ge 50 ]; then
  BAR_COLOR="\033[33m"       # yellow
else
  BAR_COLOR="\033[32m"       # green
fi
RESET="\033[0m"
DIM="\033[2m"

FILLED_STR=""
EMPTY_STR=""
[ "$FILLED" -gt 0 ] && FILLED_STR=$(printf "%${FILLED}s" | tr ' ' '█')
[ "$EMPTY"  -gt 0 ] && EMPTY_STR=$(printf "%${EMPTY}s" | tr ' ' '░')
BAR="${BAR_COLOR}${FILLED_STR}${RESET}${DIM}${EMPTY_STR}${RESET}"

# ── Context rot status (Claude Opus 4.6 Context Management Spec v1.0) ──
if [ "$PCT" -ge 95 ]; then
  STATUS="${BAR_COLOR}◉◉ EMERGENCY${RESET}"
elif [ "$PCT" -ge 90 ]; then
  STATUS="${BAR_COLOR}● CRITICAL${RESET}"
elif [ "$PCT" -ge 75 ]; then
  STATUS="${BAR_COLOR}● CHECKPOINT${RESET}"
elif [ "$PCT" -ge 50 ]; then
  STATUS="${BAR_COLOR}● ATTENTION${RESET}"
else
  STATUS="${BAR_COLOR}● healthy${RESET}"
fi

# ── GitHub prefix ──
GH_PREFIX=""
[ -n "$GH_USER" ] && GH_PREFIX="@${GH_USER} | "

# ── API org total (from Admin API cache, rounded for display) ──
API_TOTAL_RAW=$(cat "$HOME/.claude/.api_cost_cache" 2>/dev/null | tr -d '[:space:]')
if [ -n "$API_TOTAL_RAW" ]; then
  API_TOTAL=$(echo "$API_TOTAL_RAW" | awk '{printf "%d", $1}')
else
  API_TOTAL="?"
fi

# ── Burn rate ($/min for current session) ──
BURN_RATE="-.--"
if [ "$SESSION_DURATION_MS" -gt 0 ] 2>/dev/null && _gt "${SESSION_COST:-0}" 0; then
  BURN_RATE=$(echo "$SESSION_COST $SESSION_DURATION_MS" | awk '{printf "%.2f", ($1 / ($2 / 60000))}')
fi

# ── ANSI color palette ──
BOLD="\033[1m"
WHITE="\033[37;1m"
CYAN="\033[36m"
YELLOW="\033[33m"
GREEN="\033[32m"
RED="\033[31m"
MAGENTA="\033[35m"
DIM_SEP="\033[2m"

# ── RTK savings segment (green, only if non-empty) ──
RTK_SEGMENT=""
[ -n "$RTK_SAVED" ] && RTK_SEGMENT="  ${GREEN}↓${RTK_SAVED}${RESET} ${DIM}rtk${RESET}"

# ── Output to statusline (two rows) ──
# Row 1: user | model | [colored bar] pct% | health status
#   Dim pipes for structure, data stands out
# Row 2: color-coded by importance
#   dim=reference, bold=session cost, cyan=today, yellow=MTD, green=rtk savings
ROW1="${DIM}@${RESET}${GH_USER} ${DIM}|${RESET} ${MODEL} ${DIM}|${RESET} ${BAR} ${PCT}%% ${DIM}|${RESET} ${STATUS}"
[ -z "$GH_USER" ] && ROW1="${MODEL} ${DIM}|${RESET} ${BAR} ${PCT}%% ${DIM}|${RESET} ${STATUS}"

ROW2="${DIM}\$${COST_PER_1K}/1k · ${TOKEN_DISPLAY}/${CTX_LIMIT_K}${RESET}"
ROW2="${ROW2}  ${WHITE}\$${SESSION_COST_SHORT}${RESET} ${DIM}sesh${RESET} ${DIM}·${RESET} ${DIM}\$${BURN_RATE}/min${RESET}"
ROW2="${ROW2}  ${CYAN}\$${TODAY_COST}${RESET} ${DIM}today${RESET} ${DIM}·${RESET} ${YELLOW}\$${CC_MTD}${RESET} ${DIM}CC${RESET} ${DIM}·${RESET} ${DIM}\$${API_TOTAL} org${RESET}"
ROW2="${ROW2}${RTK_SEGMENT}${COST_ALERT}"

printf "${ROW1}\n${ROW2}\n"

# ── Astra Agent SDK row (ROW3) ──
ASTRA_DIR="$HOME/.astra"
ASTRA_ROW=""

# Registry summary
if [ -f "$ASTRA_DIR/registry.json" ]; then
  ASTRA_AGENTS=$(jq -r '.agentCount // ""' "$ASTRA_DIR/registry.json" 2>/dev/null)
  ASTRA_DIVS=$(jq -r '.divisionCount // ""' "$ASTRA_DIR/registry.json" 2>/dev/null)
  [ -n "$ASTRA_AGENTS" ] && ASTRA_ROW="${DIM}⬡ ${ASTRA_AGENTS} agents/${ASTRA_DIVS} div${RESET}"
fi

# Workflow state
WORKFLOW_STATUS=""
if [ -n "$SESSION_ID" ] && [ -f "$ASTRA_DIR/workflow/${SESSION_ID}.json" ]; then
  WORKFLOW_STATUS=$(jq -r '.status // ""' "$ASTRA_DIR/workflow/${SESSION_ID}.json" 2>/dev/null)
  WORKFLOW_PHASE=$(jq -r '.currentPhase // ""' "$ASTRA_DIR/workflow/${SESSION_ID}.json" 2>/dev/null)
  if [ -n "$WORKFLOW_STATUS" ]; then
    PHASE_LABEL=""
    [ -n "$WORKFLOW_PHASE" ] && PHASE_LABEL=" (${WORKFLOW_PHASE})"
    case "$WORKFLOW_STATUS" in
      executing)  WF_COLOR="\033[32m" ;;
      crashed)    WF_COLOR="\033[31m" ;;
      blocked)    WF_COLOR="\033[33m" ;;
      complete)   WF_COLOR="\033[35m" ;;
      *)          WF_COLOR="\033[2m" ;;
    esac
    WF_SEGMENT="${WF_COLOR}◆ ${WORKFLOW_STATUS}${PHASE_LABEL}${RESET}"
    ASTRA_ROW="${ASTRA_ROW}  ${WF_SEGMENT}"
  fi
fi

# Event log error count today
TODAY=$(date +"%Y-%m-%d")
EVENTS_FILE="$ASTRA_DIR/events/${TODAY}.jsonl"
if [ -f "$EVENTS_FILE" ]; then
  ERROR_COUNT=$(grep -c '"severity":"error"' "$EVENTS_FILE" 2>/dev/null)
  ERROR_COUNT="${ERROR_COUNT:-0}"
  EVENT_COUNT=$(wc -l < "$EVENTS_FILE" 2>/dev/null | tr -d '[:space:]')
  EVENT_COUNT="${EVENT_COUNT:-0}"
  [ "$ERROR_COUNT" -gt 0 ] \
    && ASTRA_ROW="${ASTRA_ROW}  \033[31m✗ ${ERROR_COUNT} err${RESET}" \
    || ASTRA_ROW="${ASTRA_ROW}  ${DIM}${EVENT_COUNT} events${RESET}"
fi

[ -n "$ASTRA_ROW" ] && printf "${ASTRA_ROW}\n"

# ── Write to Obsidian vault ──
if [ -n "$OBSIDIAN_VAULT" ] && [ -d "$OBSIDIAN_VAULT" ]; then
  OBSIDIAN_DIR="${OBSIDIAN_VAULT}/Claude Sessions"
  mkdir -p "$OBSIDIAN_DIR"

  DATE=$(date +"%Y-%m-%d")
  TIME=$(date +"%H:%M:%S")
  OBSIDIAN_FILE="${OBSIDIAN_DIR}/Claude Sessions — ${DATE}.md"

  # Create file with header if it doesn't exist
  if [ ! -f "$OBSIDIAN_FILE" ]; then
    cat > "$OBSIDIAN_FILE" << EOF
# Claude Code Sessions — ${DATE}

> Auto-generated by Claude Code statusline. Updates in real-time.

## Today's Summary

| Time | Model | Context% | \$/1k tokens | Session \$ | Tokens | Git Branch | Status |
|------|-------|----------|-------------|-----------|--------|------------|--------|
EOF
  fi

  # Get git branch if available
  GIT_BRANCH=$(git -C "$(echo "$input" | jq -r '.workspace.current_dir // "."')" branch --show-current 2>/dev/null || echo "—")

  # Plaintext status for Obsidian (no ANSI)
  if [ "$PCT" -ge 95 ]; then OBS_STATUS="EMERGENCY"
  elif [ "$PCT" -ge 90 ]; then OBS_STATUS="CRITICAL"
  elif [ "$PCT" -ge 75 ]; then OBS_STATUS="CHECKPOINT"
  elif [ "$PCT" -ge 50 ]; then OBS_STATUS="ATTENTION"
  else OBS_STATUS="healthy"
  fi

  # Append new row (avoids duplicate timestamps by checking last line)
  LAST_TIME=$(tail -1 "$OBSIDIAN_FILE" | grep -o "^| [0-9:]*" | tr -d '| ')
  if [ "$LAST_TIME" != "$TIME" ]; then
    echo "| $TIME | $MODEL | ${PCT}% | \$$COST_PER_1K | \$$SESSION_COST_FMT | ~$TOKEN_DISPLAY | $GIT_BRANCH | $OBS_STATUS |" >> "$OBSIDIAN_FILE"
  fi

  # Update footer in-place (fixes blank-line accumulation bug from grep-v approach)
  # Use @ as sed delimiter (avoids conflict with | in footer text)
  FOOTER_LINE="**Claude Code Total (month-to-date):** \$${CC_MTD}  **Today:** \$${TODAY_COST}"
  if grep -q "^\*\*Claude Code Total" "$OBSIDIAN_FILE" 2>/dev/null; then
    sed -i '' "s@^\*\*Claude Code Total.*@${FOOTER_LINE}@" "$OBSIDIAN_FILE" 2>/dev/null || \
    sed -i "s@^\*\*Claude Code Total.*@${FOOTER_LINE}@" "$OBSIDIAN_FILE" 2>/dev/null
  else
    echo "" >> "$OBSIDIAN_FILE"
    echo "$FOOTER_LINE" >> "$OBSIDIAN_FILE"
  fi
fi
