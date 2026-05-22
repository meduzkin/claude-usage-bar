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

/// Brand-ish colours for each provider's bullet glyph. Used as the
/// "icon" in dropdown section headers — gives the eye a quick scan
/// without committing to actual logo images.
let PROVIDER_COLORS: [String: NSColor] = [
    "claude":  NSColor(srgbRed: 0.85, green: 0.46, blue: 0.34, alpha: 1.0),  // Anthropic warm
    "codex":   NSColor(srgbRed: 0.06, green: 0.64, blue: 0.49, alpha: 1.0),  // OpenAI green
    "gemini":  NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1.0),  // Google blue
    "copilot": NSColor(srgbRed: 0.55, green: 0.41, blue: 1.00, alpha: 1.0),  // Copilot purple
]

/// Pace projection is hidden when less than this fraction of the 5h
/// window has elapsed — projections from <3% sample are noise.
let PACE_MIN_ELAPSED_FRACTION: Double = 0.03

/// Fixed content width for the dropdown body — drives bar width and the
/// right-alignment of two-column rows like "X% used … Resets in Yh Zm".
let CONTENT_WIDTH: CGFloat = 280

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
let WIDGET_VERSION = "0.4.0"
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
    var lastSuccessfulRefreshAt: Date = .distantPast
    let detailItem  = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    let detailsSubItem = NSMenuItem(title: "details", action: nil, keyEquivalent: "")
    let dailyItem   = NSMenuItem(title: "daily",  action: nil, keyEquivalent: "")
    let weeklyItem  = NSMenuItem(title: "weekly", action: nil, keyEquivalent: "")
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
        detailsSubItem.isHidden = true
        dailyItem.isHidden = true
        weeklyItem.isHidden = true
        menu.addItem(detailsSubItem)
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
        let refreshMI = menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshMI.target = self
        refreshMI.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)

        let updateMI = menu.addItem(withTitle: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateMI.target = self
        updateMI.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)

        let aboutItem = NSMenuItem(title: "version \(WIDGET_VERSION)", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)

        let quitMI = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitMI.target = self
        quitMI.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)

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

        // Track freshness — used to dim the status bar title when refresh
        // pipeline has been silently failing.
        if fiveHourPct != nil {
            lastSuccessfulRefreshAt = Date()
        }

        // ── status bar title: compact glance ────────────────────────────
        //   [████░░] 32%      ← always visible
        // Full info moves to the tooltip; the dropdown holds the detail.
        let isStale = lastSuccessfulRefreshAt != .distantPast &&
                      Date().timeIntervalSince(lastSuccessfulRefreshAt) >
                        Double(refreshIntervalMinutes * 60) * 2.5
        let titleStr = NSMutableAttributedString()
        if let pct = fiveHourPct {
            titleStr.append(makeBar(pct: pct, width: 8))
            let pctColor = isStale ? NSColor.tertiaryLabelColor : barColor(pct)
            titleStr.append(coloredText(String(format: " %.0f%%", pct), color: pctColor))
            statusItem.button?.attributedTitle = titleStr

            // Tooltip carries the parts we stripped from the title
            var tip = String(format: "Claude · session %.0f%%", pct)
            if let m = fiveHourResetMin { tip += " · resets in \(formatResetMinutes(m))" }
            if let sd = sevenDay, let weekPct = sd["utilization"] as? Double {
                tip += String(format: " · week %.0f%%", weekPct)
            }
            if isStale { tip += " · (data stale)" }
            statusItem.button?.toolTip = tip
        } else if let a = active {
            let cost = a["costUSD"] as? Double ?? 0
            let remMin = (a["projection"] as? [String: Any])?["remainingMinutes"] as? Int ?? 0
            statusItem.button?.title = String(format: "$%.2f · ", cost) + formatResetMinutes(remMin)
            statusItem.button?.toolTip = "no oauth data — showing ccusage block cost"
        } else {
            statusItem.button?.title = "claude —"
            statusItem.button?.toolTip = "no data — open dropdown to refresh"
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

        // Tracks whether we already emitted a section, so we can drop a
        // separator before each subsequent one.
        var emittedSection = false
        func sectionSpacer() {
            if emittedSection {
                out.append(separatorLine())
                out.append(plainSized("\n\n", font: Self.subFont))
            }
            emittedSection = true
        }
        let nl = { (font: NSFont) in self.plainSized("\n", font: font) }

        /// Single-line muted subtitle under the section header. No tab-stops
        /// — avoids the right-aligned wrap bug.
        func subtitleLine(_ parts: [String], _ extra: NSAttributedString? = nil) {
            let s = parts.joined(separator: "  ·  ")
            out.append(plainSized(s, font: Self.subFont, color: .secondaryLabelColor))
            if let extra { out.append(extra) }
            out.append(nl(Self.subFont))
            out.append(nl(Self.subFont))
        }

        if fiveHour != nil || sevenDay != nil {
            sectionSpacer()
            out.append(sectionHeader("Claude", key: "claude"))
            out.append(nl(Self.headerFont))
            subtitleLine(["updated " + Self.timeFmt.string(from: Date()), "OAuth"])

            if let f = fiveHour { appendBucketBlock(out, label: "Session", b: f) }
            if let s = sevenDay { appendBucketBlock(out, label: "Weekly",  b: s) }
            // Pace narrative sits under Weekly.
            if let pct = fiveHourPct, let mins = fiveHourResetMin {
                if let line = paceNarrativeLine(currentPct: pct, minutesUntilReset: mins,
                                                activeBlock: active) {
                    out.append(line)
                    out.append(nl(Self.paceFont))
                    out.append(nl(Self.subFont))
                }
            }
            if let o = oauth["seven_day_opus"]   as? [String: Any] {
                appendBucketBlock(out, label: "Opus", b: o)
            }
            if let s = oauth["seven_day_sonnet"] as? [String: Any] {
                appendBucketBlock(out, label: "Sonnet", b: s)
            }
        }

        // Codex section — only when the user has an authenticated OpenAI Codex CLI install.
        if let codex = payload["codex"] as? [String: Any], !codex.isEmpty {
            let cx5 = codex["five_hour"] as? [String: Any]
            let cx7 = codex["seven_day"] as? [String: Any]
            if cx5 != nil || cx7 != nil {
                sectionSpacer()
                out.append(sectionHeader("Codex", key: "codex"))
                out.append(nl(Self.headerFont))
                var parts = ["updated " + Self.timeFmt.string(from: Date())]
                if let src = codex["source"] as? String, src == "rpc" {
                    parts.append("via app-server")
                }
                let stale = (codex["stale"] as? Bool) == true
                if stale {
                    let extra = plainSized("  ·  token stale", font: Self.subFont, color: .systemYellow)
                    subtitleLine(parts, extra)
                } else {
                    parts.append("OAuth")
                    subtitleLine(parts)
                }
                if let f = cx5 { appendBucketBlock(out, label: "Session", b: f) }
                if let s = cx7 { appendBucketBlock(out, label: "Weekly",  b: s) }
            }
        }

        // Gemini Code Assist — per-model quota buckets.
        if let gemini = payload["gemini"] as? [String: Any],
           let models = gemini["models"] as? [[String: Any]], !models.isEmpty {
            sectionSpacer()
            out.append(sectionHeader("Gemini", key: "gemini"))
            out.append(nl(Self.headerFont))
            subtitleLine(["updated " + Self.timeFmt.string(from: Date()), "Code Assist"])
            for m in models {
                let name = (m["name"] as? String) ?? "model"
                let bucket: [String: Any] = [
                    "utilization": m["utilization"] ?? 0,
                    "resets_at":   m["resets_at"]   ?? "",
                ]
                appendBucketBlock(out, label: name, b: bucket)
            }
        }

        // GitHub Copilot — chat / completions / premium quotas.
        if let copilot = payload["copilot"] as? [String: Any], !copilot.isEmpty {
            let entries: [(String, String)] = [
                ("Chat", "chat"),
                ("Completions", "completions"),
                ("Premium interactions", "premium"),
            ]
            let buckets = entries.compactMap { tup -> (String, [String: Any])? in
                guard let b = copilot[tup.1] as? [String: Any] else { return nil }
                return (tup.0, b)
            }
            if !buckets.isEmpty {
                sectionSpacer()
                out.append(sectionHeader("Copilot", key: "copilot"))
                out.append(nl(Self.headerFont))
                subtitleLine(["updated " + Self.timeFmt.string(from: Date()), "GitHub"])
                for (label, b) in buckets {
                    if (b["unlimited"] as? Bool) == true {
                        out.append(metricHeader(label))
                        out.append(nl(Self.metricFont))
                        out.append(plainSized("unlimited", font: Self.monoSub,
                                              color: .secondaryLabelColor))
                        out.append(nl(Self.monoSub))
                        out.append(nl(Self.monoSub))
                    } else {
                        appendBucketBlock(out, label: label, b: b)
                    }
                }
            }
        }

        // 5h block + last session move into the `details ▸` submenu — keeps
        // the main dropdown focused on the headline (provider bars + pace).
        let detailsOut = NSMutableAttributedString()
        if let a = active {
            let cost = a["costUSD"] as? Double ?? 0
            let proj = (a["projection"] as? [String: Any])?["totalCost"] as? Double ?? 0
            let remMin = (a["projection"] as? [String: Any])?["remainingMinutes"] as? Int ?? 0
            let burn = (a["burnRate"] as? [String: Any])?["costPerHour"] as? Double ?? 0
            let tpm = (a["burnRate"] as? [String: Any])?["tokensPerMinute"] as? Double ?? 0
            let endTime = a["endTime"] as? String ?? ""
            let models = (a["models"] as? [String]) ?? []
            let tokens = blockTotalTokens(a)

            detailsOut.append(plain("◆ 5h block · " + (models.isEmpty ? "—" : shortModels(models)) + "\n"))
            detailsOut.append(plain(String(format: "   spent      $%.2f\n", cost)))
            detailsOut.append(plain(String(format: "   tokens     %@\n", fmtTokens(tokens))))
            detailsOut.append(plain(String(format: "   projected  $%.2f\n", proj)))
            detailsOut.append(plain(String(format: "   burn       $%.2f/h  %@/min\n", burn, fmtTokens(Int(tpm)))))
            var resets = String(format: "   resets in  %dh %02dm", remMin / 60, remMin % 60)
            if let local = formatLocalTime(iso: endTime) { resets += " at \(local)" }
            detailsOut.append(plain(resets + "\n"))
        } else {
            detailsOut.append(plain("◆ 5h block\n   (no active block — run something in Claude Code)\n"))
        }

        if let s = session {
            let cost = s["totalCost"] as? Double ?? 0
            let tokens = sumTokens(s)
            let models = (s["modelsUsed"] as? [String]) ?? []
            let last = ((s["metadata"] as? [String: Any])?["lastActivity"] as? String) ?? ""
            detailsOut.append(plain("\n◆ last session · " + (models.isEmpty ? "—" : shortModels(models)) + "\n"))
            detailsOut.append(plain(String(format: "   spent      $%.2f\n", cost)))
            detailsOut.append(plain(String(format: "   tokens     %@\n", fmtTokens(tokens))))
            detailsOut.append(plain("   activity   \(last)\n"))
        }

        // No trailing footer — each section already carries its own
        // "Updated HH:MM" subtitle.
        setDetail(out)
        populateDetailsSubmenu(detailsOut)

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
            toggleLabel = "alert · on · \(tiers)%"
        } else {
            toggleLabel = "alert · off"
        }
        alertToggleItem.attributedTitle = plain(toggleLabel)
        // Outlined + dimmed triangle when off so the warn glyph doesn't
        // demand attention for a feature that's intentionally disabled.
        alertToggleItem.image = tintedSymbol(
            name: alertEnabled ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
            color: alertEnabled ? nil : NSColor.tertiaryLabelColor
        )

        let tiersStr = alertThresholds.sorted().map(String.init).joined(separator: "/")
        alertThresholdItem.attributedTitle = plain("thresholds  (\(tiersStr.isEmpty ? "—" : tiersStr + "%"))")
        alertThresholdItem.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: nil)
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
        intervalItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
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
            ? "notifications · on · \(notifDelay)s"
            : "notifications · off"
        notifToggleItem.attributedTitle = plain(toggleLabel)
        notifToggleItem.image = tintedSymbol(
            name: notifEnabled ? "bell.fill" : "bell.slash",
            color: notifEnabled ? nil : NSColor.tertiaryLabelColor
        )

        notifDelayItem.attributedTitle = plain("delay  (\(notifDelay)s)")
        notifDelayItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
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

    /// Wraps the 5h-block + last-session block into the `details ▸`
    /// parent's submenu. Hidden when there's no content to show.
    func populateDetailsSubmenu(_ content: NSAttributedString) {
        guard content.length > 0 else {
            detailsSubItem.isHidden = true
            detailsSubItem.submenu = nil
            return
        }
        detailsSubItem.isHidden = false
        detailsSubItem.view = opaqueRowView(plain("details      ▸"), hPad: 18, vPad: 4)
        let sub = NSMenu()
        let body = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        body.view = opaqueRowView(content, hPad: 18, vPad: 4)
        body.isEnabled = false
        sub.addItem(body)
        detailsSubItem.submenu = sub
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
        // Use the fixed content width so right-aligned tab stops in
        // twoColLine actually push the right column to the far edge.
        detailItem.view = opaqueRowView(attr, hPad: 14, vPad: 8, fixedWidth: CONTENT_WIDTH)
    }

    /// Builds an opaque-backgrounded NSView containing the given attributed text.
    /// When `fixedWidth` is supplied, the inner label is sized to that
    /// width (needed for tab-stop right-alignment to land on the edge);
    /// height is measured for that width.
    func opaqueRowView(_ attr: NSAttributedString, hPad: CGFloat, vPad: CGFloat,
                       fixedWidth: CGFloat? = nil) -> NSView {
        let label = NSTextField(labelWithAttributedString: attr)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false
        let fit: NSSize
        if let w = fixedWidth {
            label.preferredMaxLayoutWidth = w
            let h = label.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height
            fit = NSSize(width: w, height: h)
        } else {
            fit = label.fittingSize
        }
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
    static let monoFont    = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Bold provider-name header. Slightly smaller than CodexBar's so
    /// the screen has room without the bar widget feeling oversized.
    static let headerFont  = NSFont.systemFont(ofSize: 15, weight: .bold)
    /// Metric block heading: Session / Weekly / Sonnet / etc.
    static let metricFont  = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Compact monospace for the inline figures under each bar — our
    /// signature touch versus CodexBar's prose two-column layout.
    static let monoSub     = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// Section subtitle ("Updated HH:MM · OAuth").
    static let subFont     = NSFont.systemFont(ofSize: 11, weight: .regular)
    /// Pace narrative line — same metrics as monoSub for visual alignment.
    static let paceFont    = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: Self.monoFont])
    }
    func plainSized(_ s: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
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
    /// Heavier mono font used for bar glyphs in places where we still use
    /// character-based bars (currently only the menu bar title — the
    /// dropdown switched to drawn bars below).
    static let barFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)

    /// Character-bar fallback (kept for the menu bar status title, where
    /// embedding an NSImage attachment doesn't render reliably).
    func makeBar(pct: Double, width: Int) -> NSAttributedString {
        let clamped = max(0.0, min(100.0, pct))
        let filled = Int((clamped / 100.0 * Double(width)).rounded())
        let empty = max(0, width - filled)
        let m = NSMutableAttributedString()
        if filled > 0 {
            m.append(NSAttributedString(string: String(repeating: "█", count: filled),
                                         attributes: [.font: Self.barFont, .foregroundColor: barColor(pct)]))
        }
        if empty > 0 {
            m.append(NSAttributedString(string: String(repeating: "░", count: empty),
                                         attributes: [.font: Self.barFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return m
    }

    /// Renders a rounded progress bar as an NSImage and returns it wrapped
    /// in an NSAttributedString attachment for inline placement in
    /// dropdown rows. Visually closer to the native macOS look than the
    /// `█░` block-glyph version.
    func drawnBar(pct: Double, width: CGFloat = 120, height: CGFloat = 8) -> NSAttributedString {
        let clamped = max(0.0, min(100.0, pct))
        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let radius = height / 2
            // Track
            NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            // Fill
            let fillW = rect.width * clamped / 100.0
            if fillW > 0 {
                let fillRect = NSRect(x: 0, y: 0, width: max(fillW, height), height: rect.height)
                self.barColor(clamped).setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: -1, width: width, height: height)
        return NSAttributedString(attachment: att)
    }
    /// Returns the named SF Symbol image, optionally tinted via palette
    /// configuration. Used for menu item icons that need to look dimmer
    /// (e.g. an "off" toggle) without changing the glyph itself.
    func tintedSymbol(name: String, color: NSColor?) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        guard let color else { return img }
        let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
        return img.withSymbolConfiguration(cfg) ?? img
    }

    /// SF Symbol that visually evokes each provider's actual brand mark.
    /// Not the official logos (those would need bundled image assets and
    /// have trademark caveats) — these are close-enough native macOS glyphs
    /// that read as "Anthropic / OpenAI / Google / GitHub" at a glance.
    func providerSymbol(_ key: String) -> String {
        switch key {
        case "claude":  return "asterisk"               // Anthropic's mark is an asterisk
        case "codex":   return "circle.hexagongrid"     // OpenAI's hexagonal floral motif
        case "gemini":  return "sparkles"               // Gemini's literal icon
        case "copilot": return "chevron.left.forwardslash.chevron.right" // GH Copilot code-y
        default:        return "circle.fill"
        }
    }

    /// Bold provider-name heading with a brand-tinted SF-symbol on the
    /// left. Matches CodexBar's section style — large, system font, no
    /// monospace. Returns the line WITHOUT a trailing newline so the
    /// caller can decide spacing.
    func sectionHeader(_ name: String, key: String) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let tint = PROVIDER_COLORS[key] ?? NSColor.labelColor
        let symName = providerSymbol(key)
        if let raw = NSImage(systemSymbolName: symName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(.init(paletteColors: [tint]))
            let img = raw.withSymbolConfiguration(cfg) ?? raw
            let attachment = NSTextAttachment()
            attachment.image = img
            attachment.bounds = NSRect(x: 0, y: -2, width: 16, height: 16)
            m.append(NSAttributedString(attachment: attachment))
            m.append(plainSized("  ", font: Self.headerFont))
        } else {
            m.append(plainSized("●  ", font: Self.headerFont, color: tint))
        }
        m.append(plainSized(name, font: Self.headerFont))
        return m
    }

    /// Bold metric heading inside a provider block — "Session", "Weekly", etc.
    func metricHeader(_ name: String) -> NSAttributedString {
        plainSized(name, font: Self.metricFont)
    }

    /// Thin horizontal separator rendered as an NSImage attachment so it
    /// inlines cleanly into the dropdown's attributed text.
    func separatorLine() -> NSAttributedString {
        let img = NSImage(size: NSSize(width: CONTENT_WIDTH, height: 1), flipped: false) { rect in
            NSColor.separatorColor.setFill()
            rect.fill()
            return true
        }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: 3, width: CONTENT_WIDTH, height: 1)
        return NSAttributedString(attachment: att)
    }

    /// Two-column row: `left` flush left, `right` flush right against
    /// CONTENT_WIDTH via a right-aligned tab stop. Both default to muted
    /// secondary color so the bucket's bar stays the visual anchor.
    func twoColLine(left: String, right: String,
                    font: NSFont? = nil,
                    leftColor: NSColor = .secondaryLabelColor,
                    rightColor: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let f = font ?? Self.subFont
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: CONTENT_WIDTH, options: [:])]
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(string: left, attributes: [
            .font: f, .foregroundColor: leftColor, .paragraphStyle: para,
        ]))
        m.append(NSAttributedString(string: "\t" + right, attributes: [
            .font: f, .foregroundColor: rightColor, .paragraphStyle: para,
        ]))
        return m
    }

    /// "Xh YYm" for short windows, "Xd Yh" once the remaining time crosses
    /// a day — keeps the right-aligned reset countdown compact.
    func formatResetLong(_ minutes: Int) -> String {
        if minutes >= 60 * 24 {
            let d = minutes / (60 * 24)
            let h = (minutes % (60 * 24)) / 60
            return "\(d)d \(h)h"
        }
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%dh %02dm", h, m)
    }

    /// Legacy thin header used in setDetail's pre-data placeholder paths.
    /// Kept so non-render callers don't break. New layout uses sectionHeader.
    func providerHeader(_ name: String, key: String, newline: Bool = true) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: sectionHeader(name, key: key))
        if newline { m.append(plainSized("\n", font: Self.headerFont)) }
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

