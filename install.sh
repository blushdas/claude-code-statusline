#!/bin/bash

# ─────────────────────────────────────────
# Claude Code Statusline — Installer
# https://github.com/blushdas/claude-code-statusline
# ─────────────────────────────────────────

set -e

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${BOLD}Claude Code Statusline${NC} — Installer"
echo -e "${DIM}─────────────────────────────────────${NC}"
echo ""

# ── Check dependencies ──
if ! command -v jq &>/dev/null; then
  echo -e "${RED}✗ jq is required but not installed.${NC}"
  echo -e "  macOS: ${CYAN}brew install jq${NC}"
  echo -e "  Linux: ${CYAN}apt install jq${NC}"
  exit 1
fi
echo -e "${GREEN}✓${NC} jq found"

OPTIONAL_MISSING=()
command -v gh       &>/dev/null || OPTIONAL_MISSING+=("gh (GitHub CLI) — @username display")
command -v claudelytics &>/dev/null || OPTIONAL_MISSING+=("claudelytics — today/lifetime cost")
command -v codeburn &>/dev/null || OPTIONAL_MISSING+=("codeburn — 7-day rolling cost + cache %")
if [ ${#OPTIONAL_MISSING[@]} -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}Optional tools not found (statusline works without them):${NC}"
  for dep in "${OPTIONAL_MISSING[@]}"; do
    echo -e "  ${DIM}·${NC} $dep"
  done
fi

# ── Ensure ~/.claude exists ──
mkdir -p "$HOME/.claude"

# ── Copy scripts ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.claude/lib"
cp "$SCRIPT_DIR/statusline.sh" "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
cp "$SCRIPT_DIR/lib/compute.sh" "$HOME/.claude/lib/compute.sh"
echo -e "${GREEN}✓${NC} Installed statusline.sh → ~/.claude/statusline.sh"
echo -e "${GREEN}✓${NC} Installed lib/compute.sh → ~/.claude/lib/compute.sh"

# ── Merge statusLine config into settings.json ──
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
  TMP=$(mktemp)

  if jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
    echo -e "${YELLOW}!${NC} statusLine already configured in settings.json — skipping"
    cp "$SETTINGS_FILE" "$TMP"
  else
    jq '. + {"statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh"}}' "$SETTINGS_FILE" > "$TMP"
    echo -e "${GREEN}✓${NC} Added statusLine config to settings.json"
  fi

  mv "$TMP" "$SETTINGS_FILE"
else
  cat > "$SETTINGS_FILE" << EOF
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
EOF
  echo -e "${GREEN}✓${NC} Created settings.json with statusLine config"
fi

# ── Optional: billing start day ──
echo ""
echo -e "${BOLD}Optional Configuration${NC}"
echo ""
read -p "Billing cycle start day (1–28, leave blank for default 1): " BILLING_DAY
if [ -n "$BILLING_DAY" ]; then
  if [ -f "$HOME/.zshrc" ]; then PROFILE="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then PROFILE="$HOME/.bashrc"
  else PROFILE="$HOME/.zshrc"; fi
  echo "" >> "$PROFILE"
  echo "# Claude Code Statusline" >> "$PROFILE"
  echo "export ANTHROPIC_BILLING_START_DAY=\"$BILLING_DAY\"" >> "$PROFILE"
  echo -e "${GREEN}✓${NC} Added ANTHROPIC_BILLING_START_DAY=$BILLING_DAY to $PROFILE"
  echo -e "${DIM}  Run: source $PROFILE${NC}"
fi

echo ""
echo -e "${GREEN}${BOLD}Done!${NC} Restart Claude Code to see your statusline."
echo -e "${DIM}For help: https://github.com/blushdas/claude-code-statusline${NC}"
echo ""
