# claude-code-statusline

A real-time statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that tracks context usage, costs, and optionally logs sessions to Obsidian.

## What It Shows

```
@user | Claude 4 Opus | ████████░░░░ 67% | ● ATTENTION
$0.0031/1k · 67.3k/200k  $0.29 sesh · $0.42/min  $118 today · $291 CC · $371 org  ↓978k rtk
```

**Row 1:** GitHub username · model name · context bar · health status

**Row 2** (grouped left-to-right, micro → macro):
- **Rate:** `$/1k tokens · tokens used/limit` — efficiency at a glance
- **Session:** `$ session · $/min burn rate` — what this session is costing
- **Aggregates:** `$ today · $ CC (month-to-date) · $ org (Admin API)` — bigger picture
- **RTK savings:** `↓Xk rtk` — tokens saved today by RTK compression (optional, if RTK installed)

**Row 3** (optional): Astra Agent SDK status — agent count, workflow state, error count

## Features

- **Context rot tracking** — visual progress bar with color-coded health warnings (5 tiers)
- **Real-time cost** — per-1k-token rate, session total, and burn rate ($/min)
- **Today's cost** — live daily spend pulled from claudelytics (cached 5 min, background refresh)
- **CC spend** — per-key month-to-date cost tracked locally from Claude Code sessions
- **Org spend** — total Anthropic API spend via Admin API (optional, cached hourly)
- **RTK integration** — today's token savings from RTK compression (optional, background refresh)
- **GitHub identity** — shows your `@username` from `gh` CLI
- **Cost alerts** — `⚠ $X.XXXX BURN` at $3+ (red), `⚠ BURN` badge at $5+ (red background)
- **Obsidian logging** — auto-generates daily session tables (optional)

## Quick Install

```bash
git clone https://github.com/blushdas/claude-code-statusline.git
cd claude-code-statusline
bash install.sh
```

The installer will:
1. Copy `statusline.sh` to `~/.claude/statusline.sh`
2. Add the `statusLine` config to `~/.claude/settings.json` (preserves existing settings)
3. Optionally prompt for environment variables and launchd daemon

## Manual Setup

### 1. Copy the script

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 2. Add to settings

Add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

### 3. Restart Claude Code

The statusline appears at the bottom of your terminal.

## Configuration

All configuration is via environment variables. Add these to your `.zshrc` / `.bashrc`:

| Variable | Required | Description |
|----------|----------|-------------|
| `OBSIDIAN_VAULT` | No | Path to your Obsidian vault for session logging |
| `ANTHROPIC_ADMIN_API_KEY` | No | Admin API key for org-wide spend tracking |
| `ANTHROPIC_BILLING_START_DAY` | No | Day of month your billing cycle starts (default: 01) |
| `CLAUDE_STATUSLINE_DEBUG` | No | Set to `1` for diagnostic logs at `~/.claude/.statusline_debug.log` |

### Example `.zshrc`

```bash
# Claude Code Statusline
export OBSIDIAN_VAULT="$HOME/Documents/MyVault"
export ANTHROPIC_ADMIN_API_KEY="sk-ant-admin01-..."
export ANTHROPIC_BILLING_START_DAY="15"
```

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `jq` | **Yes** | JSON parsing |
| `gh` | Yes (soft) | GitHub username display |
| `curl` | For org spend | Anthropic Admin API calls |
| `claudelytics` | No | Today's cost display (background, cached 5 min) |
| `sqlite3` | No | RTK savings display (background, cached 5 min) |

No `bc` required — all float math uses `awk`.

## Context Rot Thresholds

Based on Claude Opus 4.6 Context Management Spec v1.0:

| Threshold | Color | Status | Meaning |
|-----------|-------|--------|---------|
| 0–50% | 🟢 Green | `● healthy` | Normal operation |
| 50–75% | 🟡 Yellow | `● ATTENTION` | Consider compacting soon |
| 75–90% | 🟠 Orange | `● CHECKPOINT` | Start wrapping up |
| 90–95% | 🔴 Red | `● CRITICAL` | Context degraded — compact now |
| 95%+ | 🔴 Red bg | `◉◉ EMERGENCY` | Start new session immediately |

