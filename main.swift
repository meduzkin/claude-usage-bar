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

// When running from a .app bundle, scripts live in Contents/Resources/.
// When running as a bare binary (dev / install.sh --no-app), they sit
// next to the executable. Check the bundle path first; fall back to the
// executable's directory.
let SCRIPT_PATH: String = {
    if Bundle.main.bundlePath.hasSuffix(".app"),
       let resourcePath = Bundle.main.resourcePath,
       FileManager.default.fileExists(atPath: resourcePath + "/usage.sh") {
        return resourcePath + "/usage.sh"
    }
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

/// Fixed content width for the dropdown body. Sized to fit the
/// "Session [bar] 77.0% · 1h 17m" + pace-line full width without
/// wrapping in semibold monospaced font.
let CONTENT_WIDTH: CGFloat = 320

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
let WIDGET_VERSION = "0.5.6"
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
// Tracks the last release tag we already notified the user about, so the
// daily background check doesn't re-nag them about the same version.
// Reset (delete the file) to force a fresh notification on next check.
let UPDATE_CHECK_STATE_PATH = "\(NSHomeDirectory())/.cache/claude-usage-bar/update-check.json"
// Persists the compact-mode toggle + which providers the user wants to see
// in the menu-bar title when compact mode is on.
let DISPLAY_CONFIG_PATH = "\(NSHomeDirectory())/.cache/claude-usage-bar/display.json"
// Provider order shown in the compact title. Same order as the dropdown
// section list so the eye reads them consistently across both surfaces.
let COMPACT_PROVIDER_ORDER: [String] = ["claude", "codex", "gemini", "copilot"]
// Background update poll cadence. 24h is enough — releases ship on the
// order of days, and the GitHub Releases API is cheap (single GET, no
// per-IP throttle that we'd hit at this rate).
let UPDATE_CHECK_INTERVAL: TimeInterval = 24 * 3600
// Delay before the first background check after launch. Keeps startup
// quick and avoids stampeding the API if a bunch of widgets relaunch at
// login at the same wall-clock minute.
let UPDATE_CHECK_INITIAL_DELAY: TimeInterval = 60

// Delay options offered in the notifications submenu (seconds).
let NOTIF_DELAY_OPTIONS: [Int] = [30, 60, 120, 300]
// Threshold options offered in the usage-alert submenu (percent).
// Multiple may be enabled at once — each fires exactly once per 5h window
// (keyed by the window's `resets_at` timestamp).
let ALERT_THRESHOLD_OPTIONS: [Int] = [25, 50, 75, 90, 95]
// LaunchAgent that runs the widget at login. Path + label match install.sh
// so a UI toggle and the installer agree on the same plist.
let LAUNCH_AGENT_LABEL: String = "com.local.claude-usage-bar"
let LAUNCH_AGENT_PLIST: String = "\(NSHomeDirectory())/Library/LaunchAgents/\(LAUNCH_AGENT_LABEL).plist"
// Where alert config + last-fired window are persisted.
let ALERT_CONFIG_PATH: String = {
    let home = NSHomeDirectory()
    return "\(home)/.cache/claude-usage-bar/alert.json"
}()

class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var updateCheckTimer: Timer?
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
    let autostartToggleItem = NSMenuItem(title: "autostart",  action: nil, keyEquivalent: "")
    let compactToggleItem   = NSMenuItem(title: "compact",    action: nil, keyEquivalent: "")
    let compactProvidersItem = NSMenuItem(title: "providers", action: nil, keyEquivalent: "")
    var compactMode = false
    var compactProviders: Set<String> = ["claude"]
    var autostartEnabled = false
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
        // Parent toggles (Notifications / Usage alert / Compact mode) have
        // no action — only a submenu. NSMenu's auto-enable logic disables
        // such items when target validation fails, which makes the submenu
        // refuse to open. Disable auto-enable; we manage validation ourselves.
        menu.autoenablesItems = false
        detailItem.isEnabled = false
        setDetail(plain("Loading…"))
        menu.addItem(detailItem)
        menu.addItem(.separator())
        detailsSubItem.isHidden = true
        menu.addItem(detailsSubItem)
        menu.addItem(.separator())
        // Display section — controls how the title looks in the menu bar
        // (bar + percent vs. compact provider-icon + percent).
        menu.addItem(menuSectionLabel("DISPLAY"))
        // Submenu hangs off the parent (off + provider checkboxes) — same
        // shape as Notifications / Usage alert, no separate "providers" row.
        menu.addItem(compactToggleItem)
        menu.addItem(.separator())
        // Section label above the alerting block so it reads as its own
        // group rather than blending into the maintenance footer.
        menu.addItem(menuSectionLabel("ALERTS & NOTIFICATIONS"))
        // Submenus hang off the parent toggles directly — clicking the
        // parent opens the submenu (off / 30s / 60s / …) so off/on/delay
        // all live in one place instead of as separate rows.
        menu.addItem(notifToggleItem)
        menu.addItem(alertToggleItem)
        autostartToggleItem.target = self
        autostartToggleItem.action = #selector(toggleAutostart)
        menu.addItem(autostartToggleItem)
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
        migrateLaunchAgentIfStale()
        refreshAutostartState()
        rebuildAutostartItem()
        loadDisplayConfig()
        rebuildCompactItems()

        refresh()
        scheduleTimer()
        scheduleUpdateCheck()
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
        // Attach the menu and let the system open it. Detaching happens
        // in menuDidClose — detaching via async timer used to race with
        // submenu hover tracking and silently kill all child submenus.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach only the root menu so the next click on the status bar
        // routes through statusItemClicked again (preserving right-click
        // refresh). Submenu closures also call menuDidClose; ignore those.
        if menu === self.menu {
            statusItem.menu = nil
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
        if compactMode {
            // Compact: provider icon(s) + %, no bar.
            statusItem.button?.attributedTitle = makeCompactTitle(payload: payload)
        } else if let pct = fiveHourPct {
            titleStr.append(makeBar(pct: pct, width: 8))
            let pctColor = isStale ? NSColor.tertiaryLabelColor : barColor(pct)
            // Pad the digits to width 3 so the title doesn't shift left on
            // the 9→10 / 99→100 transitions; the bar is fixed-width already.
            titleStr.append(coloredText(String(format: " %3.0f%%", pct), color: pctColor))
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
                out.append(plainSized("\n", font: Self.subFont))
                out.append(separatorLine())
                out.append(plainSized("\n", font: Self.subFont))
            }
            emittedSection = true
        }
        let nl = { (font: NSFont) in self.plainSized("\n", font: font) }

        /// Single-line muted subtitle under a section header.
        func subtitleLine(_ parts: [String], _ extra: NSAttributedString? = nil) {
            let s = parts.joined(separator: "  ·  ")
            out.append(plainSized(s, font: Self.subFont, color: .secondaryLabelColor))
            if let extra { out.append(extra) }
            out.append(nl(Self.subFont))
        }

        if fiveHour != nil || sevenDay != nil {
            sectionSpacer()
            out.append(sectionHeader("Claude", key: "claude"))
            out.append(nl(Self.headerFont))
            subtitleLine(["updated " + Self.timeFmt.string(from: Date()), "OAuth"])
            out.append(nl(Self.subFont))

            if let f = fiveHour { appendBucketLine(out, label: "Session", b: f) }
            if let s = sevenDay { appendBucketLine(out, label: "Weekly",  b: s) }
            // Pace narrative sits under Weekly, indented to align with the bar column.
            if let pct = fiveHourPct, let mins = fiveHourResetMin {
                if let line = paceNarrativeLine(currentPct: pct, minutesUntilReset: mins,
                                                activeBlock: active) {
                    out.append(line)
                    out.append(nl(Self.paceFont))
                }
            }
            if let o = oauth["seven_day_opus"]   as? [String: Any] {
                appendBucketLine(out, label: "Opus", b: o)
            }
            if let s = oauth["seven_day_sonnet"] as? [String: Any] {
                appendBucketLine(out, label: "Sonnet", b: s)
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
                out.append(nl(Self.subFont))
                if let f = cx5 { appendBucketLine(out, label: "Session", b: f) }
                if let s = cx7 { appendBucketLine(out, label: "Weekly",  b: s) }
            }
        }

        // Gemini Code Assist — per-model quota buckets.
        if let gemini = payload["gemini"] as? [String: Any],
           let models = gemini["models"] as? [[String: Any]], !models.isEmpty {
            sectionSpacer()
            out.append(sectionHeader("Gemini", key: "gemini"))
            out.append(nl(Self.headerFont))
            subtitleLine(["updated " + Self.timeFmt.string(from: Date()), "Code Assist"])
            out.append(nl(Self.subFont))
            for m in models {
                let name = (m["name"] as? String) ?? "model"
                let bucket: [String: Any] = [
                    "utilization": m["utilization"] ?? 0,
                    "resets_at":   m["resets_at"]   ?? "",
                ]
                appendBucketLine(out, label: name, b: bucket)
            }
        }

        // GitHub Copilot — chat / completions / premium quotas.
        if let copilot = payload["copilot"] as? [String: Any], !copilot.isEmpty {
            let entries: [(String, String)] = [
                ("Chat", "chat"),
                ("Completions", "completions"),
                ("Premium", "premium"),
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
                out.append(nl(Self.subFont))
                for (label, b) in buckets {
                    if (b["unlimited"] as? Bool) == true {
                        let padded = label.padding(toLength: 9, withPad: " ", startingAt: 0)
                        out.append(NSAttributedString(string: padded + "  unlimited\n",
                            attributes: [.font: Self.metricFont,
                                         .foregroundColor: NSColor.secondaryLabelColor]))
                    } else {
                        appendBucketLine(out, label: label, b: b)
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

        // Historical aggregates from ccusage live inside the same submenu
        // so the dropdown root stays a single-row "details ▸" entry.
        appendHistoryBlock(to: detailsOut, label: "daily",  rows: daily)
        appendHistoryBlock(to: detailsOut, label: "weekly", rows: weekly)

        // No trailing footer — each section already carries its own
        // "Updated HH:MM" subtitle.
        setDetail(out)
        populateDetailsSubmenu(detailsOut)

        if let n = payload["notif"] as? [String: Any] {
            notifEnabled = (n["enabled"] as? Bool) ?? false
            notifDelay   = (n["delay"]   as? Int)  ?? 60
        }
        rebuildNotifSubmenu()
        rebuildAlertItems()
        refreshAutostartState()
        rebuildAutostartItem()
        rebuildCompactItems()

        if let pct = fiveHourPct, let resetIso = fiveHourReset {
            checkAndFireAlert(util: pct, windowResetsAt: resetIso)
        }
    }

    /// Rebuilds the usage-alert parent row + its hover submenu (off + each
    /// threshold). Multi-select: any subset of thresholds may be enabled,
    /// the `off` row clears them all. Triangle stays orange while at least
    /// one threshold is on.
    func rebuildAlertItems() {
        let toggleLabel: String
        if alertEnabled && !alertThresholds.isEmpty {
            let tiers = alertThresholds.sorted().map { "\($0)" }.joined(separator: "/")
            toggleLabel = "Usage alert  ·  on  ·  \(tiers)%"
        } else {
            toggleLabel = "Usage alert  ·  off"
        }
        alertToggleItem.attributedTitle = menuToggleLabel(toggleLabel, active: alertEnabled)
        alertToggleItem.image = tintedSymbol(
            name: alertEnabled ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
            color: alertEnabled ? NSColor.systemOrange : NSColor.tertiaryLabelColor
        )

        let sub = NSMenu()
        let offItem = NSMenuItem(
            title: "",
            action: #selector(pickAlertOff),
            keyEquivalent: ""
        )
        offItem.target = self
        let offMarker = (!alertEnabled || alertThresholds.isEmpty) ? "✓ " : "   "
        offItem.attributedTitle = plain("\(offMarker)off")
        sub.addItem(offItem)
        sub.addItem(.separator())
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
        alertToggleItem.submenu = sub
    }

    @objc func pickAlertOff() {
        alertThresholds.removeAll()
        alertEnabled = false
        firedTiersInWindow = []
        alertedWindowResetsAt = nil
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

    /// Re-reads whether the LaunchAgent plist exists on disk. Cheap enough
    /// to call on every refresh — handles the case where the user installs
    /// or removes the agent externally (e.g. via install.sh / uninstall.sh).
    func refreshAutostartState() {
        autostartEnabled = FileManager.default.fileExists(atPath: LAUNCH_AGENT_PLIST)
    }

    /// Rebuilds the autostart toggle row to match `autostartEnabled`. Matches
    /// the visual style of the notifications + alert toggles above.
    func rebuildAutostartItem() {
        let label = autostartEnabled
            ? "Autostart at login  ·  on"
            : "Autostart at login  ·  off"
        autostartToggleItem.attributedTitle = menuToggleLabel(label, active: autostartEnabled)
        autostartToggleItem.image = tintedSymbol(
            name: autostartEnabled ? "power.circle.fill" : "power.circle",
            color: autostartEnabled ? NSColor.systemGreen : NSColor.tertiaryLabelColor
        )
    }

    /// Toggle target: writes (or removes) the LaunchAgent plist that points
    /// at the currently-running binary, then `launchctl load`s / `unload`s
    /// it so the change takes effect without a reboot. The plist path +
    /// label intentionally match `install.sh` / `uninstall.sh` so the two
    /// entry points don't fight over state.
    @objc func toggleAutostart() {
        if autostartEnabled {
            disableAutostart()
        } else {
            enableAutostart()
        }
        refreshAutostartState()
        rebuildAutostartItem()
    }

    /// Writes the LaunchAgent plist and loads it. Uses the actual path of
    /// the running binary so an installed-anywhere build still autostarts
    /// from the same location after reboot.
    func enableAutostart() {
        let dir = (LAUNCH_AGENT_PLIST as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>           <string>\(LAUNCH_AGENT_LABEL)</string>
          <key>ProgramArguments</key><array><string>\(binary)</string></array>
          <key>RunAtLoad</key>       <true/>
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key><false/>
          </dict>
          <key>StandardOutPath</key> <string>/tmp/\(LAUNCH_AGENT_LABEL).log</string>
          <key>StandardErrorPath</key><string>/tmp/\(LAUNCH_AGENT_LABEL).log</string>
        </dict>
        </plist>
        """
        try? plist.write(toFile: LAUNCH_AGENT_PLIST, atomically: true, encoding: .utf8)
        runLaunchctl(args: ["unload", LAUNCH_AGENT_PLIST])
        runLaunchctl(args: ["load",   LAUNCH_AGENT_PLIST])
    }

    /// Unloads the agent and removes the plist. Doesn't kill the current
    /// process — the user is using the widget right now; disabling autostart
    /// just means it won't come back on next login.
    func disableAutostart() {
        runLaunchctl(args: ["unload", LAUNCH_AGENT_PLIST])
        try? FileManager.default.removeItem(atPath: LAUNCH_AGENT_PLIST)
    }

    /// Versions ≤ 0.5.5 wrote the LaunchAgent plist with a bare
    /// `KeepAlive=true`, which made launchd respawn the widget even
    /// after a user-requested Quit. New format keys keepalive on
    /// non-zero exit only (`KeepAlive={SuccessfulExit=false}`), so
    /// manual Quit stays quit and crashes still auto-recover.
    ///
    /// Called once at startup. If the on-disk plist still has the old
    /// shape, rewrite it via `enableAutostart()` (idempotent, also
    /// unload+reload so the new rule takes effect without a reboot).
    func migrateLaunchAgentIfStale() {
        guard FileManager.default.fileExists(atPath: LAUNCH_AGENT_PLIST),
              let data = FileManager.default.contents(atPath: LAUNCH_AGENT_PLIST),
              let body = String(data: data, encoding: .utf8) else { return }
        let needsMigration = body.contains("<key>KeepAlive</key>")
                          && !body.contains("SuccessfulExit")
        guard needsMigration else { return }
        enableAutostart()
    }

    /// Synchronously runs `launchctl <args>` and discards its output.
    /// `launchctl unload` on a missing plist prints an error to stderr but
    /// exits 0 cleanly — fine to call unconditionally before a load.
    func runLaunchctl(args: [String]) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        task.standardOutput = devNull
        task.standardError = devNull
        try? task.run()
        task.waitUntilExit()
    }

    // ── compact-mode display config ────────────────────────────────────

    /// Loads the persisted compact-mode toggle and selected providers from
    /// `~/.cache/claude-usage-bar/display.json`. Missing fields fall back
    /// to defaults (off, Claude-only). Bad config doesn't crash — we just
    /// keep defaults.
    func loadDisplayConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: DISPLAY_CONFIG_PATH)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let v = obj["compactMode"] as? Bool { compactMode = v }
        if let arr = obj["compactProviders"] as? [String] {
            let allowed = Set(COMPACT_PROVIDER_ORDER)
            let filtered = Set(arr).intersection(allowed)
            // Guard against an empty selection — would render an empty
            // title and be invisible. Fall back to Claude.
            compactProviders = filtered.isEmpty ? ["claude"] : filtered
        }
    }

    /// Persists current compact-mode state. Atomic write so a crash
    /// mid-save doesn't leave a half-written JSON file.
    func saveDisplayConfig() {
        let dir = (DISPLAY_CONFIG_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        let obj: [String: Any] = [
            "compactMode":      compactMode,
            "compactProviders": Array(compactProviders).sorted(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: DISPLAY_CONFIG_PATH), options: .atomic)
    }

    /// Refreshes the compact-mode parent row + its hover submenu (off +
    /// per-provider checkboxes). Visually parallels the notifications /
    /// usage-alert rows: pick a provider to enable compact mode at that
    /// provider set, pick `off` to disable while keeping the selection.
    func rebuildCompactItems() {
        let selected = COMPACT_PROVIDER_ORDER
            .filter { compactProviders.contains($0) }
            .joined(separator: " / ")
        let toggleLabel = compactMode
            ? "Compact mode  ·  on  ·  \(selected.isEmpty ? "—" : selected)"
            : "Compact mode  ·  off"
        compactToggleItem.attributedTitle = menuToggleLabel(toggleLabel, active: compactMode)
        compactToggleItem.image = tintedSymbol(
            name: compactMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
            color: compactMode ? NSColor.systemTeal : NSColor.tertiaryLabelColor
        )

        let sub = NSMenu()
        let offItem = NSMenuItem(
            title: "",
            action: #selector(pickCompactOff),
            keyEquivalent: ""
        )
        offItem.target = self
        offItem.attributedTitle = plain("\(compactMode ? "   " : "✓ ")off")
        sub.addItem(offItem)
        sub.addItem(.separator())
        for key in COMPACT_PROVIDER_ORDER {
            let mi = NSMenuItem(
                title: "",
                action: #selector(toggleCompactProvider(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.representedObject = key
            let marker = compactProviders.contains(key) ? "✓ " : "   "
            mi.attributedTitle = plain("\(marker)\(key)")
            sub.addItem(mi)
        }
        compactToggleItem.submenu = sub
    }

    @objc func pickCompactOff() {
        compactMode = false
        saveDisplayConfig()
        rebuildCompactItems()
        refresh()
    }

    @objc func toggleCompactProvider(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if compactProviders.contains(key) {
            // Don't allow the user to deselect the last provider — empty
            // title would render as a 0-width status item and disappear.
            if compactProviders.count > 1 { compactProviders.remove(key) }
        } else {
            compactProviders.insert(key)
        }
        // Picking a provider auto-enables compact mode (mirrors alert's
        // "any threshold ⇒ on" pattern); `off` is the way to disable.
        compactMode = true
        saveDisplayConfig()
        rebuildCompactItems()
        refresh()
    }

    /// Builds the compact-title string: per provider, a tinted SF symbol
    /// followed by ` NN%` using the same regular-12pt font as the percent
    /// label in the default title. Providers are space-padded apart so the
    /// row reads as discrete pairs.
    func makeCompactTitle(payload: [String: Any]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        var first = true
        for key in COMPACT_PROVIDER_ORDER where compactProviders.contains(key) {
            guard let pct = compactPct(key: key, payload: payload) else { continue }
            if !first {
                m.append(NSAttributedString(string: "  ",
                    attributes: [.font: Self.monoFont]))
            }
            first = false
            if let img = tintedSymbol(name: providerSymbol(key), color: PROVIDER_COLORS[key]) {
                let att = NSTextAttachment()
                att.image = img
                att.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                m.append(NSAttributedString(attachment: att))
            }
            m.append(NSAttributedString(
                string: String(format: " %3.0f%%", pct),
                attributes: [.font: Self.monoFont, .foregroundColor: barColor(pct)]
            ))
        }
        // Nothing to show? Render a placeholder so the status item still
        // has a clickable surface.
        if m.length == 0 {
            m.append(NSAttributedString(string: "—",
                attributes: [.font: Self.monoFont, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return m
    }

    /// Returns the headline percentage we display for a provider in compact
    /// mode. For Claude/Codex that's the 5-hour bucket; for Gemini and
    /// Copilot the highest utilization across their sub-buckets, since
    /// those providers expose multiple parallel quotas.
    func compactPct(key: String, payload: [String: Any]) -> Double? {
        switch key {
        case "claude":
            return ((payload["oauth"] as? [String: Any])?["five_hour"] as? [String: Any])?["utilization"] as? Double
        case "codex":
            return ((payload["codex"] as? [String: Any])?["five_hour"] as? [String: Any])?["utilization"] as? Double
        case "gemini":
            let models = (payload["gemini"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            let vals = models.compactMap { $0["utilization"] as? Double }
            return vals.max()
        case "copilot":
            let cp = payload["copilot"] as? [String: Any] ?? [:]
            let buckets = ["chat", "completions", "premium"]
                .compactMap { cp[$0] as? [String: Any] }
                .filter { ($0["unlimited"] as? Bool) != true }
            let vals = buckets.compactMap { $0["utilization"] as? Double }
            return vals.max()
        default:
            return nil
        }
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

    /// Daily background poll. First fire is delayed slightly so launch isn't
    /// slowed and so simultaneous login-time launches across machines don't
    /// stampede the API. Then repeats every `UPDATE_CHECK_INTERVAL`.
    func scheduleUpdateCheck() {
        updateCheckTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + UPDATE_CHECK_INITIAL_DELAY) { [weak self] in
            self?.checkForUpdatesSilently()
        }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: UPDATE_CHECK_INTERVAL, repeats: true) { [weak self] _ in
            self?.checkForUpdatesSilently()
        }
    }

    /// Background-friendly counterpart to `checkForUpdates`. Hits the same
    /// release API but never opens a modal — on a newer release it posts a
    /// macOS notification (via the same osascript path as usage alerts) and
    /// records the tag at `UPDATE_CHECK_STATE_PATH` so we don't re-nag the
    /// user about the same version. The user can still install via "Check
    /// for updates…" in the dropdown (which fires the interactive flow).
    func checkForUpdatesSilently() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let info = self.fetchLatestRelease() else { return }
            let remote = info.tag.hasPrefix("v") ? String(info.tag.dropFirst()) : info.tag
            guard self.compareVersions(remote, WIDGET_VERSION) > 0 else { return }
            guard self.lastNotifiedUpdateTag() != info.tag else { return }
            DispatchQueue.main.async {
                self.sendNotification(
                    title: "claude-usage-bar update available",
                    body: "\(info.tag) is out — you're on \(WIDGET_VERSION). Click 'Check for updates…' in the dropdown to install."
                )
                self.recordNotifiedUpdateTag(info.tag)
            }
        }
    }

    /// Reads the last tag we already notified about, so a newer release
    /// doesn't fire daily until the user updates (or uninstalls + reinstalls).
    func lastNotifiedUpdateTag() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: UPDATE_CHECK_STATE_PATH)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["lastNotifiedTag"] as? String
    }

    /// Persists the tag we just notified the user about. Also stores a
    /// timestamp purely for debugging — the tag is what gates re-firing.
    func recordNotifiedUpdateTag(_ tag: String) {
        let dir = (UPDATE_CHECK_STATE_PATH as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        let obj: [String: Any] = [
            "lastNotifiedTag": tag,
            "lastCheckedAt":   ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: UPDATE_CHECK_STATE_PATH), options: .atomic)
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

    /// Rebuilds the notifications parent row + its hover submenu (off + each
    /// delay). Single-pick: selecting a delay turns notifications on at that
    /// delay; selecting `off` disables them. Settings.json edits made
    /// externally show up after the next poll since this is called on every
    /// refresh.
    func rebuildNotifSubmenu() {
        let toggleLabel = notifEnabled
            ? "Notifications  ·  on  ·  \(notifDelay)s"
            : "Notifications  ·  off"
        notifToggleItem.attributedTitle = menuToggleLabel(toggleLabel, active: notifEnabled)
        notifToggleItem.image = tintedSymbol(
            name: notifEnabled ? "bell.fill" : "bell.slash",
            color: notifEnabled ? NSColor.systemBlue : NSColor.tertiaryLabelColor
        )

        let sub = NSMenu()
        let offItem = NSMenuItem(
            title: "",
            action: #selector(pickNotifOff),
            keyEquivalent: ""
        )
        offItem.target = self
        offItem.attributedTitle = plain("\(notifEnabled ? "   " : "✓ ")off")
        sub.addItem(offItem)
        sub.addItem(.separator())
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
        notifToggleItem.submenu = sub
    }

    @objc func pickNotifOff() {
        runNotifControl(args: ["set", "off"])
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

    /// Appends a daily-or-weekly table into the details submenu, matching
    /// the period / cost / tokens / models columns the standalone history
    /// submenus used. Header row is rendered only if `rows` has any data;
    /// otherwise the whole block is silently skipped.
    func appendHistoryBlock(to out: NSMutableAttributedString, label: String, rows: [[String: Any]]) {
        guard !rows.isEmpty else { return }
        out.append(plain("\n◆ \(label) · last \(rows.count)\n"))
        out.append(plain("   period        cost    tokens   models\n"))
        for r in rows {
            let p = (r["period"] as? String) ?? "?"
            let c = (r["totalCost"] as? Double) ?? 0
            let t = sumTokens(r)
            let m = shortModels((r["modelsUsed"] as? [String]) ?? [])
            out.append(plain(String(format: "   %@   $%6.2f  %@   %@\n", p, c, fmtTokens(t), m)))
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
    /// Bold provider-name header — keep big enough to anchor the section.
    static let headerFont  = NSFont.systemFont(ofSize: 14, weight: .bold)
    /// Bold mono label for each bucket row ("Session" / "Weekly" / etc.).
    /// Bolder than the data text but still monospaced so columns align
    /// across rows — that's the "old layout" identity we want back.
    static let metricFont  = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    /// Compact monospace for the inline figures next to the bar.
    static let monoSub     = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// Section subtitle ("updated HH:MM · OAuth").
    static let subFont     = NSFont.systemFont(ofSize: 11, weight: .regular)
    /// Pace narrative line — mono so it visually aligns with the bucket rows.
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
    /// embedding an NSImage attachment doesn't render reliably). Uses
    /// Unicode left-block partial fills (`▏▎▍▌▋▊▉█`) so anything > 0%
    /// renders some colour — a plain `█`/`░` bar at `width=8` only lights
    /// the first cell at ≥6.25 %, which made small percentages look like
    /// "no fill" in the tray.
    func makeBar(pct: Double, width: Int) -> NSAttributedString {
        let clamped = max(0.0, min(100.0, pct))
        // 8 sub-cells per visual cell → 8 partial-fill levels.
        let totalEighths = Int((clamped / 100.0 * Double(width) * 8.0).rounded())
        let fullCells = totalEighths / 8
        let partialIdx = totalEighths % 8
        let partials: [Character] = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

        let m = NSMutableAttributedString()
        let fillAttrs: [NSAttributedString.Key: Any] =
            [.font: Self.barFont, .foregroundColor: barColor(pct)]
        let emptyAttrs: [NSAttributedString.Key: Any] =
            [.font: Self.barFont, .foregroundColor: NSColor.tertiaryLabelColor]

        if fullCells > 0 {
            m.append(NSAttributedString(string: String(repeating: "█", count: fullCells),
                                         attributes: fillAttrs))
        }
        var emptyCount = width - fullCells
        if partialIdx > 0 && fullCells < width {
            m.append(NSAttributedString(string: String(partials[partialIdx]),
                                         attributes: fillAttrs))
            emptyCount -= 1
        }
        if emptyCount > 0 {
            m.append(NSAttributedString(string: String(repeating: "░", count: emptyCount),
                                         attributes: emptyAttrs))
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

    /// Disabled small-caps section header for a group of related menu
    /// items (e.g. "ALERTS & NOTIFICATIONS"). Visually distinct from
    /// regular rows so groups don't blend into one big list.
    func menuSectionLabel(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.isEnabled = false
        mi.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.0,
            ]
        )
        return mi
    }

    /// Bold system-font label for prominent toggle rows (notifications /
    /// alert). Reads heavier than the mono-spaced data rows above.
    func menuToggleLabel(_ text: String, active: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
    }

    /// Mono detail label used for sub-rows like "delay (30s)" and
    /// "thresholds (90%)" — sits beneath the toggle and inherits the
    /// detail-row look.
    func menuDetailLabel(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
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

    /// "Xh YYm" for short windows, "Xd YYh" once the remaining time
    /// crosses a day. Lead value padded to 2 chars so the column reads
    /// as a flush right-edge across rows ("0h 47m" / " 6d 19h").
    func formatResetLong(_ minutes: Int) -> String {
        if minutes >= 60 * 24 {
            let d = minutes / (60 * 24)
            let h = (minutes % (60 * 24)) / 60
            return String(format: "%2dd %02dh", d, h)
        }
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%2dh %02dm", h, m)
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

/// Compact one-line bucket row, inspired by the original widget layout:
    ///   `Session   [████░░] 78.0% · 1h 17m`
    /// Bold-mono label padded to a fixed width keeps columns aligned
    /// across rows; bar inline; %-colored by threshold; reset suffix
    /// muted. The bold name + colored % give the row visual weight
    /// without expanding to three lines per metric.
    func appendBucketLine(_ out: NSMutableAttributedString, label: String, b: [String: Any],
                          showReset: Bool = true) {
        let pct = b["utilization"] as? Double ?? 0
        let resetIso = b["resets_at"] as? String ?? ""

        // Pad to 9 chars so labels of varying length still line up the
        // bar column. Longer model names get truncated.
        let trimmed = label.count > 9
            ? String(label.prefix(9))
            : label.padding(toLength: 9, withPad: " ", startingAt: 0)
        out.append(NSAttributedString(
            string: trimmed + "  ",
            attributes: [.font: Self.metricFont, .foregroundColor: NSColor.labelColor]
        ))
        // `█░` block-character bar — heavier visual identity than the
        // drawn pill, matches the original widget look.
        out.append(makeBar(pct: pct, width: 12))
        out.append(NSAttributedString(
            // %5.1f gives a fixed 5-char number column (" 9.0", "81.0", "100.0")
            // so the `·` and reset time below align across rows.
            string: String(format: "  %5.1f%%", pct),
            attributes: [.font: Self.monoSub, .foregroundColor: barColor(pct)]
        ))
        if showReset, let m = minutesUntil(iso: resetIso), m > 0 {
            out.append(NSAttributedString(
                string: "  ·  " + formatResetLong(m),
                attributes: [.font: Self.monoSub, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        out.append(plainSized("\n", font: Self.monoSub))
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
        // Indent to roughly align under the bar column of the bucket rows above.
        m.append(plainSized("pace      ", font: Self.paceFont, color: .secondaryLabelColor))
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
    // Reuse SCRIPT_PATH so the bundle/bare-binary resolution stays in one place.
    let scriptPath = SCRIPT_PATH
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

// Single-instance guard. Without it you can easily end up with two
// menu-bar icons (LaunchAgent + manual launch, or a self-update that
// fails to terminate the previous process). Acquired BSD-style via
// `flock(LOCK_EX | LOCK_NB)` — the kernel releases the lock when the
// holding process dies, so a stale file never wedges future launches.
let LOCK_PATH = "\(NSHomeDirectory())/.cache/claude-usage-bar/widget.lock"
var singletonFD: Int32 = -1   // kept alive for the lifetime of the process

func acquireSingletonLock() -> Bool {
    let dir = (LOCK_PATH as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true, attributes: nil
    )
    let fd = open(LOCK_PATH, O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    // Stash our pid for humans peeking at the lock file.
    ftruncate(fd, 0)
    let pid = "\(getpid())\n"
    _ = pid.withCString { write(fd, $0, strlen($0)) }
    singletonFD = fd
    return true
}

if !acquireSingletonLock() {
    fputs("claude-usage-bar: another instance is already running (lock at \(LOCK_PATH)). Exiting.\n", stderr)
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
