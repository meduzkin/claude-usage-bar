# claude-usage-tray (cross-platform)

> **Status: proof of concept.** The canonical implementation is the Swift macOS widget in the parent directory. This Python tray app exists so Linux and Windows users can get the same core surface — percentage badge in the system tray, dropdown with usage / alert / interval controls — without forking a separate codebase.

Tested setup paths:

- Linux: GNOME / KDE / XFCE tray via `pystray` (X11 + `notify-send`)
- Windows: native system tray via `pystray` (notifications via PowerShell `New-BurntToastNotification`)
- macOS: works but the Swift widget is preferred — has opaque-background dropdown, statusline integration, hook bundling

## What's implemented

- Percentage badge in the system tray, color-coded green/yellow/red.
- Dropdown: session% + week% summary, alert toggle, threshold picker (70/80/90/95), refresh interval picker (5/10/15/20/30 min).
- Same `/api/oauth/usage` poll as the macOS widget, with disk cache fallback at `~/.cache/claude-usage-bar/oauth.json` for 429 windows.
- Anthropic service-status check via `https://status.anthropic.com/api/v2/status.json` — surfaced in the tray tooltip.
- Threshold alert with one-fire-per-window semantics (same `~/.cache/claude-usage-bar/alert.json` schema as macOS).
- OS-native notifications: `notify-send` on Linux, `BurntToastNotification` on Windows, `osascript` on macOS.

## What's NOT yet implemented (vs the macOS Swift widget)

- ccusage cost overlay — would need to shell out to `npx ccusage` and merge. Trivial to add.
- Notification hook toggle (the `claude-notify.sh` / settings.json mechanism). Hooks are Claude Code's own feature so they work cross-platform; just need a Python equivalent of `notif.sh`.
- Pace projection line in the dropdown — already implemented in the Swift widget's `paceLine()`; trivial Python port pending.
- daily / weekly history submenus.
- Statusline integration script (the `scripts/statusline.sh` from the parent dir works on Linux too — just point your Claude Code statusline at it).

## Install

```bash
# Linux example (Debian/Ubuntu)
sudo apt install python3-pip libgirepository1.0-dev   # for pystray on X11
pip install -r requirements.txt
```

```bash
# Windows (PowerShell)
pip install -r requirements.txt
# optional, for nicer notifications:
Install-Module -Name BurntToast -Scope CurrentUser
```

## Auth

Keychain access on Linux/Windows isn't standardized the way macOS's `security` CLI is. For now the app reads OAuth credentials from a file:

```bash
export CLAUDE_CREDS=/path/to/claude-credentials.json
python3 claude-usage-tray.py
```

The file should contain the same `{"claudeAiOauth": {"accessToken": "..."}}` payload Claude Code stores on its first login. Pull it manually from wherever Claude Code keeps it on your OS (varies — Linux often under `~/.config/Claude/`, Windows often under `%APPDATA%\Claude\`). A platform-aware loader is a TODO.

## Why a Python POC and not a full Rust/Tauri rewrite?

Three reasons:

1. **Reuse, not redo.** `pystray` covers Linux + Windows + macOS tray basics in ~50 lines. Same JSON schemas, same cache files, same alert semantics as the Swift widget.
2. **Iteration speed.** Adding a feature in Python takes minutes; adding it in Swift + porting to Rust would block on language-by-language work.
3. **Honest scope.** A full cross-platform rewrite is multi-day work and would duplicate the macOS Swift code for negligible benefit on macOS. The Python tray fills the gap for people who don't have a Mac.
