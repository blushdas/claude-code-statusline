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

if ! command -v bc &>/dev/null; then
  MISSING+=("bc")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${YELLOW}Missing dependencies:${NC}"
  for dep in "${MISSING[@]}"; do
    echo -e "  ${RED}✗${NC} $dep"
  done
  echo ""
  echo -e "Install with: ${CYAN}brew install jq gh${NC} (macOS) or ${CYAN}apt install jq gh bc${NC} (Linux)"
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

mkdir -p "$HOME/.claude/scripts"
cp "$SCRIPT_DIR/scripts/refresh-api-cost.sh" "$HOME/.claude/scripts/refresh-api-cost.sh"
chmod +x "$HOME/.claude/scripts/refresh-api-cost.sh"
echo -e "${GREEN}✓${NC} Installed refresh-api-cost.sh to ~/.claude/scripts/refresh-api-cost.sh"

# ── Merge statusLine config into settings.json ──
SETTINGS_FILE="$HOME/.claude/settings.json"

HOOK_CMD="bash ~/.claude/scripts/refresh-api-cost.sh"

if [ -f "$SETTINGS_FILE" ]; then
  TMP=$(mktemp)

  # Add statusLine if missing
  if jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
    echo -e "${YELLOW}!${NC} statusLine already configured in settings.json — skipping"
    cp "$SETTINGS_FILE" "$TMP"
  else
    jq '. + {"statusLine": {"type": "command", "command": "bash ~/.claude/statusline.sh"}}' "$SETTINGS_FILE" > "$TMP"
    echo -e "${GREEN}✓${NC} Added statusLine config to settings.json"
  fi

  # Add SessionStart hook if missing
  if jq -e '.hooks.SessionStart' "$TMP" &>/dev/null; then
    echo -e "${YELLOW}!${NC} SessionStart hook already configured — skipping"
  else
    TMP2=$(mktemp)
    jq --arg cmd "$HOOK_CMD" '.hooks.SessionStart += [{"type": "command", "command": $cmd}]' "$TMP" > "$TMP2"
    mv "$TMP2" "$TMP"
    echo -e "${GREEN}✓${NC} Added SessionStart hook to settings.json"
  fi

  mv "$TMP" "$SETTINGS_FILE"
else
  # Create new settings.json
  cat > "$SETTINGS_FILE" << EOF
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  },
  "hooks": {
    "SessionStart": [
      {"type": "command", "command": "$HOOK_CMD"}
    ]
  }
}
EOF
  echo -e "${GREEN}✓${NC} Created settings.json with statusLine and SessionStart hook"
fi

# ── Optional: Environment variables ──
echo ""
echo -e "${BOLD}Optional Configuration${NC}"
echo -e "${DIM}These environment variables enable extra features.${NC}"
echo -e "${DIM}You can skip these and add them later to your shell profile.${NC}"
echo ""

# Obsidian vault
read -p "Obsidian vault path (leave blank to skip): " VAULT_PATH
if [ -n "$VAULT_PATH" ]; then
  # Expand ~ if present
  VAULT_PATH="${VAULT_PATH/#\~/$HOME}"
  if [ -d "$VAULT_PATH" ]; then
    echo -e "${GREEN}✓${NC} Vault found: $VAULT_PATH"
    EXPORT_VAULT="export OBSIDIAN_VAULT=\"$VAULT_PATH\""
  else
    echo -e "${YELLOW}!${NC} Directory not found — saving anyway"
    EXPORT_VAULT="export OBSIDIAN_VAULT=\"$VAULT_PATH\""
  fi
fi

# Admin API key
echo ""
echo -e "${DIM}An Anthropic Admin API key enables month-to-date API spend tracking.${NC}"
echo -e "${DIM}Get one at: https://console.anthropic.com/settings/admin-keys${NC}"
read -p "Anthropic Admin API key (leave blank to skip): " ADMIN_KEY
if [ -n "$ADMIN_KEY" ]; then
  EXPORT_KEY="export ANTHROPIC_ADMIN_API_KEY=\"$ADMIN_KEY\""
fi


# ── Write to shell profile ──
if [ -n "$EXPORT_VAULT" ] || [ -n "$EXPORT_KEY" ]; then
  echo ""

  # Detect shell profile
  if [ -f "$HOME/.zshrc" ]; then
    PROFILE="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    PROFILE="$HOME/.bashrc"
  elif [ -f "$HOME/.bash_profile" ]; then
    PROFILE="$HOME/.bash_profile"
  else
    PROFILE="$HOME/.zshrc"
  fi

  read -p "Add env vars to $PROFILE? (Y/n) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo "" >> "$PROFILE"
    echo "# Claude Code Statusline" >> "$PROFILE"
    [ -n "$EXPORT_VAULT" ] && echo "$EXPORT_VAULT" >> "$PROFILE"
    [ -n "$EXPORT_KEY" ] && echo "$EXPORT_KEY" >> "$PROFILE"
    echo -e "${GREEN}✓${NC} Added environment variables to $PROFILE"
    echo -e "${DIM}  Run: source $PROFILE${NC}"
  else
    echo ""
    echo "Add these to your shell profile manually:"
    [ -n "$EXPORT_VAULT" ] && echo "  $EXPORT_VAULT"
    [ -n "$EXPORT_KEY" ] && echo "  $EXPORT_KEY"
  fi
fi

# ── Install launchd daemon (macOS only) ──
if [[ "$OSTYPE" == "darwin"* ]] && [ -n "$ADMIN_KEY" ]; then
  PLIST_SRC="$SCRIPT_DIR/launchd/com.astra.claude-cost-refresh.plist"
  PLIST_DEST="$HOME/Library/LaunchAgents/com.astra.claude-cost-refresh.plist"
  BILLING_DAY_VAL="${ANTHROPIC_BILLING_START_DAY:-01}"

  echo ""
  read -p "Install hourly cost refresh daemon via launchd? (Y/n) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    sed \
      -e "s|YOUR_USERNAME|$(whoami)|g" \
      -e "s|YOUR_ANTHROPIC_ADMIN_API_KEY|$ADMIN_KEY|g" \
      -e "s|<string>01</string>|<string>$BILLING_DAY_VAL</string>|" \
      "$PLIST_SRC" > "$PLIST_DEST"

    # Unload existing if running
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load "$PLIST_DEST"
    echo -e "${GREEN}✓${NC} Launchd daemon installed and loaded (runs hourly)"
    echo -e "${DIM}  Logs: /tmp/claude-cost-refresh.log${NC}"
  else
    echo -e "${DIM}  Skipped. To install later: launchctl load $PLIST_DEST${NC}"
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}Done!${NC} Restart Claude Code to see your statusline."
echo -e "${DIM}For help: https://github.com/blushdas/claude-code-statusline${NC}"
echo ""
