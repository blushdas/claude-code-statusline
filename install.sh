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
MISSING=()

if ! command -v jq &>/dev/null; then
  MISSING+=("jq")
fi

if ! command -v gh &>/dev/null; then
  MISSING+=("gh (GitHub CLI)")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${YELLOW}Missing dependencies:${NC}"
  for dep in "${MISSING[@]}"; do
    echo -e "  ${RED}✗${NC} $dep"
  done
  echo ""
  echo -e "Install with: ${CYAN}brew install jq gh${NC} (macOS) or ${CYAN}apt install jq gh${NC} (Linux)"
  echo ""
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# ── Ensure ~/.claude exists ──
mkdir -p "$HOME/.claude"

# ── Copy scripts ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/statusline.sh" "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
echo -e "${GREEN}✓${NC} Installed statusline.sh to ~/.claude/statusline.sh"

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
