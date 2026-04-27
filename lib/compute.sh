#!/bin/bash
# lib/compute.sh — pure computation functions for statusline
# All functions are stateless with no side effects. Testable in isolation.

# ── Float comparison helpers (replaces bc dependency) ──
_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# ── Token count → display string with smart precision ──
# Args: $1 = token count (integer)
# Output: "1.2k" for <10k, "12k" for >=10k
token_display() {
  echo "$1" | awk '{
    v = $1/1000;
    if (v < 10) printf "%.1fk", v;
    else printf "%dk", v;
  }'
}

# ── Context window size → "200k" format ──
# Args: $1 = size in tokens
ctx_limit_k() {
  echo "$1" | awk '{printf "%dk", $1/1000}'
}

# ── RTK savings → k/M format ──
# Args: $1 = saved tokens (integer)
# Output: "1.2k", "203k", "1.4M"
rtk_format() {
  local saved="$1"
  awk -v n="$saved" 'BEGIN{
    v=n/1000;
    if(v<10) printf "%.1fk",v;
    else if(v<1000) printf "%dk",v;
    else printf "%.1fM",v/1000;
  }'
}

# ── RTK savings → dollar cost saved ──
# Args: $1 = saved tokens (integer)
# Output: "$X.XX" at Sonnet 4.6 input rate ($3/1M tokens)
rtk_dollars() {
  local tokens="$1"
  awk -v n="$tokens" 'BEGIN{d=n*0.000003; if(d<0.01) printf "$%.3f",d; else printf "$%.2f",d}'
}

# ── Bar fill count ──
# Args: $1 = pct (0-100 integer), $2 = width (default 12)
# Output: number of filled chars
bar_filled() {
  local pct="$1" width="${2:-12}"
  echo $((pct * width / 100))
}

# ── ANSI color code string for PCT tier ──
# Args: $1 = pct (integer)
# Output: ANSI code values only (e.g. "32" for green), caller wraps with \033[..m
bar_color_code() {
  local pct="$1"
  if   [ "$pct" -ge 95 ]; then echo "41;37;1"
  elif [ "$pct" -ge 90 ]; then echo "31"
  elif [ "$pct" -ge 75 ]; then echo "38;5;208"
  elif [ "$pct" -ge 50 ]; then echo "33"
  else                          echo "32"
  fi
}

# ── Status label text for PCT tier ──
# Args: $1 = pct (integer)
status_label() {
  local pct="$1"
  if   [ "$pct" -ge 95 ]; then echo "EMERGENCY"
  elif [ "$pct" -ge 90 ]; then echo "CRITICAL"
  elif [ "$pct" -ge 75 ]; then echo "CHECKPOINT"
  elif [ "$pct" -ge 50 ]; then echo "ATTENTION"
  else                          echo "healthy"
  fi
}

# ── Burn rate: $/min ──
# Args: $1 = cost_usd, $2 = duration_ms
# Output: "X.XX" or "-.--" if no data
burn_rate() {
  local cost="$1" duration_ms="$2"
  if [ "${duration_ms:-0}" -gt 0 ] 2>/dev/null && _gt "${cost:-0}" 0; then
    echo "$cost $duration_ms" | awk '{printf "%.2f", ($1 / ($2 / 60000))}'
  else
    echo "-.--"
  fi
}

# ── Cost per 1k tokens ──
# Args: $1 = cost_usd, $2 = used_tokens
# Output: "X.XXXX" or "0.0000" if no data
cost_per_1k() {
  local cost="$1" tokens="$2"
  if [ "${tokens:-0}" -gt 0 ] && _gt "${cost:-0}" 0; then
    echo "$cost $tokens" | awk '{printf "%.4f", ($1 / $2) * 1000}'
  else
    echo "0.0000"
  fi
}

# ── Token fallback: derive from percentage when current_usage is zero ──
# After /clear or before first model turn, current_usage fields are 0
# but used_percentage includes system prompt + tools + memory.
# Args: $1 = used_tokens, $2 = pct (integer), $3 = ctx_size
# Output: best token count to display
token_or_fallback() {
  local tokens="$1" pct="$2" ctx_size="$3"
  if [ "${tokens:-0}" -eq 0 ] && [ "${pct:-0}" -gt 0 ]; then
    echo $((pct * ctx_size / 100))
  else
    echo "${tokens:-0}"
  fi
}

# ── Cache hit percentage ──
# Args: $1=cache_read_tokens, $2=cache_creation_tokens, $3=input_tokens
# Output: integer (e.g. "87") or "" if 0 — no "%" suffix (caller adds %% for printf safety)
cache_hit_pct() {
  local cr="$1" cc="$2" inp="$3"
  awk -v cr="$cr" -v cc="$cc" -v inp="$inp" 'BEGIN {
    total = cr + cc + inp;
    if (total == 0) { print ""; exit }
    pct = int(cr / total * 100);
    if (pct == 0) { print ""; exit }
    printf "%d", pct
  }'
}

# ── Cache middleware ──────────────────────────────────────────────────

# cache_age: file age in seconds (999999 if missing)
# Args: $1 = cache file path
cache_age() {
  [ ! -f "$1" ] && echo "999999" && return
  local mtime now
  mtime=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)
  now=$(date +%s)
  echo $((now - mtime))
}

# cache_is_stale: exit 0 if stale, exit 1 if fresh
# Args: $1 = cache file, $2 = max stale seconds
cache_is_stale() {
  local age
  age=$(cache_age "$1")
  [ "$age" -gt "$2" ] 2>/dev/null
}

# stale_marker: returns dim "?" if stale, empty if fresh
# Args: $1 = cache file, $2 = max stale seconds
stale_marker() {
  if cache_is_stale "$1" "$2"; then
    printf '\033[2m?\033[0m'
  fi
}
