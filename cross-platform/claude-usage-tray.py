#!/usr/bin/env python3
"""
Cross-platform proof-of-concept companion to the macOS menu bar widget.

Goal: feature-parity-ish on Linux and Windows for the *core* surface —
percentage in the tray, dropdown with the same plan-usage / 5h-block /
pace breakdown. Notifications via the OS-native channel. ccusage
overlay reused via the same shell helper if Node is available.

Status: POC. The macOS version is the canonical implementation. This
file exists so the same feature set is achievable on Linux/Windows
without forking a separate codebase. Things still TODO are tagged
inline.

Run:
    pip install -r requirements.txt
    python3 claude-usage-tray.py

Auth on Linux/Windows is *not* keychain-based — Claude Code stores the
OAuth token in different places depending on platform. Set
CLAUDE_CREDS to a file containing the same `{"claudeAiOauth": {...}}`
payload (e.g. by copying it out of the system credential store once)
and this script reads from there.
"""

from __future__ import annotations

import datetime
import json
import os
import platform
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any, Optional

try:
    import pystray
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.stderr.write(
        "missing dependencies — run: pip install -r requirements.txt\n"
    )
    sys.exit(1)


HOME = Path.home()
CACHE_DIR = Path(os.environ.get("CLAUDE_USAGE_CACHE_DIR", HOME / ".cache" / "claude-usage-bar"))
CACHE_DIR.mkdir(parents=True, exist_ok=True)
OAUTH_CACHE = CACHE_DIR / "oauth.json"
ALERT_CONFIG = CACHE_DIR / "alert.json"
INTERVAL_CONFIG = CACHE_DIR / "interval.json"

OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
STATUS_URL = "https://status.anthropic.com/api/v2/status.json"
USAGE_BETA = "oauth-2025-04-20"

INTERVAL_OPTIONS = [5, 10, 15, 20, 30]
DEFAULT_INTERVAL_MIN = 10
THRESHOLD_OPTIONS = [70, 80, 90, 95]
DEFAULT_THRESHOLD = 90


# ── token loading ──────────────────────────────────────────────────────────
def load_token() -> Optional[str]:
    """Read OAuth access token from $CLAUDE_CREDS file (mandatory on
    Linux/Windows). On macOS would fall back to the keychain but the
    macOS port is the Swift widget — Python tray is for non-Mac users."""
    creds_path = os.environ.get("CLAUDE_CREDS")
    if creds_path and Path(creds_path).is_file():
        try:
            data = json.loads(Path(creds_path).read_text().strip().splitlines()[0])
            return ((data.get("claudeAiOauth") or {}).get("accessToken"))
        except Exception:
            return None
    # TODO(macos): security find-generic-password -s "Claude Code-credentials" -w
    # TODO(linux): poke libsecret or read ~/.config/Claude/credentials.json
    # TODO(windows): wincred lookup
    return None


# ── network ────────────────────────────────────────────────────────────────
def fetch_oauth_usage(token: str) -> Optional[dict]:
    req = urllib.request.Request(OAUTH_USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": USAGE_BETA,
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status != 200:
                return None
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def fetch_service_status() -> dict:
    try:
        with urllib.request.urlopen(STATUS_URL, timeout=5) as resp:
            d = json.loads(resp.read().decode("utf-8"))
            s = d.get("status") or {}
            return {
                "indicator":   s.get("indicator")   or "none",
                "description": s.get("description") or "Unknown",
            }
    except Exception:
        return {"indicator": "unknown", "description": "Unknown"}


# ── cache helpers ──────────────────────────────────────────────────────────
def write_cache(obj: dict) -> None:
    tmp = OAUTH_CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj))
    tmp.replace(OAUTH_CACHE)


def read_cache() -> Optional[dict]:
    if not OAUTH_CACHE.is_file():
        return None
    try:
        return json.loads(OAUTH_CACHE.read_text())
    except Exception:
        return None


