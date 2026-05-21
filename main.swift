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
// (429s within a few requests/minute). Background poll is generous
// (15 min) so we never re-trigger throttling; on-demand refresh
// happens when the user opens the dropdown — gated by ON_OPEN_COOLDOWN
// so repeated clicks don't spam the endpoint either.
let REFRESH_SECONDS: TimeInterval = 900
let ON_OPEN_COOLDOWN: TimeInterval = 30

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

// Delay options offered in the notifications submenu (seconds).
let NOTIF_DELAY_OPTIONS: [Int] = [30, 60, 120, 300]
// Threshold options offered in the usage-alert submenu (percent).
let ALERT_THRESHOLD_OPTIONS: [Int] = [70, 80, 90, 95]
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

    let alertToggleItem     = NSMenuItem(title: "alert",     action: nil, keyEquivalent: "")
    let alertThresholdItem  = NSMenuItem(title: "threshold", action: nil, keyEquivalent: "")
    var alertEnabled = false
    var alertThreshold = 90
    var alertedWindowResetsAt: String? = nil

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "claude …"

        let menu = NSMenu()
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
        menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        loadAlertConfig()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: REFRESH_SECONDS, repeats: true) { [weak self] _ in
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

        if fiveHour != nil || sevenDay != nil {
            out.append(plain("◆ plan usage\n"))
            if let f = fiveHour { appendBucketLine(out, label: "current session       ", b: f) }
            if let s = sevenDay { appendBucketLine(out, label: "current week          ", b: s) }
            if let o = oauth["seven_day_opus"]   as? [String: Any] { appendBucketLine(out, label: "current week opus     ", b: o) }
            if let s = oauth["seven_day_sonnet"] as? [String: Any] { appendBucketLine(out, label: "current week sonnet   ", b: s) }
            out.append(plain("\n"))
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

    /// Rebuilds the alert toggle + threshold submenu to match current state.
    func rebuildAlertItems() {
        let toggleLabel = alertEnabled
            ? "✓ alert  at \(alertThreshold)%"
            : "  alert  off"
        alertToggleItem.attributedTitle = plain(toggleLabel)

        alertThresholdItem.attributedTitle = plain("    threshold  (\(alertThreshold)%)")
        let sub = NSMenu()
        for n in ALERT_THRESHOLD_OPTIONS {
            let mi = NSMenuItem(
                title: "",
                action: #selector(pickAlertThreshold(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.tag = n
            let marker = (alertEnabled && n == alertThreshold) ? "✓ " : "   "
            mi.attributedTitle = plain("\(marker)\(n)%")
            sub.addItem(mi)
        }
        alertThresholdItem.submenu = sub
    }

    @objc func toggleAlert() {
        alertEnabled.toggle()
        // When re-enabling, treat the current window as un-alerted so the
        // user gets a fresh chance to be notified.
        if alertEnabled { alertedWindowResetsAt = nil }
        saveAlertConfig()
        rebuildAlertItems()
    }

    @objc func pickAlertThreshold(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        alertThreshold = sender.tag
        // Picking a new threshold enables the feature and resets the
        // already-fired marker so the new threshold takes effect immediately.
        alertEnabled = true
        alertedWindowResetsAt = nil
        saveAlertConfig()
        rebuildAlertItems()
        // Trigger immediate refresh — current utilization may already be
        // over the new threshold and we want the popup right away.
        refresh()
    }

    /// Fires a macOS notification when the 5h utilization first crosses the
    /// configured threshold. Suppresses repeats by remembering which window
    /// (keyed by its resets_at timestamp) we've already alerted for.
    func checkAndFireAlert(util: Double, windowResetsAt: String) {
        guard alertEnabled else { return }
        if util < Double(alertThreshold) { return }
        if alertedWindowResetsAt == windowResetsAt { return }

        let body = String(format: "Current 5-hour session is at %.0f%% (≥ %d%%)",
                          util, alertThreshold)
        sendNotification(title: "Claude usage", body: body)

        alertedWindowResetsAt = windowResetsAt
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

    func loadAlertConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ALERT_CONFIG_PATH)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        alertEnabled         = (obj["enabled"]   as? Bool)   ?? false
        alertThreshold       = (obj["threshold"] as? Int)    ?? 90
        alertedWindowResetsAt = obj["alertedWindowResetsAt"] as? String
    }

    func saveAlertConfig() {
        let obj: [String: Any] = [
            "enabled":               alertEnabled,
            "threshold":             alertThreshold,
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

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
