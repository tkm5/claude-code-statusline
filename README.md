# Claude Code Statusline

Custom status line script for Claude Code that displays session usage metrics with ANSI color-coded indicators.

## Screenshot

```
~/.claude │ $5.85 │ 88.0% (2h 55m) │ 7d 73.0% │ CTX 90.0%
```

## Display Format

| Segment | Description | Style |
|---------|-------------|-------|
| `~/.claude` | Current working directory (leftmost) | Cyan |
| `$5.85` | Session cost (USD) | Dim |
| `88.0%` | 5-hour rate limit remaining | Bold + Color |
| `(2h 55m)` | Time until 5-hour window resets | Dim |
| `7d 73.0%` | 7-day rate limit remaining | Label: Dim, Value: Bold + Color |
| `CTX 90.0%` | Context window remaining (defaults to 100% after `/clear`) | Label: Dim, Value: Bold + Color |

## Color Thresholds

Percentage values change color based on remaining capacity:

| Remaining | Color |
|-----------|-------|
| >= 80% | Green (Bold) |
| 60-79% | Yellow (Bold) |
| 40-59% | Orange (Bold, 256-color) |
| < 40% | Red (Bold) |

## Setup

### Prerequisites

- `jq` (JSON parser)

```bash
brew install jq
```

### Installation

1. Copy `statusline.sh` to `~/.claude/`:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

2. Add the `statusLine` field to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

3. (Optional) If OAuth usage API returns 401, re-login to get the required scope:

```bash
claude auth logout
claude auth login
```

## How It Works

### Data Sources

- **Session info** (model, cwd, cost, context): Received via stdin JSON from Claude Code. Context window defaults to 100% when data is unavailable (e.g., after `/clear`)
- **Rate limits** (5h, 7d): Fetched from Anthropic OAuth Usage API (`/api/oauth/usage`)
- **Fallback**: `ccusage` CLI tool (if installed and OAuth is unavailable)

### Caching

- OAuth responses are cached at `/tmp/oauth-usage-cache.json` with a 60-second TTL
- Uses stale-while-revalidate: returns cached data immediately while refreshing in background
- `ccusage` fallback uses a 5-minute TTL at `/tmp/ccusage-cache.json`

### ANSI Color Strategy

- Uses `$'...'` bash syntax to store real escape bytes in variables (avoids `printf` `%` interpretation issues)
- Output via `echo -n` instead of `printf` to prevent format string injection from `%` in percentage values
- Reset code placed before a space character to prevent terminal rendering artifacts (dim bleed)

## Credits

Based on [Claude Code session remaining display](https://zenn.dev/shivase/articles/022-claude-code-statusline-session-remaining) by shivase.