# ── small UI helpers ───────────────────────────────────────────────────────
def color_for(pct: float) -> tuple[int, int, int]:
    if pct < 60:  return (52, 199,  89)   # systemGreen
    if pct < 85:  return (255, 204, 0)    # systemYellow
    return            (255,  59, 48)      # systemRed


def make_tray_icon(pct: float) -> Image.Image:
    """Render a 22×22 icon showing the percentage. Color matches the
    macOS widget so the visual cue is consistent across machines."""
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    bg = color_for(pct)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=12, fill=bg + (255,))
    text = f"{int(pct)}"
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", 32)
    except Exception:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(((size - tw) / 2 - bbox[0], (size - th) / 2 - bbox[1] - 2),
              text, fill=(0, 0, 0, 255), font=font)
    return img


def minutes_until(iso: str) -> Optional[int]:
    if not iso:
        return None
    try:
        t = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        diff = (t - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
        return max(0, int(diff // 60))
    except Exception:
        return None


# ── notifications ──────────────────────────────────────────────────────────
def notify(title: str, body: str) -> None:
    """OS-native notification. Plain stdlib fallback if dedicated tools
    aren't present."""
    sys_name = platform.system()
    try:
        if sys_name == "Linux":
            subprocess.run(
                ["notify-send", title, body],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        elif sys_name == "Windows":
            # TODO: switch to win10toast or BurntToast for richer notifications
            subprocess.run(
                ["powershell", "-Command",
                 f'New-BurntToastNotification -Text "{title}", "{body}"'],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        elif sys_name == "Darwin":
            subprocess.run(
                ["osascript", "-e",
                 f'display notification "{body}" with title "{title}" sound name "Glass"'],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
    except Exception:
        pass


# ── core poll loop ─────────────────────────────────────────────────────────
class TrayApp:
    def __init__(self) -> None:
        self.interval_min = self._load_interval()
        self.alert = self._load_alert()
        self.last_payload: Optional[dict] = None
        self.icon: Optional[pystray.Icon] = None
        self._stop = threading.Event()

    # ── config persistence ──
    def _load_interval(self) -> int:
        try:
            d = json.loads(INTERVAL_CONFIG.read_text())
            m = int(d.get("minutes", DEFAULT_INTERVAL_MIN))
            return m if m in INTERVAL_OPTIONS else DEFAULT_INTERVAL_MIN
        except Exception:
            return DEFAULT_INTERVAL_MIN

    def _save_interval(self) -> None:
        INTERVAL_CONFIG.write_text(json.dumps({"minutes": self.interval_min}))

    def _load_alert(self) -> dict:
        try:
            return json.loads(ALERT_CONFIG.read_text())
        except Exception:
            return {"enabled": False, "threshold": DEFAULT_THRESHOLD,
                    "alertedWindowResetsAt": None}

    def _save_alert(self) -> None:
        ALERT_CONFIG.write_text(json.dumps(self.alert))

    # ── refresh ──
    def refresh(self) -> None:
        token = load_token()
        oauth: dict = {}
        if token:
            d = fetch_oauth_usage(token)
            if d is not None:
                oauth = d
                write_cache(d)
            else:
                cached = read_cache()
                if cached:
                    oauth = cached
        else:
            cached = read_cache()
            if cached:
                oauth = cached

        service = fetch_service_status()
        payload = {"oauth": oauth, "service": service}
        self.last_payload = payload

        # tray icon + tooltip
        fh = oauth.get("five_hour") or {}
        pct = fh.get("utilization") or 0
        mins = minutes_until(fh.get("resets_at") or "")
        if self.icon is not None:
            self.icon.icon = make_tray_icon(pct)
            self.icon.title = self._tooltip(pct, mins, oauth, service)
            self._update_menu()
        self._check_alert(pct, fh.get("resets_at") or "")

    def _tooltip(self, pct: float, mins: Optional[int], oauth: dict, service: dict) -> str:
        parts = [f"session {pct:.0f}%"]
        if mins is not None:
            parts.append(f"{mins // 60}h {mins % 60:02d}m to reset" if mins >= 60 else f"{mins}m")
        if (service.get("indicator") or "none") not in ("none", "unknown"):
            parts.append(f"⚠ {service.get('description')}")
        return " · ".join(parts)

    # ── alert ──
    def _check_alert(self, pct: float, window_id: str) -> None:
        if not self.alert.get("enabled"):
            return
        if pct < float(self.alert.get("threshold", DEFAULT_THRESHOLD)):
            return
        if self.alert.get("alertedWindowResetsAt") == window_id:
            return
        notify("Claude usage",
               f"Current 5-hour session is at {pct:.0f}% (≥ {self.alert['threshold']}%)")
        self.alert["alertedWindowResetsAt"] = window_id
        self._save_alert()

    # ── menu ──
    def _menu(self) -> pystray.Menu:
        return pystray.Menu(
            pystray.MenuItem(self._format_summary(), None, enabled=False),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                lambda _: f"alert  {'on' if self.alert['enabled'] else 'off'}",
                self._toggle_alert,
            ),
            pystray.MenuItem(
                lambda _: f"threshold  ({self.alert['threshold']}%)",
                pystray.Menu(*[
                    pystray.MenuItem(
                        f"{n}%",
                        self._make_pick_threshold(n),
                        checked=lambda _, n=n: self.alert["threshold"] == n,
                    ) for n in THRESHOLD_OPTIONS
                ]),
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                lambda _: f"refresh interval  ({self.interval_min}m)",
                pystray.Menu(*[
                    pystray.MenuItem(
                        f"{n} min",
                        self._make_pick_interval(n),
                        checked=lambda _, n=n: self.interval_min == n,
                    ) for n in INTERVAL_OPTIONS
                ]),
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Refresh now", lambda _: self.refresh()),
            pystray.MenuItem("Quit", self._quit),
        )

    def _update_menu(self) -> None:
        if self.icon is not None:
            self.icon.menu = self._menu()
            self.icon.update_menu()

    def _format_summary(self) -> str:
        if not self.last_payload:
            return "loading…"
        fh = (self.last_payload.get("oauth") or {}).get("five_hour") or {}
        sd = (self.last_payload.get("oauth") or {}).get("seven_day") or {}
        pct5 = fh.get("utilization") or 0
        pct7 = sd.get("utilization") or 0
        return f"session {pct5:.0f}%  ·  week {pct7:.0f}%"

    def _toggle_alert(self, _icon, _item) -> None:
        self.alert["enabled"] = not self.alert.get("enabled", False)
        if self.alert["enabled"]:
            self.alert["alertedWindowResetsAt"] = None
        self._save_alert()
        self._update_menu()

    def _make_pick_threshold(self, n: int):
        def cb(_icon, _item):
            self.alert["threshold"] = n
            self.alert["enabled"] = True
            self.alert["alertedWindowResetsAt"] = None
            self._save_alert()
            self._update_menu()
            self.refresh()
        return cb

    def _make_pick_interval(self, n: int):
        def cb(_icon, _item):
            self.interval_min = n
            self._save_interval()
            self._update_menu()
            # poll loop sees the new interval on its next tick
        return cb

    # ── main loop ──
    def _quit(self, icon, _item) -> None:
        self._stop.set()
        icon.stop()

    def _loop(self) -> None:
        while not self._stop.is_set():
            self.refresh()
            # Sleep in 1s chunks so quit is responsive
            for _ in range(self.interval_min * 60):
                if self._stop.is_set():
                    return
                time.sleep(1)

    def run(self) -> None:
        self.icon = pystray.Icon(
            "claude-usage-tray",
            make_tray_icon(0),
            "claude-usage",
            self._menu(),
        )
        threading.Thread(target=self._loop, daemon=True).start()
        self.icon.run()


if __name__ == "__main__":
    TrayApp().run()
