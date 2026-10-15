#!/usr/bin/env python3
"""Jira Cloud client for the widget's Today row and session task statuses.

    jira.py check                 -> {"ok": true, "name": "...", "accountId": "..."} or {"ok": false, "error": "..."}
    jira.py refresh KEY [KEY...]  -> {"ok": true, "today": {...}, "statuses": {KEY: {...}}} or {"ok": false, ...}

Config: ~/.cache/claude-usage-bar/jira.json {"site": "https://x.atlassian.net", "email": "..."}.
Token: macOS Keychain, generic password, service "claude-usage-bar-jira", account = email.
Overrides (tests, headless): JIRA_SITE, JIRA_EMAIL, JIRA_TOKEN, JIRA_CONFIG, JIRA_NOW (epoch).

"Today" is the local calendar day of this Mac. Jira stores each worklog's
`started` with whatever offset the client sent, so a worklog belongs to today
when its instant falls inside [local midnight, next local midnight), not when
its date string says so. Only the caller's own worklogs count.
Talks only to the configured Jira site. Never prints the token.
"""
import base64, datetime, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

KEYCHAIN_SERVICE = "claude-usage-bar-jira"
CONFIG = os.environ.get("JIRA_CONFIG") or os.path.expanduser("~/.cache/claude-usage-bar/jira.json")


def out(obj):
    print(json.dumps(obj))
    sys.exit(0)


def load_config():
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
    site = (os.environ.get("JIRA_SITE") or cfg.get("site") or "").rstrip("/")
    email = os.environ.get("JIRA_EMAIL") or cfg.get("email") or ""
    token = os.environ.get("JIRA_TOKEN")
    if token is None and email:
        r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", email, "-w"],
                           capture_output=True, text=True)
        token = r.stdout.strip() if r.returncode == 0 else ""
    return site, email, token or ""


def client(site, email, token):
    auth = "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode()

    def get(path):
        req = urllib.request.Request(site + "/rest/api/3" + path,
                                     headers={"Authorization": auth, "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    return get


def local_day(now):
    d = datetime.datetime.fromtimestamp(now).astimezone()
    start = d.replace(hour=0, minute=0, second=0, microsecond=0)
    end = (start + datetime.timedelta(days=1, hours=2)).replace(hour=0, minute=0, second=0, microsecond=0)
    return start.timestamp(), end.timestamp(), start.date().isoformat()


def parse_started(s):
    # "2026-10-15T06:00:00.000+0300"
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f%z").timestamp()


def seconds_in(worklogs, me, start, end):
    total = 0
    for w in worklogs:
        try:
            t = parse_started(w["started"])
        except (KeyError, ValueError):
            continue
        if (w.get("author") or {}).get("accountId") == me and start <= t < end:
            total += int(w.get("timeSpentSeconds") or 0)
    return total


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("check", "refresh"):
        out({"ok": False, "error": "usage: jira.py check | refresh KEY..."})
    site, email, token = load_config()
    if not (site and email and token):
        out({"ok": False, "error": "not connected"})
    if not site.startswith("https://") and not os.environ.get("JIRA_ALLOW_HTTP"):
        out({"ok": False, "error": "site must start with https://"})
    get = client(site, email, token)
    try:
        me = get("/myself")
        if sys.argv[1] == "check":
            out({"ok": True, "name": me.get("displayName"), "accountId": me.get("accountId"), "site": site})

        now = float(os.environ.get("JIRA_NOW") or time.time())
        start, end, day = local_day(now)
        jql = urllib.parse.quote("worklogAuthor = currentUser() AND worklogDate >= -2d")
        issues = get(f"/search/jql?jql={jql}&fields=summary&maxResults=100").get("issues", [])
        total, tasks = 0, 0
        for it in issues:
            wl = get(f"/issue/{it['key']}/worklog?startedAfter={int(start * 1000) - 1}&maxResults=1000")
            sec = seconds_in(wl.get("worklogs", []), me["accountId"], start, end)
            total += sec
            tasks += sec > 0

        # One request per key: a key taken from a branch name may not exist,
        # and `key in (...)` fails the whole query on a single unknown key.
        statuses = {}
        for key in sorted({k for k in sys.argv[2:] if k})[:30]:
            try:
                st = get(f"/issue/{urllib.parse.quote(key)}?fields=status")["fields"]["status"]
            except urllib.error.HTTPError as e:
                if e.code in (400, 403, 404):
                    continue
                raise
            statuses[key] = {"name": st["name"], "category": st["statusCategory"]["key"],
                             "url": f"{site}/browse/{key}"}
        out({"ok": True, "today": {"date": day, "loggedSeconds": total, "tasks": tasks},
             "statuses": statuses, "fetchedAt": int(now)})
    except urllib.error.HTTPError as e:
        out({"ok": False, "error": f"HTTP {e.code}" + (" (check email and token)" if e.code in (401, 403) else "")})
    except Exception as e:
        out({"ok": False, "error": type(e).__name__ + ": " + str(e)[:200]})


if __name__ == "__main__":
    main()
