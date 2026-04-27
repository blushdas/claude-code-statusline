#!/bin/bash

# ─────────────────────────────────────────
# Claude Code Statusline
# https://github.com/blushdas/claude-code-statusline
# ─────────────────────────────────────────
#
# Environment variables:
#   ANTHROPIC_BILLING_START_DAY — Day of month your billing cycle starts (default: 01)
#   CLAUDE_STATUSLINE_DEBUG     — Set to 1 to log diagnostics to ~/.claude/.statusline_debug.log
#
# Context rot thresholds based on Claude Opus 4.6 Context Management Spec v1.0:
#   0-50%: Healthy | 50-75%: Attention | 75-90%: Checkpoint | 90-95%: Critical | 95%+: Emergency

# ── Pure computation functions ──
STATUSLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STATUSLINE_DIR/lib/compute.sh"

# ── Debug helper ──
DEBUG_LOG="$HOME/.claude/.statusline_debug.log"
debug() { [ -n "$CLAUDE_STATUSLINE_DEBUG" ] && echo "[$(date -u +%H:%M:%S)] $*" >> "$DEBUG_LOG"; }


input=$(cat)
debug "RAW_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0') RAW_TOKENS=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')"

# ── Extract session ID (used by Astra SDK) ──
SESSION_ID=$(echo "$input" | jq -r '.session_id // ""')

# ── Extract core fields from JSON ──
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
SESSION_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
SESSION_DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

