#!/bin/bash
# Refresh Anthropic API cost cache
# Queries the Admin API (paginated) and writes result to ~/.claude/.api_cost_cache
# Runs as background daemon (launchd, every 1 hour) and on SessionStart hook

CACHE="$HOME/.claude/.api_cost_cache"
FETCHING_FLAG="$HOME/.claude/.api_cost_fetching"
ADMIN_KEY="${ANTHROPIC_ADMIN_API_KEY}"

[ -z "$ADMIN_KEY" ] && exit 0

trap 'rm -f "$FETCHING_FLAG"' EXIT
touch "$FETCHING_FLAG"

BILLING_DAY="${ANTHROPIC_BILLING_START_DAY:-01}"
START_DATE=$(date -u +"%Y-%m-${BILLING_DAY}T00:00:00Z")
END_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

TOTAL_CENTS=0
PAGE=""
PAGE_NUM=0
FETCH_OK=false

while true; do
  PAGE_PARAM=""
  [ -n "$PAGE" ] && PAGE_PARAM="&page=${PAGE}"

  RESPONSE=$(curl -sf --max-time 10 \
    "https://api.anthropic.com/v1/organizations/cost_report?starting_at=${START_DATE}&ending_at=${END_DATE}&bucket_width=1d&limit=31${PAGE_PARAM}" \
    --header "anthropic-version: 2023-06-01" \
    --header "x-api-key: $ADMIN_KEY" 2>/dev/null)

  [ $? -ne 0 ] || [ -z "$RESPONSE" ] && break

  ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
  [ -n "$ERROR" ] && break

  PAGE_NUM=$((PAGE_NUM + 1))
  FETCH_OK=true
  PAGE_CENTS=$(echo "$RESPONSE" | jq '[.data[].results[]?.amount // "0" | tonumber] | add // 0' 2>/dev/null)
  TOTAL_CENTS=$(echo "$TOTAL_CENTS + ${PAGE_CENTS:-0}" | bc -l)

  HAS_MORE=$(echo "$RESPONSE" | jq -r '.has_more // false' 2>/dev/null)
  [ "$HAS_MORE" != "true" ] && break
  PAGE=$(echo "$RESPONSE" | jq -r '.next_page // empty' 2>/dev/null)
  [ -z "$PAGE" ] && break
done

if [ "$FETCH_OK" = "true" ]; then
  echo "$TOTAL_CENTS" | awk '{printf "%.2f", $1 / 100}' > "$CACHE"
fi
