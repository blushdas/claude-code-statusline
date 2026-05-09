# claude-code-statusline

Real-time statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Tracks context health, session cost, and model discipline — all in the status bar at the bottom of your terminal.

![claude-code-statusline screenshot](assets/statusline.png)

## What you get

```
ACT │ @user │ Sonnet 4.6 │ ████████░░░░░░ 67% │ ● ATTENTION
GIT │ claude-code-statusline │ main │ a1b2c3d
CTX │ 67.3k/200k │ $0.0031/1k │ 87% cache
RUN │ $0.29 sesh │ $0.42/min
SUM │ $118 today │ $291 key │ $2054 all │ ↓978k $2.93 rtk │ $466 wk │ 98%⚡
```

**ACT** — GitHub username · model name · context bar + % · health status

**GIT** — repo · branch · short commit (only shown inside a git repo)

**CTX** — tokens used / context limit · cost per 1k tokens · session cache hit %

**RUN** — current session spend · live burn rate ($/min)

**SUM** — today's spend · per-key month-to-date · lifetime total · optional: RTK savings · 7-day cost + cache hit %

## Install

```bash
git clone https://github.com/blushdas/claude-code-statusline.git
cd claude-code-statusline
bash install.sh
```

Restart Claude Code. That's it.

**Only hard requirement: `jq`**

```bash
brew install jq   # macOS
apt install jq    # Linux
```

The installer checks for `jq` and will tell you if it's missing.

## What works out of the box

With just `jq` installed, you get the full ACT / GIT / CTX / RUN rows and the `$X key` segment in SUM (per-key MTD tracked locally). Everything else degrades gracefully — if an optional tool isn't installed, that segment is hidden. Nothing breaks.

## Optional tools

Each one adds a segment. Skip any you don't want.

**`gh` (GitHub CLI)** — shows `@username` in ACT row. Without it: shows `local`.

```bash
brew install gh && gh auth login
```

**`claudelytics`** — adds `$X today` and `$X all` to SUM. Without it: those fields show `?`.

```bash
cargo install claudelytics
```

**`codeburn`** — adds `$X wk │ 98%⚡` (true 7-day rolling cost + cache hit %) to SUM. Without it: segment is hidden.

```bash
brew install codeburn
```

**`rtk` + `sqlite3`** — adds `↓Xk $Y.YY rtk` (today's token savings from RTK compression) to SUM. `sqlite3` ships with macOS. Install RTK from the [RTK repo](https://github.com/rusty-tools/rtk).

## Manual setup

If you'd rather not use the installer:

**1. Copy the script**

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

**2. Add to `~/.claude/settings.json`**

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

If you already have a `settings.json`, merge just the `statusLine` key in — don't replace the file.

**3. Restart Claude Code**

## Configuration

All config via environment variables. Add to `.zshrc` / `.bashrc`:

```bash
export ANTHROPIC_BILLING_START_DAY="15"  # billing cycle start day (default: 1)
export CLAUDE_STATUSLINE_DEBUG="1"        # write debug logs to ~/.claude/.statusline_debug.log
```

## Context rot thresholds

Based on Claude Opus 4.6 Context Management Spec v1.0:

- **0–50%** — green `● healthy`
- **50–75%** — yellow `● ATTENTION` — consider compacting soon
- **75–90%** — orange `● CHECKPOINT` — start wrapping up
- **90–95%** — red `● CRITICAL` — compact now
- **95%+** — red background `◉◉ EMERGENCY` — start a new session

## Opus guard

The statusline flags when Opus is active without a proper planning workflow, so you don't get a surprise bill from an unconstrained Opus session.

- **Opus + Commander workflow executing** → model name in bold magenta (intentional use)
- **Opus + no workflow** → model name flips to `⚠ Opus X.X` on a red background + `OPUS-NO-CMDR` badge

The guard reads `~/.astra/workflow/<session_id>.json`. If you don't use the Astra SDK, Opus will always trigger the warning — this is intentional behavior.

## Data sources

All real-time values come from the Claude Code JSON hook. Background values use a cache-and-refresh pattern (stale-while-revalidate) so the statusline never blocks.

- **context % / tokens** — Claude Code JSON hook, real-time
- **session cost, burn rate** — Claude Code JSON hook, real-time
- **cache hit %** — computed from hook token fields, session-scoped
- **$X today** — claudelytics reads JSONL files, background refresh every 60s
- **$X key** — local accumulator in `~/.claude/.cc_sessions.json`, resets each billing cycle
- **$X all** — claudelytics lifetime total, background refresh every 60s
- **↓Xk rtk** — RTK SQLite history DB, background refresh every 5 min
- **$X wk / cache %** — `codeburn report --period week`, true 7-day rolling total, background refresh every 5 min

**Why do today / key / all show different numbers?** Each uses a different scope:
- `key` = sessions tracked since statusline was installed, current billing cycle, per API key
- `today` = recalculated from all JSONL transcripts claudelytics can see
- `all` = lifetime total across every transcript claudelytics has ever seen

## Persistent files

All in `~/.claude/` — never modify these manually while Claude Code is running.

- `.cc_sessions.json` — peak cost per session (billing MTD accumulator)
- `.cc_billing_month` — current billing period (YYYYMM)
- `.gh_user_cache` — GitHub username (60 min TTL)
- `.claudelytics_today_cache` — today's cost from claudelytics (60s TTL)
- `.claudelytics_total_cache` — lifetime total from claudelytics (60s TTL)
- `.rtk_today_cache` — RTK token savings today (5 min TTL)
- `.codeburn_week_cache` — 7-day cost + cache hit % (5 min TTL)
- `.statusline_state.json` — unified state snapshot for hooks and other tooling

## Troubleshooting

**Statusline not showing?**

Check `~/.claude/settings.json` has the `statusLine` key and restart Claude Code.

**`jq: command not found`**

```bash
brew install jq   # macOS
apt install jq    # Linux
```

**SUM shows `? today` or `? all`?**

```bash
cargo install claudelytics
```

Wait one refresh cycle (60s) after install for the cache to populate.

**Key MTD shows `$0`?**

Normal on first run — the accumulator starts from zero and builds up across sessions. Check the current value:

```bash
jq '[.[]] | add // 0' ~/.claude/.cc_sessions.json
```

Reset manually (e.g. new billing cycle):

```bash
echo '{}' > ~/.claude/.cc_sessions.json
```

**RTK segment not showing?**

RTK needs to have tracked at least one command today. Run `rtk gain` to confirm it's working.

**GitHub username not showing?**

```bash
gh auth status        # verify login
cat ~/.claude/.gh_user_cache   # check cached value
```

Cache refreshes every 60 minutes. Delete the cache file to force an immediate refresh.

**CodeBurn segment not showing?**

```bash
codeburn report --period week --format json   # verify it returns data
```

If the command works, the cache will populate on next statusline tick.

## License

MIT — see [LICENSE](LICENSE)
