# Claude Code Statusline

Custom status line script for Claude Code that displays session usage metrics with ANSI color-coded indicators.

## Screenshot

```
~/s/.../my-project │ 12.0% (2h 55m) │ 7d 27.0% │ CTX 10.0%
```

## Display Format

| Segment | Description | Style |
|---------|-------------|-------|
| `~/s/.../my-project` | Compact cwd (leftmost). Paths with 3+ segments are shortened: `~/first_char/.../last_dir` | Cyan |
| `12.0%` | 5-hour rate limit used | Bold + Color |
| `(2h 55m)` | Time until 5-hour window resets | Dim |
| `7d 27.0%` | 7-day rate limit used | Label: Dim, Value: Bold + Color |
| `CTX 10.0%` | Context window used (defaults to 0% after `/clear`) | Label: Dim, Value: Bold + Color |

## Color Thresholds

Percentage values change color based on usage level:

| Usage | Color |
|-------|-------|
| < 20% | Green (Bold) |
| 20-39% | Yellow (Bold) |
| 40-59% | Orange (Bold, 256-color) |
| >= 60% | Red (Bold) |

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

- **Session info** (model, cwd, context): Received via stdin JSON from Claude Code. Context window defaults to 0% usage when data is unavailable (e.g., after `/clear`). CWD is compacted for deep paths: `~/first_char/.../last_dir`
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
