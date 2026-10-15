# claude-usage-bar

[![build](https://github.com/meduzkin/claude-usage-bar/actions/workflows/build.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/build.yml)
[![shellcheck](https://github.com/meduzkin/claude-usage-bar/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/shellcheck.yml)
[![codeql](https://github.com/meduzkin/claude-usage-bar/actions/workflows/codeql.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/codeql.yml)
[![gitleaks](https://github.com/meduzkin/claude-usage-bar/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/meduzkin/claude-usage-bar/actions/workflows/gitleaks.yml)

> macOS menu-bar widget for AI coding agents. It lists your running Claude Code sessions and shows which ones wait on you, notifies you when a session blocks on a permission prompt or finishes a long job, alerts on usage thresholds, and shows usage bars for Claude / Codex / Gemini / Copilot.

![claude-usage-bar dropdown](docs/screenshot.png?v=0.6.0)

## Sessions

The top of the dropdown lists the Claude Code sessions running on this Mac, from `claude agents --json`, with their titles; sessions that wait on you come first:

```
SESSIONS   5 open · 1 busy · 2 waiting
✋ api-gateway-3f  OPS-1204  waiting 3m  Rate limiter for the public API   ›
✋ infra-7c        OPS-1198  waiting 1m  Terraform plan for the new cache… ›
●  web-app-29      WEB-311   busy        Checkout page performance         ›
○  infra-8c        OPS-1150 ✓ idle 25m   Monthly impact report review      ›
✱ Claude
Session  ████░░░░░░░░  31.0% ·  2h 09m
Weekly   █░░░░░░░░░░░  12.0% ·  4d 23h
pace     lasts until reset · +$10.70 more
details                                               ›
◇  Codex   ━──── 12% · 3h 09m · wk 7%                 ›
◆  Jira    ━━━━─ 6h 15m / 8h · 1 no task              ›
Settings ›   Refresh now   Quit
```

- **State**: `waiting` means the session is blocked on a permission prompt (set by the notification hook, cleared when you answer); `busy` and `idle` come from Claude Code. Waiting sessions are listed first, longest wait on top.
- **Name** is the one Claude Code shows in `claude agents` and agent view, and the name other sessions use to message this one.
- **Title** is the session's title: the one you set with `/rename`, or the one Claude Code generated from your first prompt.
- **Task** (optional): a ticket key from the session's metadata file (see [Session metadata](#session-metadata-optional)), else from the session title (`/rename OPS-77 cache cluster`), else from the git branch of its working directory (`WEB-12-checkout`). With [Jira](#jira-optional) connected, the key gets its status; a task marked done (`✓`, red) means the session still works in a ticket that is already closed.
- The menu-bar title shows `✋ N` while N sessions wait on you, and the tooltip names them.
- Each row has a submenu: open the task, bring the session's terminal (VS Code, iTerm, Terminal…) to the front, copy `cd <dir> && claude --resume <id>`, copy the session name, reveal the transcript in Finder.
- More than 8 sessions: the rest go under `N more ›`.

The list refreshes every 10 seconds and when you open the dropdown. `sessions.sh` reads only local files, no network.

## Agent rows and Jira

- **Claude**: the full block in the root (Session / Weekly / model buckets with bars, pace) and `details ›`.
- **Other agents**: Codex, Gemini and Copilot, when they have data, get one row each under it: headline % and reset time, with their buckets in the row's submenu.
- **Jira** (last in the block, with a Jira-style mark): time you logged today against a daily target (6–10 h, default 8, in `Settings ›`) and open sessions without a task. The submenu adds the number of tasks and today's and this week's spend from `ccusage`. Logged time comes from [Jira](#jira-optional) when connected, else from the optional `today.json`. Without either, the row is called **Spend** and shows only today's spend.

## Notifications

Three independent nudges, all opt-in under **Settings › ALERTS & NOTIFICATIONS**. Each row has one submenu: `off` plus its options.

- **Permission prompt** (`Notifications ›`) — when Claude Code blocks on a confirmation (`Notification` / `Stop` / `PreToolUse` hooks), pops a macOS notification, plays a sound, and re-focuses your terminal if the wait exceeds your configured delay. The title names the session and its task: `Claude Code · infra-7c · OPS-1198`. Delay options: 30 / 60 / 120 / 300 s. Toggling only touches the three hooks the widget owns in `~/.claude/settings.json`; your other hooks stay. These hooks also drive the `waiting` state in the session list.
- **Session finished** (`Session finished ›`) — when a session that was busy for at least 5 / 10 / 15 / 30 minutes (default 10) goes idle: `web-app-29 · WEB-311 finished`, `Busy for 14m · Checkout page performance`. A session that stops to ask you something is not "finished", and a closed session is not reported.
- **Usage threshold** (`Usage alert ▸`) — multi-select tiers 25 / 50 / 75 / 90 / 95 %. Each enabled tier fires once per 5-hour window the first time utilization crosses it, then re-arms on the next window. `off` clears them all. Triangle turns orange when on. State at `~/.cache/claude-usage-bar/alert.json`.

## At a glance

Status-bar title is `[bar] NN%`. The bar uses 8 cells with Unicode partial-block fills (`▏▎▍▌▋▊▉█`) so even sub-12.5 % utilization shows colour, and the digits pad to a fixed width so the title doesn't shift on the 9 → 10 / 99 → 100 transition. Tooltip carries the rest: `Claude · session 37% · resets in 1h 27m · week 12%`.

Right-click the icon to refresh without opening the dropdown.

### Compact mode

**Settings › DISPLAY** lets you swap the bar for a tighter `[provider icon] NN%` rendering — useful if you're tracking more than one assistant and want all of them visible in the menu bar at once.

`Compact mode ▸` opens a single submenu — `off` plus the four providers (Claude / Codex / Gemini / Copilot) with checkmarks. Picking a provider enables compact mode and toggles that provider's icon into the title; `off` disables compact mode while keeping the provider selection. Provider icons render in their brand tint (Anthropic warm, OpenAI green, Gemini blue, Copilot purple). Headline percentage per provider: Claude / Codex 5-hour bucket; Gemini / Copilot the max across their parallel quotas.

## Dropdown

Claude's block is in the root; Codex, Gemini and Copilot are rows below it, with their buckets in each row's submenu. A provider shows up only when its credentials exist locally. Each bucket of Claude's block is a single compact row:

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
- **details ▸** — active 5h block (cost / tokens / projected / burn / resets in), last session, and the last 7 daily + 4 weekly totals from ccusage, all in one submenu.
- **Settings ›** — display mode, the three notifications, daily target, usage refresh interval (5 / 10 / 15 / 20 / 30 min, default 10; background poll plus on-open with a 30 s cooldown), autostart, `Check for updates…` and the version.
- **Check for updates…** (in `Settings ›`) — self-update from GitHub or GitLab Releases (source picked at install time).

## Install

Two routes. The first is recommended — it installs the `.app` into `~/Applications/` (Spotlight-, Finder- and Launchpad-launchable as **Claude Usage Bar**) and avoids the macOS quarantine prompt entirely.

### A. Via `install.sh` (recommended)

```bash
git clone https://github.com/meduzkin/claude-usage-bar.git
cd claude-usage-bar
./install.sh
```

That:

1. Checks prerequisites (`python3`, `jq`, `npx`/`ccusage`, plus `curl` or `swiftc` depending on path) and exits with a clear error if anything is missing.
2. Triggers the macOS keychain prompt so you can click **Always Allow** during install rather than at first widget launch.
3. Gets the bundle one of two ways:
   - **`swiftc` available** (Xcode Command Line Tools installed) → builds the universal binary from source and packages a `.app` bundle.
   - **`swiftc` not available** → downloads the pre-built `Claude-Usage-Bar.zip` from this repo's [latest GitHub Release](https://github.com/meduzkin/claude-usage-bar/releases/latest).
4. Copies the `.app` into `~/Applications/` (no `sudo` required). Because the download path uses `curl`, the bundle never picks up macOS's quarantine attribute — Gatekeeper stays out of the way.
5. Optionally registers a LaunchAgent at `~/Library/LaunchAgents/com.local.claude-usage-bar.plist` so the widget starts at login.

Flags:

- `./install.sh --autostart` — non-interactive, installs the LaunchAgent without prompting.
- `./install.sh --build` — force build from source (requires `swiftc`).
- `./install.sh --download` — skip building, always pull the release artefact.

### B. Direct `.app` download

Grab `Claude-Usage-Bar.zip` from the [latest GitHub Release](https://github.com/meduzkin/claude-usage-bar/releases/latest), unzip, drag **Claude Usage Bar.app** into `~/Applications/` (or `/Applications/`), double-click to launch.

The bundle is ad-hoc signed (free, no Apple Developer ID), so on **first launch** macOS Gatekeeper will refuse it because it was downloaded via a browser (quarantine attribute set). One-time unblock:

- **macOS 14 (Sonoma) and earlier** — right-click the app → **Open** → **Open** in the dialog.
- **macOS 15 (Sequoia) and later** — open **System Settings → Privacy & Security**, scroll to the bottom, click **Open Anyway** next to the "Claude Usage Bar was blocked…" line, then re-launch.

After that, macOS remembers the approval and subsequent launches are silent. If you'd prefer a single command instead, this strips the quarantine attribute directly:

```bash
xattr -dr com.apple.quarantine ~/Applications/Claude\ Usage\ Bar.app
```

This route does **not** wire up a LaunchAgent or deploy the notification hook scripts — for those, run `./install.sh` after dropping the app in, or you can just live without autostart / hooks.

To remove: `./uninstall.sh` (stops the widget, removes the LaunchAgent, and deletes the installed bundle; the keychain ACL and your source repo stay).

## Requirements

- macOS (uses Cocoa / `NSStatusItem`)
- An active Claude Code login on this Mac — creates the `Claude Code-credentials` keychain entry the widget reads
- `python3` on `PATH` (parses keychain JSON and merges ccusage output)
- `jq` on `PATH` (used by the notification hook scripts and `sessions.sh`)
- Claude Code 2.1.196 or later for the session list (`claude agents --json`); older versions just show no sessions
- `node` / `npx` on `PATH` (for [`ccusage`](https://www.npmjs.com/package/ccusage); a globally installed `ccusage` is preferred and faster)
- One of:
  - **Swift toolchain** (`xcode-select --install`) — for `install.sh` to build from source. About 1 GB on disk; the install itself takes a couple of seconds after the toolchain is in place.
  - **`curl`** + **`unzip`** — for `install.sh` to download the pre-built `.app` bundle from the [latest GitHub Release](https://github.com/meduzkin/claude-usage-bar/releases/latest). No Xcode needed.

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
- **`jira.py`** — the optional Jira client (`check`, `refresh KEY…`): your worklogs on the local day and task statuses, one request per key so a key that does not exist is skipped.
- **`sessions.sh`** — runs `claude agents --json`, finds each session's transcript under `~/.claude/projects/` for its title and last activity, reads the `waiting` markers the notification hooks leave in `/tmp`, merges the optional session metadata, and prints one JSON document. Runs in about a second with a dozen sessions.
- **`main.swift`** / **`Sessions.swift`** — Cocoa app with `NSStatusItem`, refreshes every `refresh interval` minutes (user-configurable from the dropdown; default 10) **plus** every time you open the dropdown (with a 30-second cooldown to avoid spamming the rate-limited endpoint). Each row in the data section is wrapped in a custom `NSView` with an opaque background so the dropdown reads more solidly than the default vibrancy material.
- **Self-update and scripts** — the in-widget update replaces only the binary, so the binary carries `sessions.sh` and the two notification hooks (`embed-scripts.sh` generates `EmbeddedScripts.swift` at build time). On launch it writes `sessions.sh` to `~/.cache/claude-usage-bar/` if the bundle has none, and upgrades `~/.claude/scripts/claude-notify*.sh` only when those files are the widget's own (they carry its marker line); the previous file is kept as `.bak`.
- **`build.sh`** — produces a universal binary (`swiftc` + `lipo` over arm64 and x86_64 slices, target `macos12`), then `package-app.sh` wraps it into a `Claude Usage Bar.app` bundle (`Info.plist` with `LSUIElement`, scripts under `Contents/Resources/`, ad-hoc `codesign`).
- **Single-instance guard** — on launch the GUI process acquires a BSD `flock(LOCK_EX | LOCK_NB)` on `~/.cache/claude-usage-bar/widget.lock`. A second launch (LaunchAgent + manual run, a self-update that didn't terminate the prior process, a Finder double-click) sees the lock and exits cleanly. The kernel auto-releases on process death, so stale lock files never wedge future launches. `--headless` bypasses the lock.

## Claude Code statusline

The repo ships `scripts/statusline.sh`. `install.sh` drops it into `~/.claude/scripts/` along with the notification hooks. Wire it into Claude Code's statusline by setting in `~/.claude/settings.json`:

```json
{
  "statusline": { "command": "~/.claude/scripts/statusline.sh" }
}
```

The script reads only from the local cache (`~/.cache/claude-usage-bar/oauth.json`) so it adds zero network latency to your prompts. Output: `<color>NN%<reset> →PP% · Mh MMm`, where `NN` is current 5h utilization (colour-tiered), `PP` is projected end-of-window pace, and `Mh MMm` is time to reset.

## Jira (optional)

Off until you connect it: **Settings › Jira › Connect…** asks for your Jira Cloud site, email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens). Then, every 5 minutes, the widget fetches:

- your time logged today: your own worklogs whose start falls on the Mac's local day, whatever time zone they were logged in;
- the status of each session's task key, so a session working in a closed ticket is flagged.

The token is stored in your Keychain (an item of the widget itself) and goes only to your Jira site, over https; `jira.py` gets it through its environment, never on the command line. The widget only reads from Jira. `Show tasks & logged time` turns the task column and the logged time off without disconnecting; `Disconnect` removes the token.

## Session metadata (optional)

The widget does not know about your ticket tracker. Any tool can tell it, by writing small JSON files to `~/.cache/claude-sessions/` (override with `CLAUDE_SESSIONS_META_DIR`):

`<session-id>.json`, per session (a status line command gets `session_id` on stdin):

```json
{"task": "OPS-1204", "taskStatus": "In Progress", "taskStatusCategory": "indeterminate",
 "taskUrl": "https://example.atlassian.net/browse/OPS-1204", "ctx": 41}
```

`today.json`, once per refresh:

```json
{"date": "2026-10-15", "loggedSeconds": 22500, "tasks": 5, "targetSeconds": 28800}
```

All fields are optional. `taskStatusCategory: "done"` marks the task as closed. `date` is the local date; a file from another day is ignored, so a producer that stops updating does not show yesterday's hours. Without these files the session list still works, just without the task column and the Logged row.

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

## Development

```bash
./build.sh                                   # universal binary + .app
/bin/bash tests/test_sessions.sh             # sessions.sh and the hooks, on fixtures
/bin/bash tests/test_jira.sh                 # jira.py against a stub Jira on localhost
./claude-usage-bar --self-test               # session logic: order, finished detection, today, script upgrade
tests/make-preview-fixtures.sh /tmp/fx       # demo data, made-up names
./claude-usage-bar --render-preview /tmp/menu.png --usage /tmp/fx/usage.json --sessions /tmp/fx/sessions.json [--light]
```

`--render-preview` draws the menu-bar title and the dropdown into a PNG without opening the menu; the README screenshot is made this way from the demo data. CI runs all of the above on every push.

## Cross-platform (Linux / Windows)

`cross-platform/` contains a Python + `pystray` proof of concept covering the core surface — tray badge, dropdown with alert / threshold / interval / refresh, service-status tooltip. See [`cross-platform/README.md`](cross-platform/README.md). The Swift app remains the canonical implementation on macOS; the Python tray is for non-Mac machines where the Swift binary doesn't run.

## Known limits

- The `/api/oauth/usage` endpoint is throttled. The background refresh interval is user-configurable (5/10/15/20/30 min; default 10) and the dropdown on-open refresh is gated by a 30-second cooldown. If you hit a 429 anyway, the widget shows cached values until the next successful call.
- `ccusage` cost figures are estimates from local JSONL session files and won't exactly match Anthropic's internal billing.
- No paid Apple Developer ID / notarization — the `.app` bundle is only ad-hoc signed. macOS Gatekeeper warns on first launch of a browser-downloaded copy; see [direct `.app` install instructions](#b-direct-app-download) for the one-time unblock. The `install.sh` path uses `curl` (no quarantine), so that route stays one-step.

## Disclaimer

This is an unofficial community tool, not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic. It reads the OAuth token Claude Code already stored on your machine and calls a public Anthropic API endpoint; it does not bypass any auth or send any data anywhere else. It changes your Claude Code setup only in two places, both its own: the three notification hooks in `~/.claude/settings.json` when you toggle notifications, and its own hook scripts in `~/.claude/scripts/` when a newer version ships them.

## License

Apache 2.0 — see [LICENSE](LICENSE).
