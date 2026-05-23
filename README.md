# claude-usage-bar

[![build](https://github.com/meduzkin/claude-usage-bar/actions/workflows/build.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/build.yml)
[![shellcheck](https://github.com/meduzkin/claude-usage-bar/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/shellcheck.yml)
[![codeql](https://github.com/meduzkin/claude-usage-bar/actions/workflows/codeql.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/codeql.yml)
[![gitleaks](https://github.com/meduzkin/claude-usage-bar/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/gitleaks.yml)

> macOS menu-bar widget for AI coding agents — desktop notifications when Claude Code blocks on a permission prompt, threshold alerts on usage windows, and unified usage bars across Claude / Codex / Gemini / Copilot.

![claude-usage-bar dropdown](docs/screenshot.png?v=0.5.3)

## Notifications

Two independent nudges, both opt-in from **ALERTS & NOTIFICATIONS** in the dropdown.

- **Permission prompt** — when Claude Code blocks on a confirmation (`Notification` / `Stop` / `PreToolUse` hooks), pops a macOS notification, plays a sound, and re-focuses your terminal if the wait exceeds your configured delay. Delay options: 30 / 60 / 120 / 300 s. Bell turns blue when on. Toggling only touches the three hooks the widget owns in `~/.claude/settings.json` — your other hooks stay.
- **Usage threshold** — multi-select tiers 25 / 50 / 75 / 90 / 95 %. Each enabled tier fires once per 5-hour window the first time utilization crosses it, then re-arms on the next window. Triangle turns orange when on. State at `~/.cache/claude-usage-bar/alert.json`.

## At a glance

Status-bar title is `[bar] NN%`. Tooltip carries the rest: `Claude · session 37% · resets in 1h 27m · week 12%`.

Right-click the icon to refresh without opening the dropdown.

## Dropdown

Per-provider section (only rendered when credentials exist locally). Each bucket is a single compact row:

```
✱ Claude
updated 16:50 · OAuth

Session    ████░░░░░░░░    82.0%  ·  0h 47m
Weekly     █░░░░░░░░░░░     9.0%  ·  6d 19h
pace       lasts until reset  ·  +$15.71 more
Sonnet     ░░░░░░░░░░░░     0.0%
```

- **Claude** — `Session` (5h), `Weekly` (7d), `Opus`, `Sonnet`. Green <60%, yellow 60–85%, red >85%. Adapts to dark/light mode.
- **Codex** — from `~/.codex/auth.json`, with a JSON-RPC `via app-server` fallback when HTTP is rate-limited.
- **Gemini** — per-model quotas from Google's Code Assist API.
- **Copilot** — `Chat` / `Completions` / `Premium` from `api.github.com/copilot_internal/user`.
- **pace** — projection under `Weekly`: `lasts until reset` / `lasts until reset (tight)` / `runs out in 1h 06m`, colour follows meaning. Appends `· +$X.XX more` when `ccusage` has the active block.
- **service status** — top-of-dropdown badge when `status.anthropic.com` reports a minor / major / critical incident.
- **details ▸ / daily ▸ / weekly ▸** — active 5h block (cost / tokens / burn) and the last 7d / 4w totals.
- **refresh interval ▸** — 5 / 10 / 15 / 20 / 30 min (default 10). Background poll + on-open with a 30 s cooldown.
- **Check for updates…** — self-update from GitHub or GitLab Releases (source picked at install time).

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
- **`main.swift`** — Cocoa app with `NSStatusItem`, refreshes every `refresh interval` minutes (user-configurable from the dropdown; default 10) **plus** every time you open the dropdown (with a 30-second cooldown to avoid spamming the rate-limited endpoint). Each row in the data section is wrapped in a custom `NSView` with an opaque background so the dropdown reads more solidly than the default vibrancy material.
- **`build.sh`** — produces a universal binary (`swiftc` + `lipo` over arm64 and x86_64 slices, target `macos12`).
- **Single-instance guard** — on launch the GUI process acquires a BSD `flock(LOCK_EX | LOCK_NB)` on `~/.cache/claude-usage-bar/widget.lock`. A second launch (LaunchAgent + manual run, a self-update that didn't terminate the prior process, a Finder double-click) sees the lock and exits cleanly. The kernel auto-releases on process death, so stale lock files never wedge future launches. `--headless` bypasses the lock.

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