# ── Token count (sum all types) + raw cache fields for hit % ──
CACHE_READ=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
CACHE_CREATE=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
INPUT_RAW=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
USED_TOKENS=$(echo "$input" | jq -r '
  ((.context_window.current_usage.input_tokens // 0) +
   (.context_window.current_usage.cache_creation_input_tokens // 0) +
   (.context_window.current_usage.cache_read_input_tokens // 0) +
   (.context_window.current_usage.output_tokens // 0))
')

# ── Fallback: derive tokens from percentage when current_usage is zero ──
# used_percentage includes system prompt + tools + memory + conversation.
# current_usage only counts conversation tokens from model turns.
USED_TOKENS=$(token_or_fallback "$USED_TOKENS" "$PCT" "$CTX_SIZE")

# ── Cache hit percentage (suppressed when 0 — no noise at session start) ──
CACHE_HIT_PCT=$(cache_hit_pct "$CACHE_READ" "$CACHE_CREATE" "$INPUT_RAW")

# ── Git branch (current working directory) ──
GIT_BRANCH=$(git branch --show-current 2>/dev/null | head -1)

# ── Context bridge for gsd-context-monitor.js ──
if [ -n "$SESSION_ID" ]; then
  _CTX_REMAINING=$((100 - PCT))
  printf '{"session_id":"%s","remaining_percentage":%d,"used_pct":%d,"timestamp":%d}' \
    "$SESSION_ID" "$_CTX_REMAINING" "$PCT" "$(date +%s)" > "/tmp/claude-ctx-${SESSION_ID}.json"
fi

# ── Cost per 1k tokens (real-time) ──
COST_PER_1K=$(cost_per_1k "$SESSION_COST" "$USED_TOKENS")

SESSION_COST_FMT=$(printf "%.4f" "$SESSION_COST")
SESSION_COST_SHORT=$(printf "%.2f" "$SESSION_COST")

# ── Token display with smart precision (e.g. 1.2k not 1k for <10k) ──
TOKEN_DISPLAY=$(token_display "$USED_TOKENS")

# ── Context window size in k ──
CTX_LIMIT_K=$(ctx_limit_k "$CTX_SIZE")

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
CC_MTD_INT=$(echo "$CC_MTD" | awk '{printf "%.0f", $1}')

# ── Claudelytics: today + CC total (cached 60s, background refresh) ──
CLYTICS_CACHE="$HOME/.claude/.claudelytics_today_cache"
CLYTICS_TOTAL_CACHE="$HOME/.claude/.claudelytics_total_cache"
CLYTICS_LOCK="$HOME/.claude/.claudelytics_refreshing"
TODAY_COST="?"
CLYTICS_TOTAL="?"
[ -f "$CLYTICS_CACHE" ] && TODAY_COST=$(cat "$CLYTICS_CACHE" 2>/dev/null)
[ -f "$CLYTICS_TOTAL_CACHE" ] && CLYTICS_TOTAL=$(cat "$CLYTICS_TOTAL_CACHE" 2>/dev/null)

if command -v claudelytics &>/dev/null; then
  # Auto-clean stale lock (crashed refresh)
  [ -f "$CLYTICS_LOCK" ] && cache_is_stale "$CLYTICS_LOCK" 60 && rm -f "$CLYTICS_LOCK"
  if cache_is_stale "$CLYTICS_CACHE" 60 && [ ! -f "$CLYTICS_LOCK" ]; then
    (
      touch "$CLYTICS_LOCK"
      CLYTICS_JSON=$(claudelytics --json daily 2>/dev/null)
      if [ -n "$CLYTICS_JSON" ]; then
        echo "$CLYTICS_JSON" | jq -r --arg d "$(date +%Y-%m-%d)" \
          '[.daily[] | select(.date == $d)] | .[0].totalCost // 0' 2>/dev/null \
          | awk '{printf "%.0f", $1}' > "$CLYTICS_CACHE"
        echo "$CLYTICS_JSON" | jq -r '.totals.totalCost // 0' 2>/dev/null \
          | awk '{printf "%.0f", $1}' > "$CLYTICS_TOTAL_CACHE"
      fi
      rm -f "$CLYTICS_LOCK"
    ) &
  fi
fi
[ -z "$TODAY_COST" ] && TODAY_COST="?"
[ -z "$CLYTICS_TOTAL" ] && CLYTICS_TOTAL="?"

# ── RTK savings today (from SQLite, cached 5 min, background refresh) ──
RTK_DB="$HOME/Library/Application Support/rtk/history.db"
RTK_CACHE="$HOME/.claude/.rtk_today_cache"
RTK_LOCK="$HOME/.claude/.rtk_refreshing"
RTK_RAW=""
[ -f "$RTK_CACHE" ] && RTK_RAW=$(cat "$RTK_CACHE" 2>/dev/null | awk 'NR==1{print int($1+0)}')

if [ -f "$RTK_DB" ] && command -v sqlite3 &>/dev/null; then
  # Auto-clean stale lock (crashed refresh)
  [ -f "$RTK_LOCK" ] && cache_is_stale "$RTK_LOCK" 60 && rm -f "$RTK_LOCK"
  if cache_is_stale "$RTK_CACHE" 60 && [ ! -f "$RTK_LOCK" ]; then
    (
      touch "$RTK_LOCK"
      saved=$(sqlite3 "$RTK_DB" "SELECT COALESCE(SUM(saved_tokens),0) FROM commands WHERE date(timestamp,'localtime')=date('now','localtime')" 2>/dev/null | awk 'NR==1{print int($1+0)}')
      saved="${saved:-0}"
      echo "$saved" > "$RTK_CACHE"
      rm -f "$RTK_LOCK"
    ) &
  fi
fi

# ── Build colored context progress bar ──
BAR_WIDTH=14
FILLED=$(bar_filled "$PCT" "$BAR_WIDTH")
EMPTY=$((BAR_WIDTH - FILLED))
BAR_COLOR="\033[$(bar_color_code "$PCT")m"
RESET="\033[0m"
DIM="\033[2m"

FILLED_STR=""
EMPTY_STR=""
[ "$FILLED" -gt 0 ] && FILLED_STR=$(printf "%${FILLED}s" | tr ' ' '█')
[ "$EMPTY"  -gt 0 ] && EMPTY_STR=$(printf "%${EMPTY}s" | tr ' ' '░')
BAR="${BAR_COLOR}${FILLED_STR}${RESET}${DIM}${EMPTY_STR}${RESET}"

# ── Context rot status (Claude Opus 4.6 Context Management Spec v1.0) ──
STATUS_TEXT=$(status_label "$PCT")
if [ "$PCT" -ge 95 ]; then
  STATUS="${BAR_COLOR}◉◉ ${STATUS_TEXT}${RESET}"
else
  STATUS="${BAR_COLOR}● ${STATUS_TEXT}${RESET}"
fi

# ── GitHub prefix (dimmed — reference info, not actionable) ──
GH_PREFIX=""
[ -n "$GH_USER" ] && GH_PREFIX="${DIM}@${GH_USER}${RESET}"

# ── Burn rate ($/min for current session) ──
BURN_RATE=$(burn_rate "$SESSION_COST" "$SESSION_DURATION_MS")

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
RTK_STALE_MARKER=$(stale_marker "$RTK_CACHE" 60)
if [ -n "$RTK_RAW" ] && [ "$RTK_RAW" -gt 0 ] 2>/dev/null; then
  RTK_FMT=$(rtk_format "$RTK_RAW")
  RTK_DOLLARS=$(rtk_dollars "$RTK_RAW")
  RTK_SEGMENT="${GREEN}↓${RTK_FMT} ${RTK_DOLLARS}${RTK_STALE_MARKER}${RESET} ${DIM}rtk${RESET}"
fi

# ── Staleness markers for cache-backed fields ──
TODAY_STALE=$(stale_marker "$CLYTICS_CACHE" 60)

# ── Output to statusline ──
# Row 1: identity │ model │ [bar] pct% │ health   (identity dimmed, bar+status bright)
# Row 2: rate zone ─ session zone                  (session cost bold white)
# Row 3: spend zone ─ savings/alert zone           (color-coded by concern level)
# Row 4: astra agents ─ workflow ─ events          (conditional, dim reference)

# ── Opus guard: flag if Opus active without Commander workflow ──
ASTRA_DIR="$HOME/.astra"
MODEL_SEGMENT="${DIM}${MODEL}${RESET}"
OPUS_BADGE=""
case "$MODEL" in
  *Opus*|*opus*)
    WF_ACTIVE=""
    if [ -n "$SESSION_ID" ] && [ -f "$ASTRA_DIR/workflow/${SESSION_ID}.json" ]; then
      WF_ACTIVE=$(jq -r '.status // ""' "$ASTRA_DIR/workflow/${SESSION_ID}.json" 2>/dev/null)
    fi
    if [ "$WF_ACTIVE" = "executing" ]; then
      MODEL_SEGMENT="\033[35;1m${MODEL}\033[0m"
    else
      MODEL_SEGMENT="\033[41;37;1m ⚠ ${MODEL} \033[0m"
      OPUS_BADGE="\033[31;1m OPUS-NO-CMDR \033[0m"
    fi
    ;;
esac

# ── Git branch segment (dim, only if inside a repo) ──
BRANCH_SEGMENT=""
[ -n "$GIT_BRANCH" ] && BRANCH_SEGMENT=" ${DIM}│${RESET} ${DIM}${GIT_BRANCH}${RESET}"

ROW1="${GH_PREFIX} ${DIM}│${RESET} ${MODEL_SEGMENT} ${DIM}│${RESET} ${BAR} ${BAR_COLOR}${PCT}%%${RESET} ${DIM}│${RESET} ${STATUS}${OPUS_BADGE}${BRANCH_SEGMENT}"
[ -z "$GH_USER" ] && ROW1="${MODEL_SEGMENT} ${DIM}│${RESET} ${BAR} ${BAR_COLOR}${PCT}%%${RESET} ${DIM}│${RESET} ${STATUS}${OPUS_BADGE}${BRANCH_SEGMENT}"

# ── Cache hit segment (cyan, only if >0%; %% for printf safety) ──
CACHE_SEGMENT=""
[ -n "$CACHE_HIT_PCT" ] && CACHE_SEGMENT=" ${DIM}·${RESET} ${CYAN}${CACHE_HIT_PCT}%%${RESET} ${DIM}cache${RESET}"

ROW2="  ${DIM}\$${COST_PER_1K}/1k · ${TOKEN_DISPLAY}/${CTX_LIMIT_K}${RESET}${CACHE_SEGMENT}"
ROW2="${ROW2}  ${DIM}─${RESET}  ${WHITE}\$${SESSION_COST_SHORT}${RESET} ${DIM}sesh${RESET} ${DIM}·${RESET} ${DIM}\$${BURN_RATE}/min${RESET}"

ROW3="  ${CYAN}\$${TODAY_COST}${TODAY_STALE}${RESET} ${DIM}today${RESET} ${DIM}·${RESET} ${YELLOW}\$${CC_MTD_INT}${RESET} ${DIM}key${RESET} ${DIM}·${RESET} ${DIM}\$${CLYTICS_TOTAL}${TODAY_STALE}${RESET} ${DIM}all${RESET}"
if [ -n "$RTK_SEGMENT" ] || [ -n "$COST_ALERT" ]; then
  ROW3="${ROW3}  ${DIM}─${RESET}  ${RTK_SEGMENT}${COST_ALERT}"
fi

printf "${ROW1}\n${ROW2}\n${ROW3}\n"

# ── Astra Agent SDK row (ROW3) ──
ASTRA_ROW=""

# Registry summary
if [ -f "$ASTRA_DIR/registry.json" ]; then
  ASTRA_AGENTS=$(jq -r '.agentCount // ""' "$ASTRA_DIR/registry.json" 2>/dev/null)
  ASTRA_DIVS=$(jq -r '.divisionCount // ""' "$ASTRA_DIR/registry.json" 2>/dev/null)
  [ -n "$ASTRA_AGENTS" ] && ASTRA_ROW="  ${DIM}⬡ ${ASTRA_AGENTS} agents/${ASTRA_DIVS} div${RESET}"
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
    ASTRA_ROW="${ASTRA_ROW}  ${DIM}─${RESET}  ${WF_SEGMENT}"
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
    && ASTRA_ROW="${ASTRA_ROW}  ${DIM}─${RESET}  \033[31m✗ ${ERROR_COUNT} err${RESET}" \
    || ASTRA_ROW="${ASTRA_ROW}  ${DIM}─${RESET}  ${DIM}${EVENT_COUNT} events${RESET}"
fi

[ -n "$ASTRA_ROW" ] && printf "${ASTRA_ROW}\n"

# ── Unified state file (single truth for all consumers) ──
STATE_FILE="$HOME/.claude/.statusline_state.json"
if command -v jq &>/dev/null; then
  jq -n \
    --argjson ts "$(date +%s)" \
    --arg sid "$SESSION_ID" \
    --argjson pct "${PCT:-0}" \
    --argjson remaining "$((100 - ${PCT:-0}))" \
    --argjson used_tokens "${USED_TOKENS:-0}" \
    --argjson ctx_size "${CTX_SIZE:-200000}" \
    --arg health "$(status_label "${PCT:-0}")" \
    --arg model "$MODEL" \
    --arg gh_user "$GH_USER" \
    --arg session_cost "${SESSION_COST:-0}" \
    --arg cost_per_1k "$COST_PER_1K" \
    --arg burn_rate "$BURN_RATE" \
    --arg today_cost "$TODAY_COST" \
    --arg cc_mtd "$CC_MTD" \
    --arg cc_alltime "$CLYTICS_TOTAL" \
    --arg rtk_saved "${RTK_SAVED:-}" \
    --argjson astra_agents "${ASTRA_AGENTS:-0}" \
    --argjson astra_divs "${ASTRA_DIVS:-0}" \
    --arg workflow_status "${WORKFLOW_STATUS:-idle}" \
    --argjson event_count "${EVENT_COUNT:-0}" \
    --argjson error_count "${ERROR_COUNT:-0}" \
    --argjson gh_age "$(cache_age "$GH_CACHE")" \
    --argjson today_age "$(cache_age "$CLYTICS_CACHE")" \
    --argjson rtk_age "$(cache_age "$RTK_CACHE")" \
    --arg cache_hit_pct "${CACHE_HIT_PCT:-}" \
    --arg git_branch "${GIT_BRANCH:-}" \
    '{
      version: 1,
      timestamp: $ts,
      session_id: $sid,
      context: { used_pct: $pct, remaining_pct: $remaining, used_tokens: $used_tokens, ctx_size: $ctx_size, health: $health, cache_hit_pct: $cache_hit_pct },
      cost: { session_usd: $session_cost, cost_per_1k: $cost_per_1k, burn_rate_min: $burn_rate, today_usd: $today_cost, cc_key_mtd_usd: $cc_mtd, cc_alltime_usd: $cc_alltime },
      identity: { model: $model, gh_user: $gh_user, git_branch: $git_branch },
      astra: { agent_count: $astra_agents, division_count: $astra_divs, workflow_status: $workflow_status, event_count: $event_count, error_count: $error_count },
      rtk: { saved_today: $rtk_saved },
      freshness: {
        gh_user:    { age_s: $gh_age,    max_s: 3600, fresh: ($gh_age < 3600) },
        today_cost: { age_s: $today_age, max_s: 60,   fresh: ($today_age < 60) },
        rtk_saved:  { age_s: $rtk_age,   max_s: 300,  fresh: ($rtk_age < 300) }
      }
    }' > "$STATE_FILE" 2>/dev/null
fi

# Vault writes handled by SessionEnd hook (session-logger-worker.js).
