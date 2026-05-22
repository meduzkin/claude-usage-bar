import Cocoa

/// Solid-fill background view used to give the dropdown's content area an
/// opaque feel instead of inheriting macOS's translucent menu vibrancy.
/// Drawing via `draw(_:)` (not a CALayer color) keeps it correct under
/// dynamic light/dark appearance changes.
final class OpaqueBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

let SCRIPT_PATH: String = {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return (exe as NSString).deletingLastPathComponent + "/usage.sh"
}()

// The /api/oauth/usage endpoint is rate-limited fairly aggressively
// (429s within a few requests/minute). The background poll interval is
// user-configurable from the dropdown — these are the offered options.
// Default 10 min keeps us well clear of the throttle while still giving
// reasonably fresh percentages.
let INTERVAL_OPTIONS: [Int] = [5, 10, 15, 20, 30]   // minutes
let DEFAULT_INTERVAL_MINUTES: Int = 10
let ON_OPEN_COOLDOWN: TimeInterval = 30
let INTERVAL_CONFIG_PATH: String = "\(NSHomeDirectory())/.cache/claude-usage-bar/interval.json"

func shortModel(_ raw: String) -> String {
    // claude-opus-4-7 -> opus-4.7
    // claude-haiku-4-5-20251001 -> haiku-4.5
    var s = raw
    if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
    let parts = s.split(separator: "-")
    guard parts.count >= 3 else { return s }
    let name = String(parts[0])
    let major = String(parts[1])
    let minor = String(parts[2])
    return "\(name)-\(major).\(minor)"
}

func shortModels(_ raws: [String]) -> String {
    raws.map(shortModel).joined(separator: ",")
}

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%5.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%5.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%5.1fK", d / 1e3) }
    return String(format: "%5d ", n)
}

func sumTokens(_ d: [String: Any]) -> Int {
    let keys = ["inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens"]
    return keys.reduce(0) { $0 + ((d[$1] as? Int) ?? 0) }
}

func blockTotalTokens(_ d: [String: Any]) -> Int {
    if let t = d["totalTokens"] as? Int { return t }
    if let tc = d["tokenCounts"] as? [String: Any] {
        let keys = ["inputTokens", "outputTokens", "cacheCreationInputTokens", "cacheReadInputTokens"]
        return keys.reduce(0) { $0 + ((tc[$1] as? Int) ?? 0) }
    }
    return 0
}

// Widget version, bumped manually each release. Compared against the
// `tag_name` of the latest release fetched from the configured source.
let WIDGET_VERSION = "0.3.0"
// Default update source. Overridable at runtime by ~/.cache/claude-usage-bar/update.json
// — install.sh writes that file pointing at the distribution it came from
// (GitHub Releases for the standalone repo, GitLab Releases for the
// ai-snippets distribution).
let DEFAULT_UPDATE_CONFIG: [String: String] = [
    "type":       "github",
    "url":        "https://api.github.com/repos/meduzkin/claude-usage-bar/releases/latest",
    "asset_name": "claude-usage-bar",
]
let UPDATE_CONFIG_PATH = "\(NSHomeDirectory())/.cache/claude-usage-bar/update.json"

// Delay options offered in the notifications submenu (seconds).
let NOTIF_DELAY_OPTIONS: [Int] = [30, 60, 120, 300]
// Threshold options offered in the usage-alert submenu (percent).
// Multiple may be enabled at once — each fires exactly once per 5h window
// (keyed by the window's `resets_at` timestamp).
let ALERT_THRESHOLD_OPTIONS: [Int] = [25, 50, 75, 90, 95]
// Where alert config + last-fired window are persisted.
let ALERT_CONFIG_PATH: String = {
    let home = NSHomeDirectory()
    return "\(home)/.cache/claude-usage-bar/alert.json"
}()

