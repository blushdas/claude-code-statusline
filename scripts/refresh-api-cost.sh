#!/bin/bash
# Refresh Anthropic API cost cache
# Queries the Admin API and writes result to ~/.claude/.api_cost_cache
# Runs as background daemon (launchd) and on SessionStart hook

CACHE="$HOME/.claude/.api_cost_cache"
ADMIN_KEY="${ANTHROPIC_ADMIN_API_KEY}"
KEY_CREATED="${ANTHROPIC_KEY_CREATED}"

[ -z "$ADMIN_KEY" ] && exit 0

START_DATE="${KEY_CREATED:-$(date -u +"%Y-%m-01T00:00:00Z")}"
END_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RAW=$(curl -s \
  "https://api.anthropic.com/v1/organizations/cost_report?starting_at=${START_DATE}&ending_at=${END_DATE}" \
  --header "anthropic-version: 2023-06-01" \
  --header "x-api-key: $ADMIN_KEY" 2>/dev/null)

[ -z "$RAW" ] && exit 0

TOTAL=$(echo "$RAW" | jq -r '
  [.data[].results[]?.amount // "0"] | map(tonumber) | add // 0
' 2>/dev/null | awk '{printf "%.2f", $1 / 100}')

[ -z "$TOTAL" ] && exit 0

echo "$TOTAL" > "$CACHE"