/// Metric block: bold label, full-width pill bar, then a single
    /// monospace line "%pct · resets in Xh Ym". Single-line on purpose —
    /// keeps numerics colour-coded (our identity) and sidesteps the
    /// tab-stop wrap that the right-aligned two-column layout triggered.
    func appendBucketBlock(_ out: NSMutableAttributedString, label: String, b: [String: Any],
                           showReset: Bool = true) {
        let pct = b["utilization"] as? Double ?? 0
        let resetIso = b["resets_at"] as? String ?? ""

        out.append(metricHeader(label))
        out.append(plainSized("\n", font: Self.metricFont))
        out.append(drawnBar(pct: pct, width: CONTENT_WIDTH, height: 7))
        out.append(plainSized("\n", font: Self.monoSub))

        let pctColor = barColor(pct)
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: String(format: "%.1f%%", pct),
            attributes: [.font: Self.monoSub, .foregroundColor: pctColor]
        ))
        if showReset, let m = minutesUntil(iso: resetIso), m > 0 {
            line.append(NSAttributedString(
                string: "  ·  resets in " + formatResetLong(m),
                attributes: [.font: Self.monoSub, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        out.append(line)
        out.append(plainSized("\n\n", font: Self.monoSub))
    }

    /// Pace narrative — colour-coded by outcome (red/yellow/green) so the
    /// state reads at a glance. This is our distinctive twist on the
    /// CodexBar "Pace: Behind (-X%) · Lasts to reset" format.
    func paceNarrativeLine(currentPct: Double, minutesUntilReset: Int,
                           activeBlock: [String: Any]? = nil) -> NSAttributedString? {
        let elapsed = 300 - minutesUntilReset
        guard elapsed > 0 else { return nil }
        if Double(elapsed) / 300.0 < PACE_MIN_ELAPSED_FRACTION { return nil }
        let projected = currentPct / Double(elapsed) * 300.0

        let outcome: String
        let outcomeColor: NSColor
        if projected > 100 {
            let minutesTo100 = currentPct < 100
                ? Int(Double(elapsed) * (100 - currentPct) / currentPct)
                : 0
            let runOut = minutesTo100 >= 60
                ? String(format: "%dh %02dm", minutesTo100 / 60, minutesTo100 % 60)
                : "\(minutesTo100)m"
            outcome = "runs out in \(runOut)"
            outcomeColor = .systemRed
        } else if projected >= 80 {
            outcome = "lasts until reset (tight)"
            outcomeColor = .systemYellow
        } else {
            outcome = "lasts until reset"
            outcomeColor = .systemGreen
        }
        let m = NSMutableAttributedString()
        m.append(plainSized("pace  ", font: Self.paceFont, color: .secondaryLabelColor))
        m.append(plainSized(outcome, font: Self.paceFont, color: outcomeColor))
        // Optional projected extra spend.
        if let a = activeBlock,
           let spent = a["costUSD"] as? Double,
           let projectedTotal = (a["projection"] as? [String: Any])?["totalCost"] as? Double {
            let delta = max(0, projectedTotal - spent)
            if delta >= 0.01 {
                m.append(plainSized(String(format: "  ·  +$%.2f more", delta),
                                    font: Self.paceFont, color: .secondaryLabelColor))
            }
        }
        return m
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