## Data Sources

Each number in Row 2 comes from a different source:

| Display | Source | Freshness |
|---------|--------|-----------|
| `$/1k` | Claude Code JSON pipe | Real-time |
| `tokens/limit` | Claude Code JSON pipe | Real-time |
| `$ session` | Claude Code JSON pipe | Real-time |
| `$/min` | Calculated from session cost + duration | Real-time |
| `$ today` | claudelytics → JSONL files | 5 min cache |
| `$ CC` | Local accumulator (`.cc_sessions.json`) | Per-tick |
| `$ org` | Anthropic Admin API cache | 1 hour cache |
| `↓Xk rtk` | RTK SQLite DB | 5 min cache |

**Why do the numbers differ?** Each uses a different methodology:
- **CC** = sum of peak costs per session, tracked locally since statusline was installed
- **today** = recalculated from token counts in JSONL files by claudelytics (most accurate)
- **org** = Anthropic's billing API, includes all API usage (not just Claude Code)

## Persistent Files

All state is stored in `~/.claude/`:

| File | Purpose | TTL |
|------|---------|-----|
| `.cc_sessions.json` | Peak cost per session (billing MTD) | Monthly reset |
| `.cc_billing_month` | Current billing YYYYMM | Monthly |
| `.gh_user_cache` | GitHub username | 60 min |
| `.api_cost_cache` | Org-wide Admin API cost | 1 hour |
| `.claudelytics_today_cache` | Today's cost from claudelytics | 5 min |
| `.rtk_today_cache` | RTK savings today | 5 min |

## Obsidian Integration

When `OBSIDIAN_VAULT` is set, the statusline creates daily notes at:

```
{OBSIDIAN_VAULT}/Claude Sessions/Claude Sessions — 2025-03-15.md
```

Each note contains a live-updating table:

| Time | Model | Context% | $/1k tokens | Session $ | Tokens | Git Branch | Status |
|------|-------|----------|-------------|-----------|--------|------------|--------|
| 14:22:01 | Claude 4 Opus | 23% | $0.0029 | $0.04 | ~14k | main | healthy |

Plus a footer with month-to-date API spend and today's total.

## API Spend Tracking

To track your total Anthropic API spend:

1. Go to [console.anthropic.com/settings/admin-keys](https://console.anthropic.com/settings/admin-keys)
2. Create an Admin API key
3. Set `ANTHROPIC_ADMIN_API_KEY` in your shell profile

The installer can also set up a **hourly launchd daemon** (macOS) to refresh the org cost cache in the background.

Test your API key setup:
```bash
bash ~/.claude/statusline.sh --test-api
```

## Troubleshooting

**Statusline not showing?**
- Make sure `~/.claude/settings.json` has the `statusLine` config
- Restart Claude Code after making changes

**`jq: command not found`**
- Install jq: `brew install jq` (macOS) or `apt install jq` (Linux)

**CC cost shows $0.00?**
- Costs accumulate from Claude Code sessions as you use it
- The counter resets each billing cycle (`ANTHROPIC_BILLING_START_DAY`)
- Check current total: `jq '[.[]] | add // 0' ~/.claude/.cc_sessions.json`
- Reset manually: `echo '{}' > ~/.claude/.cc_sessions.json`

**Today cost shows `?`?**
- Install claudelytics: `cargo install claudelytics`
- On first run, the cache needs to populate — wait one tick after install

**RTK savings not showing?**
- Install RTK and ensure it has tracked at least one command today
- Check: `~/.local/bin/rtk gain --format json`

**GitHub username not showing?**
- Make sure you're logged in: `gh auth status`
- Cache refreshes every 60 minutes: `cat ~/.claude/.gh_user_cache`

## License

MIT — see [LICENSE](LICENSE)