class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastRefreshAt: Date = .distantPast
    let detailItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    let dailyItem  = NSMenuItem(title: "daily",  action: nil, keyEquivalent: "")
    let weeklyItem = NSMenuItem(title: "weekly", action: nil, keyEquivalent: "")
    let notifToggleItem = NSMenuItem(title: "notifications", action: nil, keyEquivalent: "")
    let notifDelayItem  = NSMenuItem(title: "delay",         action: nil, keyEquivalent: "")
    var notifEnabled = false
    var notifDelay = 60

    let alertToggleItem     = NSMenuItem(title: "alert",      action: nil, keyEquivalent: "")
    let alertThresholdItem  = NSMenuItem(title: "thresholds", action: nil, keyEquivalent: "")
    var alertEnabled = false
    var alertThresholds: Set<Int> = [90]            // tiers that fire
    var alertedWindowResetsAt: String? = nil         // which window we last fired in
    var firedTiersInWindow: Set<Int> = []            // tiers already fired this window

    let intervalItem = NSMenuItem(title: "refresh interval", action: nil, keyEquivalent: "")
    var refreshIntervalMinutes = DEFAULT_INTERVAL_MINUTES

    var menu: NSMenu!  // stored so right-click handler can pop it up manually

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "claude …"

        // Custom click handling: left-click pops up the menu, right-click
        // triggers a refresh in place. The menu is NOT attached to the
        // status item (we'd lose the right-click hook); we pop it up
        // ourselves via `popUp(positioning:at:in:)` on left-click.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        menu = NSMenu()
        menu.delegate = self
        detailItem.isEnabled = false
        setDetail(plain("Loading…"))
        menu.addItem(detailItem)
        menu.addItem(.separator())
        dailyItem.isHidden = true
        weeklyItem.isHidden = true
        menu.addItem(dailyItem)
        menu.addItem(weeklyItem)
        menu.addItem(.separator())
        notifToggleItem.target = self
        notifToggleItem.action = #selector(toggleNotif)
        menu.addItem(notifToggleItem)
        menu.addItem(notifDelayItem)
        menu.addItem(.separator())
        alertToggleItem.target = self
        alertToggleItem.action = #selector(toggleAlert)
        menu.addItem(alertToggleItem)
        menu.addItem(alertThresholdItem)
        menu.addItem(.separator())
        menu.addItem(intervalItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        let aboutItem = NSMenuItem(title: "version \(WIDGET_VERSION)", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self

        loadAlertConfig()
        loadIntervalConfig()
        rebuildIntervalSubmenu()

        refresh()
        scheduleTimer()
    }

    /// (Re)installs the background refresh timer at the current
    /// `refreshIntervalMinutes`. Invalidates any prior timer.
    func scheduleTimer() {
        timer?.invalidate()
        let seconds = TimeInterval(refreshIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // refresh on dropdown open, but throttle so repeated clicks don't
        // smash the rate-limited endpoint
        if Date().timeIntervalSince(lastRefreshAt) >= ON_OPEN_COOLDOWN {
            refresh()
        }
    }

    /// Left-click → pop up the menu. Right-click (or Ctrl-click) →
    /// trigger a refresh without opening the dropdown — quick way to
    /// re-fetch state when you've just consumed a chunk and want to
    /// see the new percentage immediately.
    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
                            (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            refresh()
            return
        }
        // Attach menu, show it, detach so the next click hits our action
        // handler again instead of being captured by the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func refresh() {
        lastRefreshAt = Date()
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let payload = self.runScript()
            DispatchQueue.main.async { self.render(payload: payload) }
        }
    }

    func runScript() -> [String: Any]? {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [SCRIPT_PATH]
        let out = Pipe(); let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func render(payload: [String: Any]?) {
        guard let payload else {
            statusItem.button?.title = "claude ?"
            setDetail(plain("Failed to fetch usage data\nIs ccusage installed? Run: npx -y ccusage@latest blocks --active"))
            return
        }
        let oauth = payload["oauth"] as? [String: Any] ?? [:]
        let active = payload["active"] as? [String: Any]
        let session = payload["session"] as? [String: Any]
        let daily = (payload["daily"] as? [[String: Any]]) ?? []
        let weekly = (payload["weekly"] as? [[String: Any]]) ?? []

        let fiveHour = oauth["five_hour"] as? [String: Any]
        let sevenDay = oauth["seven_day"] as? [String: Any]
        let fiveHourPct = fiveHour?["utilization"] as? Double
        let fiveHourReset = fiveHour?["resets_at"] as? String
        let fiveHourResetMin = minutesUntil(iso: fiveHourReset ?? "")

        // ── status bar title (mini colored bar) ─────────────────────────
        if let pct = fiveHourPct, let m = fiveHourResetMin {
            let title = NSMutableAttributedString()
            title.append(plain("session "))
            title.append(makeBar(pct: pct, width: 6))
            title.append(coloredText(String(format: " %.0f%%", pct), color: barColor(pct)))
            title.append(plain(" · " + formatResetMinutes(m)))
            statusItem.button?.attributedTitle = title
        } else if let a = active {
            let cost = a["costUSD"] as? Double ?? 0
            let remMin = (a["projection"] as? [String: Any])?["remainingMinutes"] as? Int ?? 0
            statusItem.button?.title = String(format: "$%.2f · ", cost) + formatResetMinutes(remMin)
        } else {
            statusItem.button?.title = "claude —"
        }

        // ── dropdown body ───────────────────────────────────────────────
        let out = NSMutableAttributedString()

        // Service-status badge — only renders when Anthropic is not "none".
        if let svc = payload["service"] as? [String: Any],
           let ind = svc["indicator"] as? String, ind != "none" && ind != "unknown" {
            let desc = (svc["description"] as? String) ?? "Service degraded"
            let badge = serviceStatusBadge(indicator: ind, description: desc)
            out.append(badge)
            out.append(plain("\n"))
        }

        if fiveHour != nil || sevenDay != nil {
            out.append(plain("◆ plan usage  (Claude)\n"))
            if let f = fiveHour { appendBucketLine(out, label: "current session       ", b: f) }
            if let s = sevenDay { appendBucketLine(out, label: "current week          ", b: s) }
            if let o = oauth["seven_day_opus"]   as? [String: Any] { appendBucketLine(out, label: "current week opus     ", b: o) }
            if let s = oauth["seven_day_sonnet"] as? [String: Any] { appendBucketLine(out, label: "current week sonnet   ", b: s) }

            // Pace marker: projected end-of-window utilization at current burn,
            // plus projected additional cost when ccusage gave us numbers.
            if let pct = fiveHourPct, let mins = fiveHourResetMin {
                if let line = paceLine(currentPct: pct, minutesUntilReset: mins,
                                       activeBlock: active) {
                    out.append(line)
                    out.append(plain("\n"))
                }
            }
            out.append(plain("\n"))
        }

        // Codex section — only rendered when the user has an authenticated
        // OpenAI Codex CLI install (scripts/codex-usage.sh returned data).
        if let codex = payload["codex"] as? [String: Any], !codex.isEmpty {
            let cx5  = codex["five_hour"]  as? [String: Any]
            let cx7  = codex["seven_day"] as? [String: Any]
            if cx5 != nil || cx7 != nil {
                var header = "◆ plan usage  (Codex"
                if let src = codex["source"] as? String, src == "rpc" {
                    header += " · via app-server"
                }
                header += ")"
                if (codex["stale"] as? Bool) == true {
                    out.append(plain(header + "  "))
                    out.append(coloredText("(token stale — run `codex` to refresh)",
                                            color: .systemYellow))
                    out.append(plain("\n"))
                } else {
                    out.append(plain(header + "\n"))
                }
                if let f = cx5 { appendBucketLine(out, label: "current session       ", b: f) }
                if let s = cx7 { appendBucketLine(out, label: "current week          ", b: s) }
                out.append(plain("\n"))
            }
        }

        // Gemini Code Assist — per-model quota buckets.
        if let gemini = payload["gemini"] as? [String: Any],
           let models = gemini["models"] as? [[String: Any]], !models.isEmpty {
            out.append(plain("◆ plan usage  (Gemini)\n"))
            for m in models {
                let name = (m["name"] as? String) ?? "model"
                let bucket: [String: Any] = [
                    "utilization": m["utilization"] ?? 0,
                    "resets_at":   m["resets_at"]   ?? "",
                ]
                let label = name.padding(toLength: 22, withPad: " ", startingAt: 0)
                appendBucketLine(out, label: label, b: bucket)
            }
            out.append(plain("\n"))
        }

        // GitHub Copilot — chat / completions / premium quotas.
        if let copilot = payload["copilot"] as? [String: Any], !copilot.isEmpty {
            var anyRendered = false
            for (label, key) in [("chat                  ", "chat"),
                                  ("completions           ", "completions"),
                                  ("premium interactions  ", "premium")] {
                if let b = copilot[key] as? [String: Any] {
                    if !anyRendered {
                        out.append(plain("◆ plan usage  (Copilot)\n"))
                        anyRendered = true
                    }
                    if (b["unlimited"] as? Bool) == true {
                        out.append(plain("   \(label)  unlimited\n"))
                    } else {
                        appendBucketLine(out, label: label, b: b)
                    }
                }
            }
            if anyRendered { out.append(plain("\n")) }
        }

        if let a = active {
            let cost = a["costUSD"] as? Double ?? 0
            let proj = (a["projection"] as? [String: Any])?["totalCost"] as? Double ?? 0
            let remMin = (a["projection"] as? [String: Any])?["remainingMinutes"] as? Int ?? 0
            let burn = (a["burnRate"] as? [String: Any])?["costPerHour"] as? Double ?? 0
            let tpm = (a["burnRate"] as? [String: Any])?["tokensPerMinute"] as? Double ?? 0
            let endTime = a["endTime"] as? String ?? ""
            let models = (a["models"] as? [String]) ?? []
            let tokens = blockTotalTokens(a)

            out.append(plain("◆ 5h block · " + (models.isEmpty ? "—" : shortModels(models)) + "\n"))
            out.append(plain(String(format: "   spent      $%.2f\n", cost)))
            out.append(plain(String(format: "   tokens     %@\n", fmtTokens(tokens))))
            out.append(plain(String(format: "   projected  $%.2f\n", proj)))
            out.append(plain(String(format: "   burn       $%.2f/h  %@/min\n", burn, fmtTokens(Int(tpm)))))
            var resets = String(format: "   resets in  %dh %02dm", remMin / 60, remMin % 60)
            if let local = formatLocalTime(iso: endTime) { resets += " at \(local)" }
            out.append(plain(resets + "\n"))
        } else {
            out.append(plain("◆ 5h block\n   (no active block — run something in Claude Code)\n"))
        }

        if let s = session {
            let cost = s["totalCost"] as? Double ?? 0
            let tokens = sumTokens(s)
            let models = (s["modelsUsed"] as? [String]) ?? []
            let last = ((s["metadata"] as? [String: Any])?["lastActivity"] as? String) ?? ""
            out.append(plain("\n◆ last session · " + (models.isEmpty ? "—" : shortModels(models)) + "\n"))
            out.append(plain(String(format: "   spent      $%.2f\n", cost)))
            out.append(plain(String(format: "   tokens     %@\n", fmtTokens(tokens))))
            out.append(plain("   activity   \(last)\n"))
        }

        out.append(plain("\nUpdated: " + Self.timeFmt.string(from: Date())))
        setDetail(out)

        populateHistorySubmenu(item: dailyItem, label: "daily",  rows: daily)
        populateHistorySubmenu(item: weeklyItem, label: "weekly", rows: weekly)

        if let n = payload["notif"] as? [String: Any] {
            notifEnabled = (n["enabled"] as? Bool) ?? false
            notifDelay   = (n["delay"]   as? Int)  ?? 60
        }
        rebuildNotifSubmenu()
        rebuildAlertItems()

        if let pct = fiveHourPct, let resetIso = fiveHourReset {
            checkAndFireAlert(util: pct, windowResetsAt: resetIso)
        }
    }

    /// Rebuilds the alert toggle + thresholds submenu to match current state.
    func rebuildAlertItems() {
        let toggleLabel: String
        if alertEnabled && !alertThresholds.isEmpty {
            let tiers = alertThresholds.sorted().map { "\($0)" }.joined(separator: "/")
            toggleLabel = "✓ alert  at \(tiers)%"
        } else {
            toggleLabel = "  alert  off"
        }
        alertToggleItem.attributedTitle = plain(toggleLabel)

        let tiersStr = alertThresholds.sorted().map(String.init).joined(separator: "/")
        alertThresholdItem.attributedTitle = plain("    thresholds  (\(tiersStr.isEmpty ? "—" : tiersStr + "%"))")
        let sub = NSMenu()
        for n in ALERT_THRESHOLD_OPTIONS {
            let mi = NSMenuItem(
                title: "",
                action: #selector(toggleAlertThreshold(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.tag = n
            let marker = alertThresholds.contains(n) ? "✓ " : "   "
            mi.attributedTitle = plain("\(marker)\(n)%")
            sub.addItem(mi)
        }
        alertThresholdItem.submenu = sub
    }

    @objc func toggleAlert() {
        alertEnabled.toggle()
        // When re-enabling, treat the current window as un-alerted so the
        // user gets a fresh chance to be notified at each enabled tier.
        if alertEnabled {
            alertedWindowResetsAt = nil
            firedTiersInWindow = []
        }
        saveAlertConfig()
        rebuildAlertItems()
    }

    @objc func toggleAlertThreshold(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        let tier = sender.tag
        if alertThresholds.contains(tier) {
            alertThresholds.remove(tier)
        } else {
            alertThresholds.insert(tier)
        }
        // Enable feature if any tier active; disable & clear when empty.
        alertEnabled = !alertThresholds.isEmpty
        // Reset fired-state so changes take effect immediately for the
        // current window.
        firedTiersInWindow = []
        alertedWindowResetsAt = nil
        saveAlertConfig()
        rebuildAlertItems()
        refresh()
    }

    /// Fires notifications for each enabled tier the utilization crosses,
    /// exactly once per 5h window (keyed by `resets_at`).
    func checkAndFireAlert(util: Double, windowResetsAt: String) {
        guard alertEnabled, !alertThresholds.isEmpty else { return }
        // New window? reset firedTiers
        if alertedWindowResetsAt != windowResetsAt {
            alertedWindowResetsAt = windowResetsAt
            firedTiersInWindow = []
        }
        for tier in alertThresholds.sorted() {
            if util >= Double(tier) && !firedTiersInWindow.contains(tier) {
                let body = String(format: "Current 5-hour session crossed %d%% (now at %.0f%%)", tier, util)
                sendNotification(title: "Claude usage", body: body)
                firedTiersInWindow.insert(tier)
            }
        }
        saveAlertConfig()
    }

    /// macOS notification via osascript. Self-contained — doesn't require
    /// Claude Code's hook infrastructure or any external script.
    func sendNotification(title: String, body: String) {
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"Glass\""
        DispatchQueue.global(qos: .background).async {
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Rebuilds the refresh-interval parent label + its submenu of choices.
    func rebuildIntervalSubmenu() {
        intervalItem.attributedTitle = plain("refresh interval  (\(refreshIntervalMinutes)m)")
        let sub = NSMenu()
        for m in INTERVAL_OPTIONS {
            let mi = NSMenuItem(
                title: "",
                action: #selector(pickInterval(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.tag = m
            let marker = (m == refreshIntervalMinutes) ? "✓ " : "   "
            mi.attributedTitle = plain("\(marker)\(m) min")
            sub.addItem(mi)
        }
        intervalItem.submenu = sub
    }

    @objc func pickInterval(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        refreshIntervalMinutes = sender.tag
        saveIntervalConfig()
        scheduleTimer()
        rebuildIntervalSubmenu()
    }

    func loadIntervalConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: INTERVAL_CONFIG_PATH)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = obj["minutes"] as? Int,
              INTERVAL_OPTIONS.contains(m)
        else { return }
        refreshIntervalMinutes = m
    }

    func saveIntervalConfig() {
        let obj: [String: Any] = ["minutes": refreshIntervalMinutes]
        let dir = (INTERVAL_CONFIG_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: INTERVAL_CONFIG_PATH), options: .atomic)
    }

    func loadAlertConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ALERT_CONFIG_PATH)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        alertEnabled          = (obj["enabled"] as? Bool) ?? false
        alertedWindowResetsAt = obj["alertedWindowResetsAt"] as? String
        // Migration: old schema kept a single `threshold: Int`; new schema
        // uses `thresholds: [Int]`. Read whichever is present.
        if let arr = obj["thresholds"] as? [Int], !arr.isEmpty {
            alertThresholds = Set(arr)
        } else if let single = obj["threshold"] as? Int {
            alertThresholds = [single]
        }
        if let fired = obj["firedTiers"] as? [Int] {
            firedTiersInWindow = Set(fired)
        }
    }

    // ── self-update ─────────────────────────────────────────────────────

    @objc func checkForUpdates() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let info = self.fetchLatestRelease()
            DispatchQueue.main.async { self.handleUpdateInfo(info) }
        }
    }

    /// Resolves which release source to query (GitHub or GitLab) from
    /// the sidecar config installed by `install.sh`, falling back to the
    /// hardcoded GitHub default.
    func loadUpdateConfig() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: UPDATE_CONFIG_PATH)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return DEFAULT_UPDATE_CONFIG }
        var cfg = DEFAULT_UPDATE_CONFIG
        for k in ["type", "url", "asset_name"] {
            if let v = obj[k] as? String { cfg[k] = v }
        }
        return cfg
    }

    /// Returns the latest release's tag + download URL of the asset,
    /// or nil on any error. Supports both the GitHub Releases API shape
    /// (object with `assets[].browser_download_url`) and the GitLab
    /// Releases API shape (array of objects with `assets.links[].url`).
    func fetchLatestRelease() -> (tag: String, downloadURL: String)? {
        let cfg = loadUpdateConfig()
        let asset = cfg["asset_name"] ?? "claude-usage-bar"
        guard let url = URL(string: cfg["url"] ?? "") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        switch cfg["type"] {
        case "gitlab":
            // GitLab returns an array of releases; pick the first.
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let latest = arr.first,
                  let tag = latest["tag_name"] as? String
            else { return nil }
            let links = ((latest["assets"] as? [String: Any])?["links"] as? [[String: Any]]) ?? []
            guard let link = links.first(where: { ($0["name"] as? String) == asset }),
                  let dl = link["url"] as? String
            else { return nil }
            return (tag, dl)
        default: // github
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String
            else { return nil }
            let assets = obj["assets"] as? [[String: Any]] ?? []
            guard let item = assets.first(where: { ($0["name"] as? String) == asset }),
                  let dl = item["browser_download_url"] as? String
            else { return nil }
            return (tag, dl)
        }
    }

    func handleUpdateInfo(_ info: (tag: String, downloadURL: String)?) {
        guard let info else {
            let src = loadUpdateConfig()["url"] ?? "the release API"
            showInfo(title: "Update check failed",
                     message: "Couldn't reach \(src). Check your network or try again later.")
            return
        }
        let remote = info.tag.hasPrefix("v") ? String(info.tag.dropFirst()) : info.tag
        if compareVersions(remote, WIDGET_VERSION) <= 0 {
            showInfo(title: "Up to date",
                     message: "You're on \(WIDGET_VERSION). Latest release is \(info.tag).")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update available: \(info.tag)"
        alert.informativeText = "You're on \(WIDGET_VERSION). Download and install \(info.tag) now? The widget will relaunch automatically."
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            performUpdate(from: info.downloadURL)
        }
    }

    /// Lexicographic-ish semver compare. Returns -1/0/1.
    func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Downloads the new binary to a tempfile, atomically replaces the
    /// current binary, then relaunches and quits. macOS allows
    /// overwriting a running executable as long as we do it via `mv`,
    /// so we can self-update without an external helper script.
    func performUpdate(from urlString: String) {
        let binaryPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let tempPath = "/tmp/claude-usage-bar.new.\(UUID().uuidString)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let curl = Process()
            curl.launchPath = "/usr/bin/curl"
            curl.arguments = ["-fsSL", urlString, "-o", tempPath]
            try? curl.run()
            curl.waitUntilExit()
            if curl.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self.showInfo(title: "Update failed", message: "curl exited \(curl.terminationStatus). Download did not complete.")
                }
                return
            }
            // chmod +x
            let chmod = Process()
            chmod.launchPath = "/bin/chmod"
            chmod.arguments = ["+x", tempPath]
            try? chmod.run()
            chmod.waitUntilExit()
            // mv over current binary
            let mv = Process()
            mv.launchPath = "/bin/mv"
            mv.arguments = [tempPath, binaryPath]
            try? mv.run()
            mv.waitUntilExit()
            if mv.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self.showInfo(title: "Update failed",
                                  message: "Couldn't replace \(binaryPath). Try with elevated permissions or move the install.")
                }
                return
            }
            DispatchQueue.main.async {
                let relaunch = Process()
                relaunch.launchPath = binaryPath
                try? relaunch.run()
                // Give the new instance a moment to register its status item
                // before this one tears down its own.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // ── alert / interval persistence ────────────────────────────────────

    func saveAlertConfig() {
        let obj: [String: Any] = [
            "enabled":               alertEnabled,
            "thresholds":            alertThresholds.sorted(),
            "firedTiers":            firedTiersInWindow.sorted(),
            "alertedWindowResetsAt": alertedWindowResetsAt as Any
        ]
        let dir = (ALERT_CONFIG_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: ALERT_CONFIG_PATH), options: .atomic)
    }

    /// Rebuilds the two notification menu items (top-level toggle + delay
    /// submenu parent) so they match the state read from settings.json.
    /// Called on every refresh, so external edits to settings.json show up
    /// after the next poll.
    func rebuildNotifSubmenu() {
        let toggleLabel = notifEnabled
            ? "✓ notifications  on \(notifDelay)s"
            : "  notifications  off"
        notifToggleItem.attributedTitle = plain(toggleLabel)

        notifDelayItem.attributedTitle = plain("    delay  (\(notifDelay)s)")
        let sub = NSMenu()
        for n in NOTIF_DELAY_OPTIONS {
            let mi = NSMenuItem(
                title: "",
                action: #selector(pickDelay(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.tag = n
            let marker = (notifEnabled && n == notifDelay) ? "✓ " : "   "
            mi.attributedTitle = plain("\(marker)\(n)s")
            sub.addItem(mi)
        }
        notifDelayItem.submenu = sub
    }

    @objc func toggleNotif() {
        let target = notifEnabled ? "off" : "on"
        let args = target == "on"
            ? ["set", "on", String(notifDelay)]
            : ["set", "off"]
        runNotifControl(args: args)
    }

    @objc func pickDelay(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        runNotifControl(args: ["set", "on", String(sender.tag)])
    }

    /// Runs the notif.sh control script and triggers a refresh on success
    /// so the menu reflects the new state immediately.
    func runNotifControl(args: [String]) {
        let scriptPath = (SCRIPT_PATH as NSString).deletingLastPathComponent + "/notif.sh"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = [scriptPath] + args
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func populateHistorySubmenu(item: NSMenuItem, label: String, rows: [[String: Any]]) {
        guard !rows.isEmpty else {
            item.isHidden = true
            item.submenu = nil
            return
        }
        item.isHidden = false
        // The parent item itself uses a custom view so its background stays
        // opaque too; the chevron is part of the text since the system one
        // is suppressed when .view is set.
        item.view = opaqueRowView(plain("\(label) (last \(rows.count))      ▸"), hPad: 18, vPad: 4)

        let sub = NSMenu()
        sub.addItem(makeOpaqueItem(plain("   period        cost    tokens   models")))
        for r in rows {
            let p = (r["period"] as? String) ?? "?"
            let c = (r["totalCost"] as? Double) ?? 0
            let t = sumTokens(r)
            let m = shortModels((r["modelsUsed"] as? [String]) ?? [])
            let line = String(format: "   %@   $%6.2f  %@   %@", p, c, fmtTokens(t), m)
            sub.addItem(makeOpaqueItem(plain(line)))
        }
        item.submenu = sub
    }

    func setDetail(_ s: NSAttributedString) {
        // wrap the text in a custom NSView with an opaque background, so the
        // dropdown doesn't show the system's translucent menu vibrancy through
        // our content
        let attr = NSMutableAttributedString(attributedString: s)
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { existing, range, _ in
            if existing[.font] == nil {
                attr.addAttribute(.font, value: Self.monoFont, range: range)
            }
        }
        detailItem.view = opaqueRowView(attr, hPad: 14, vPad: 6)
    }

    /// Builds an opaque-backgrounded NSView containing the given attributed text.
    /// Used to give menu items a solid background instead of the translucent
    /// vibrancy macOS applies by default.
    func opaqueRowView(_ attr: NSAttributedString, hPad: CGFloat, vPad: CGFloat) -> NSView {
        let label = NSTextField(labelWithAttributedString: attr)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        let fit = label.fittingSize
        let wrapper = OpaqueBackgroundView(frame: NSRect(
            x: 0, y: 0,
            width:  fit.width  + hPad * 2,
            height: fit.height + vPad * 2
        ))
        label.frame = NSRect(x: hPad, y: vPad, width: fit.width, height: fit.height)
        wrapper.addSubview(label)
        return wrapper
    }

    /// Creates a disabled NSMenuItem whose visible content is a custom
    /// opaque-background view. Used for read-only history rows.
    func makeOpaqueItem(_ attr: NSAttributedString) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = opaqueRowView(attr, hPad: 18, vPad: 2)
        item.isEnabled = false
        return item
    }

    // ── attributed-string helpers ───────────────────────────────────────
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Self.monoFont])
    }
    func coloredText(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Self.monoFont, .foregroundColor: color])
    }
    func barColor(_ pct: Double) -> NSColor {
        switch pct {
        case ..<60:  return .systemGreen
        case ..<85:  return .systemYellow
        default:     return .systemRed
        }
    }
    func makeBar(pct: Double, width: Int) -> NSAttributedString {
        let clamped = max(0.0, min(100.0, pct))
        let filled = Int((clamped / 100.0 * Double(width)).rounded())
        let empty = max(0, width - filled)
        let m = NSMutableAttributedString()
        if filled > 0 {
            m.append(NSAttributedString(string: String(repeating: "█", count: filled),
                                         attributes: [.font: Self.monoFont, .foregroundColor: barColor(pct)]))
        }
        if empty > 0 {
            m.append(NSAttributedString(string: String(repeating: "░", count: empty),
                                         attributes: [.font: Self.monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return m
    }
    /// Badge for Anthropic service-status degradations (statuspage indicator).
    /// Color map matches the upstream "minor/major/critical" semantics.
    func serviceStatusBadge(indicator: String, description: String) -> NSAttributedString {
        let color: NSColor
        switch indicator {
        case "minor":    color = .systemYellow
        case "major":    color = .systemOrange
        case "critical": color = .systemRed
        default:         color = .systemYellow
        }
        return coloredText("⚠ Anthropic: \(description)\n", color: color)
    }

    /// "pace  87% projected at reset · +$12 more" line, colored by projected value.
    /// The 5h window is 300 minutes long; elapsed = 300 - mins-until-reset.
    /// If a ccusage active-block payload is provided, also appends the
    /// projected additional cost (`projection.totalCost - costUSD`).
    func paceLine(currentPct: Double, minutesUntilReset: Int,
                  activeBlock: [String: Any]? = nil) -> NSAttributedString? {
        let elapsed = 300 - minutesUntilReset
        guard elapsed > 0 else { return nil }
        let projected = currentPct / Double(elapsed) * 300.0
        let clamped = min(projected, 999)
        let arrow = projected <= 100 ? "→" : "⚠"

        var summary: String
        if projected > 100 {
            let minutesTo100 = currentPct < 100
                ? Int(Double(elapsed) * (100 - currentPct) / currentPct)
                : 0
            summary = String(format: "   pace      %@ %.0f%% at reset (hits 100%% in %dm)",
                             arrow, clamped, minutesTo100)
        } else {
            summary = String(format: "   pace      %@ %.0f%% projected at reset",
                             arrow, clamped)
        }

        // Append projected additional spend, if ccusage gave us the numbers.
        if let a = activeBlock,
           let spent = a["costUSD"] as? Double,
           let projectedTotal = (a["projection"] as? [String: Any])?["totalCost"] as? Double {
            let delta = max(0, projectedTotal - spent)
            if delta >= 0.01 {
                summary += String(format: "  ·  +$%.2f more", delta)
            }
        }

        return coloredText(summary, color: barColor(clamped))
    }

    func appendBucketLine(_ out: NSMutableAttributedString, label: String, b: [String: Any]) {
        let pct = b["utilization"] as? Double ?? 0
        let resetIso = b["resets_at"] as? String ?? ""
        out.append(plain("   \(label) "))
        out.append(makeBar(pct: pct, width: 20))
        out.append(coloredText(String(format: "  %5.1f%%", pct), color: barColor(pct)))
        if let m = minutesUntil(iso: resetIso), m > 0 {
            let h = m / 60, mm = m % 60
            out.append(plain(String(format: "  resets in %dh %02dm", h, mm)))
            if let local = formatLocalTime(iso: resetIso) {
                out.append(plain(" (\(local))"))
            }
        }
        out.append(plain("\n"))
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    static let isoIn: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    func formatLocalTime(iso: String) -> String? {
        guard let d = Self.isoIn.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    /// Human-friendly "Xh YYm" / "Nm" for reset countdown. Used in the
    /// status bar title to keep it readable when the window has hours left.
    func formatResetMinutes(_ m: Int) -> String {
        if m < 60 { return "\(m)m" }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    func minutesUntil(iso: String) -> Int? {
        guard !iso.isEmpty,
              let d = Self.isoIn.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return nil }
        let diff = d.timeIntervalSinceNow
        return diff > 0 ? Int(diff / 60) : 0
    }

}

// Headless mode short-circuits the Cocoa app — useful for SSH sessions,
// scripts, cron, or status bars on remote/headless Macs. Runs usage.sh
// once, prints a one-liner (or JSON), exits.
if CommandLine.arguments.contains("--headless") {
    runHeadless(asJSON: CommandLine.arguments.contains("--json"))
    exit(0)
}

func runHeadless(asJSON: Bool) {
    let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let scriptPath = (exePath as NSString).deletingLastPathComponent + "/usage.sh"
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [scriptPath]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { fputs("failed to launch usage.sh: \(error)\n", stderr); return }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard task.terminationStatus == 0,
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        fputs("usage.sh exited \(task.terminationStatus) or returned invalid JSON\n", stderr)
        return
    }

    let oauth = payload["oauth"] as? [String: Any] ?? [:]
    let fh = oauth["five_hour"] as? [String: Any]
    let sd = oauth["seven_day"] as? [String: Any]
    let svc = payload["service"] as? [String: Any]

    let session   = fh?["utilization"] as? Double
    let week      = sd?["utilization"] as? Double
    let resetIso  = fh?["resets_at"] as? String ?? ""
    let svcInd    = svc?["indicator"] as? String ?? "unknown"
    let svcDesc   = svc?["description"] as? String ?? ""

    var minsLeft: Int? = nil
    if !resetIso.isEmpty {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: resetIso) ?? ISO8601DateFormatter().date(from: resetIso) {
            minsLeft = max(0, Int(date.timeIntervalSinceNow / 60))
        }
    }

    var pace: Double? = nil
    if let s = session, let m = minsLeft {
        let elapsed = 300 - m
        if elapsed > 0 { pace = s / Double(elapsed) * 300 }
    }

    if asJSON {
        var out: [String: Any] = [:]
        if let s = session  { out["session"] = s }
        if let w = week     { out["week"] = w }
        if let m = minsLeft { out["minutes_left"] = m }
        if let p = pace     { out["pace_projected"] = p }
        out["service_indicator"]   = svcInd
        out["service_description"] = svcDesc
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        var parts: [String] = []
        if let s = session {
            parts.append(String(format: "session %.0f%%", s))
        }
        if let m = minsLeft {
            parts.append(m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m)m")
        }
        if let p = pace {
            let arrow = p <= 100 ? "→" : "⚠"
            parts.append(String(format: "pace %@ %.0f%%", arrow, min(p, 999)))
        }
        if let w = week {
            parts.append(String(format: "week %.0f%%", w))
        }
        if svcInd != "none" && svcInd != "unknown" {
            parts.append("⚠ \(svcDesc)")
        }
        print(parts.joined(separator: " · "))
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
