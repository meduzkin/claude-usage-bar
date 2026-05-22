# claude-usage-bar

> Native macOS menu bar widget that surfaces Claude Code's `/usage` view at a glance — coloured progress bars for your subscription's 5-hour and 7-day rate-limit windows, plus per-session cost overlay from [`ccusage`](https://www.npmjs.com/package/ccusage).

<!-- Drop a screenshot at docs/screenshot.png — Cmd+Shift+4 around the dropdown works well. -->
![claude-usage-bar dropdown](docs/screenshot.png)

The menu bar title reads `session 37% · 87m` — **37%** of your current 5-hour rate-limit window is consumed and the window resets in **87 minutes**. The same numbers Claude Code shows when you type `/usage` in an interactive session, except always visible.

## Why

`/usage` only works inside an interactive Claude Code session (`claude -p "/usage"` returns a stub). This widget calls the same backend endpoint Claude Code uses (`/api/oauth/usage`) with the OAuth token Claude Code already keeps in your macOS keychain, then layers `ccusage`'s cost estimates on top of the raw utilization percentages.

## What's in the dropdown

- **plan usage (Claude)** — colored progress bars for `current session` (5h), `current week` (7d), `current week opus`, `current week sonnet`. Green <60%, yellow 60–85%, red >85%. Colors adapt to dark/light mode.
- **plan usage (Codex)** — same shape, fetched from OpenAI's `chatgpt.com/backend-api/wham/usage`. Only shown when `~/.codex/auth.json` exists.
- **plan usage (Gemini)** — per-model quota buckets from Google's Code Assist API (`cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`). Only shown when `~/.gemini/oauth_creds.json` exists.
- **plan usage (Copilot)** — chat / completions / premium interactions from GitHub's `api.github.com/copilot_internal/user`. Token discovered from `~/.copilot/config.json`, `~/.config/gh/hosts.yml`, the macOS keychain (`gh-cli`), or `$GITHUB_TOKEN`. Only shown when a token is found.
- **5h block** — cost, tokens, projected total, burn rate, reset time (from ccusage).
- **last session** — most recent session cost, tokens, last activity.
- **daily ▸** / **weekly ▸** — submenus with the last 7 days / 4 weeks of cost & token totals.
- **notifications** + **delay ▸** — toggle macOS popup + sound + terminal-activate when Claude Code waits on a permission prompt longer than N seconds. Delay options: 30s / 60s / 120s / 300s. State is read from / written to `~/.claude/settings.json` atomically.
- **alert** + **thresholds ▸** — multi-select threshold tiers (25 / 50 / 75 / 90 / 95). Each enabled tier posts a macOS notification the first time the 5h utilization crosses it. Independently tracked per tier — a new 5h window re-arms all of them.
- **refresh interval ▸** — how often the widget polls `/api/oauth/usage` in the background. Options: 5 / 10 / 15 / 20 / 30 minutes (default 10). Picking a value reschedules the timer immediately and persists the choice to `~/.cache/claude-usage-bar/interval.json`. The dropdown still triggers an on-open refresh with a 30 s cooldown regardless.
- **pace projection** — inside `plan usage`, an extra `pace` line shows the projected end-of-window utilization at the current burn rate (e.g. `→ 87% projected at reset · +$12.50 more` or `⚠ 142% at reset (hits 100% in 38m) · +$28 more`). Colour matches the projected tier. When the ccusage active block is available, the line also estimates the additional spend before reset.
- **service status badge** — when `status.anthropic.com` reports a minor / major / critical incident, the widget surfaces it at the top of the dropdown with the upstream description. Cleared once Anthropic flips back to "All Systems Operational".
- **Check for updates…** — menu action that hits the release source's API, compares against the embedded `WIDGET_VERSION`, and (on user confirm) downloads + atomically replaces the running binary + relaunches. Source is configurable via `~/.cache/claude-usage-bar/update.json` (written by `install.sh`); both GitHub and GitLab Releases API shapes are supported.
- **Right-click the menu-bar icon** to trigger an immediate refresh without opening the dropdown.
- Refresh now (⌘R), Check for updates…, Quit (⌘Q).

The notifications feature is hook-based: when enabled, three entries are added to `~/.claude/settings.json` (`Notification`, `Stop`, `PreToolUse`) pointing at scripts installed at `~/.claude/scripts/`. Toggling off removes only those three entries — any other hooks you have in `settings.json` are preserved.

The usage alert is self-contained — the widget reads utilization from its regular refresh, fires `osascript` directly, and persists `{enabled, threshold, alertedWindowResetsAt}` to `~/.cache/claude-usage-bar/alert.json`.

## Install

```bash
git clone https://github.com/meduzkin/claude-usage-bar.git
cd claude-usage-bar
./install.sh
```

That:

1. Checks prerequisites (`python3`, `jq`, `npx`/`ccusage`, plus `curl` or `swiftc` depending on path) and exits with a clear error if anything is missing.
2. Triggers the macOS keychain prompt so you can click **Always Allow** during install rather than at first widget launch.
3. Gets the binary one of two ways:
   - **`swiftc` available** (Xcode Command Line Tools installed) → builds a universal binary from source.
   - **`swiftc` not available** → downloads the pre-built universal binary from this repo's [latest GitHub Release](https://github.com/meduzkin/claude-usage-bar/releases/latest).
4. Optionally registers a LaunchAgent at `~/Library/LaunchAgents/com.local.claude-usage-bar.plist` so the widget starts at login.

Flags:

- `./install.sh --autostart` — non-interactive, installs the LaunchAgent without prompting.
- `./install.sh --build` — force build from source (requires `swiftc`).
- `./install.sh --download` — skip building, always pull the release artifact.

To remove: `./uninstall.sh` (stops the widget and removes the LaunchAgent; the binary and keychain ACL stay).

## Requirements

- macOS (uses Cocoa / `NSStatusItem`)
- An active Claude Code login on this Mac — creates the `Claude Code-credentials` keychain entry the widget reads
- `python3` on `PATH` (parses keychain JSON and merges ccusage output)
- `jq` on `PATH` (used by the notification hook scripts)
- `node` / `npx` on `PATH` (for [`ccusage`](https://www.npmjs.com/package/ccusage); a globally installed `ccusage` is preferred and faster)
- One of:
  - **Swift toolchain** (`xcode-select --install`) — for `install.sh` to build from source. About 1 GB on disk; the install itself takes a couple of seconds after the toolchain is in place.
  - **`curl`** — for `install.sh` to download the pre-built universal binary from the [latest GitHub Release](https://github.com/meduzkin/claude-usage-bar/releases/latest). No Xcode needed.

## How auth works

The widget reads the access token directly from the macOS keychain entry `Claude Code-credentials` via:

```bash
security find-generic-password -s "Claude Code-credentials" -w
```

Claude Code itself creates and refreshes that entry — the widget only reads. The first time `security` runs, macOS pops the standard "an application wants to access keychain" dialog. Click **Always Allow** and subsequent reads from `usage.sh` (which calls the same `/usr/bin/security` binary) are silent.

For headless / CI setups, set `CLAUDE_CREDS=/path/to/file` and `usage.sh` reads the same `{"claudeAiOauth": {...}}` JSON from that file instead.

## How it works

- **`usage.sh`** — resolves the OAuth token, calls `https://api.anthropic.com/api/oauth/usage` with the `anthropic-beta: oauth-2025-04-20` header for plan utilization, runs `ccusage` (`blocks --active`, `daily`, `weekly`, `session`) for cost data, optionally calls `scripts/codex-usage.sh` to grab OpenAI Codex's rate limits (`/backend-api/wham/usage`), and merges everything into one JSON blob via inline `python3`.
- Successful API responses are cached at `~/.cache/claude-usage-bar/oauth.json`. The endpoint rate-limits aggressively (429s within a few requests per minute), so on failure the widget falls back to the cached response — the bars stay visible even when the endpoint refuses to talk to us.
- On a `401` `usage.sh` re-reads from keychain and retries once, in case Claude Code rotated the token.
- **`main.swift`** — Cocoa app with `NSStatusItem`, refreshes every `refresh interval` minutes (user-configurable from the dropdown; default 10) **plus** every time you open the dropdown (with a 30-second cooldown to avoid spamming the rate-limited endpoint). All menu items wrap their content in custom `NSView`s with opaque backgrounds so the dropdown reads more solidly than the default vibrancy material.
- **`build.sh`** — produces a universal binary (`swiftc` + `lipo` over arm64 and x86_64 slices).

## Claude Code statusline

The repo ships `scripts/statusline.sh`. `install.sh` drops it into `~/.claude/scripts/` along with the notification hooks. Wire it into Claude Code's statusline by setting in `~/.claude/settings.json`:

```json
{
  "statusline": { "command": "~/.claude/scripts/statusline.sh" }
}
```

The script reads only from the local cache (`~/.cache/claude-usage-bar/oauth.json`) so it adds zero network latency to your prompts. Output: `<color>NN%<reset> →PP% · Mh MMm`, where `NN` is current 5h utilization (colour-tiered), `PP` is projected end-of-window pace, and `Mh MMm` is time to reset.

## Multi-provider

The widget tracks four coding-assistant providers in one pane. Each provider section appears only when the widget finds credentials for that provider on disk. If you don't use a given assistant, its section just doesn't render — no extra config, no flags to toggle.

| Provider | Token source | Endpoint hit |
|---|---|---|
| **Claude (Code)** | macOS keychain entry `Claude Code-credentials` | `api.anthropic.com/api/oauth/usage` (official) |
| **OpenAI Codex** | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` (undocumented) |
| **Gemini Code Assist** | `~/.gemini/oauth_creds.json` | `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (undocumented; via `:loadCodeAssist` for project id) |
| **GitHub Copilot** | `~/.copilot/config.json`, `~/.config/gh/hosts.yml`, keychain (`gh-cli`), or `$GITHUB_TOKEN` | `api.github.com/copilot_internal/user` (undocumented) |

**Codex two-path resolution** — `scripts/codex-usage.sh` tries the HTTP `wham/usage` endpoint first (fast, no subprocess). If it fails or returns garbage, it falls back to spawning `codex -s read-only -a untrusted app-server` and talking JSON-RPC over stdin/stdout (`initialize` + `account/rateLimits/read`). The subprocess is explicitly torn down on exit so we don't leak `codex app-server` zombies — that was a notable bug in ClaudeBar at one point.

**Stale credentials hint** — when the auth file's `last_refresh` is older than the 8-day Codex refresh window, the section header gets a yellow `(token stale — run codex to refresh)` annotation. Same idea applies (less explicitly) to other providers — they'll just disappear when their token rots, prompting a manual re-login.

Caveats with the undocumented providers (everyone except Claude):

- Field names drift across CLI versions; each script tries multiple common shapes and silently falls back to `{}` on schema mismatch.
- No active token refresh implemented for Gemini/Codex/Copilot (would need extracting embedded `client_id`/`client_secret` from the CLI binaries — fragile). If the cached token has expired, run the provider's own CLI once (`codex`, `gemini`, `gh auth login`, `copilot auth`) and the cache is refreshed locally.
- Account-id detection is best-effort. If your provider's response shape doesn't match what the script expects, the section just won't render.

## Headless mode

For SSH sessions, Mac minis without a display, scripts, cron jobs, or anything that doesn't want a menu bar — run the binary with `--headless`:

```bash
$ claude-usage-bar --headless
session 7% · 4h 41m · pace ⚠ 111% · week 30%

$ claude-usage-bar --headless --json
{
  "minutes_left" : 280,
  "pace_projected" : 105,
  "service_description" : "All Systems Operational",
  "service_indicator" : "none",
  "session" : 7,
  "week" : 30
}
```

The text form is a single line, suitable for prompt-PS1 use or grepping. The JSON form gives structured fields for scripting / monitoring stacks.

## Cross-platform (Linux / Windows)

`cross-platform/` contains a Python + `pystray` proof of concept covering the core surface — tray badge, dropdown with alert / threshold / interval / refresh, service-status tooltip. See [`cross-platform/README.md`](cross-platform/README.md). The Swift app remains the canonical implementation on macOS; the Python tray is for non-Mac machines where the Swift binary doesn't run.

## Known limits

- The `/api/oauth/usage` endpoint is throttled. The background refresh interval is user-configurable (5/10/15/20/30 min; default 10) and the dropdown on-open refresh is gated by a 30-second cooldown. If you hit a 429 anyway, the widget shows cached values until the next successful call.
- `ccusage` cost figures are estimates from local JSONL session files and won't exactly match Anthropic's internal billing.
- No notarization / code signing — macOS Gatekeeper may warn on first launch if the binary was downloaded as a zip (cloning via git is fine, no quarantine attribute is set).

## Disclaimer

This is an unofficial community tool, not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic. It reads the OAuth token Claude Code already stored on your machine and calls a public Anthropic API endpoint; it does not bypass any auth, send any data anywhere else, or modify your Claude Code installation.

## License

Apache 2.0 — see [LICENSE](LICENSE).
