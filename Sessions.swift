import Cocoa

// ── Sessions: model ────────────────────────────────────────────────────────
//
// The SESSIONS section lists every running Claude Code session on this Mac.
// sessions.sh assembles the data (claude agents --json + transcripts + the
// hooks' "waiting" markers + optional per-session metadata) and the widget
// polls it every SESSIONS_POLL_SECONDS. Everything below the model is pure
// so `--self-test` can check it without a menu bar.

let SESSIONS_POLL_SECONDS: TimeInterval = 10
/// Rows shown in the root menu; the rest go under "More ▸".
let SESSIONS_VISIBLE_ROWS = 8
let DAILY_TARGET_OPTIONS: [Int] = [6, 7, 8, 9, 10]        // hours
let DEFAULT_DAILY_TARGET_HOURS = 8
/// "Session finished" notification: fires when a session that was busy for
/// at least this many minutes goes idle. 0 = off.
let FINISH_NOTIFY_OPTIONS: [Int] = [5, 10, 15, 30]        // minutes
let DEFAULT_FINISH_NOTIFY_MINUTES = 10

/// sessions.sh next to usage.sh (bundle Resources or the binary's folder);
/// when it is missing, which is the case after a self-update from 0.5.x that
/// replaced only the binary, the embedded copy is written to the cache dir.
var SESSIONS_SCRIPT_PATH: String = (SCRIPT_PATH as NSString).deletingLastPathComponent + "/sessions.sh"
let SUPPORT_DIR = "\(NSHomeDirectory())/.cache/claude-usage-bar"
let HOOKS_DIR = "\(NSHomeDirectory())/.claude/scripts"

/// Makes the scripts v0.6 depends on present and current:
///  - sessions.sh: bundled copy if there is one, else the embedded copy in the cache dir;
///  - the notification hooks in ~/.claude/scripts: replaced with the embedded
///    version only when the file there is ours (carries our marker line) and
///    differs; the previous file is kept as <name>.bak. Files that are not
///    ours, or absent (hooks never installed), are left alone.
/// Returns what it changed, for the log.
@discardableResult
func ensureSupportScripts(fm: FileManager = .default, supportDir: String = SUPPORT_DIR,
                          hooksDir: String = HOOKS_DIR) -> [String] {
    var changed: [String] = []
    func write(_ text: String, _ path: String, executable: Bool) -> Bool {
        let body = text.hasSuffix("\n") ? text : text + "\n"
        if let cur = fm.contents(atPath: path), String(data: cur, encoding: .utf8) == body { return false }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true, attributes: nil)
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
        if executable { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        return true
    }
    if !fm.fileExists(atPath: SESSIONS_SCRIPT_PATH) || SESSIONS_SCRIPT_PATH.hasPrefix(supportDir) {
        let path = supportDir + "/sessions.sh"
        if write(EMBEDDED_SESSIONS_SH, path, executable: true) { changed.append(path) }
        SESSIONS_SCRIPT_PATH = path
    }
    if !fm.fileExists(atPath: JIRA_SCRIPT_PATH) || JIRA_SCRIPT_PATH.hasPrefix(supportDir) {
        let path = supportDir + "/jira.py"
        if write(EMBEDDED_JIRA_PY, path, executable: true) { changed.append(path) }
        JIRA_SCRIPT_PATH = path
    }
    let hooks: [(String, String, String)] = [
        ("claude-notify.sh", EMBEDDED_CLAUDE_NOTIFY_SH, "claude-usage-bar widget writes the delay"),
        ("claude-notify-cancel.sh", EMBEDDED_CLAUDE_NOTIFY_CANCEL_SH, "scheduled by claude-notify.sh"),
    ]
    for (name, text, marker) in hooks {
        let path = hooksDir + "/" + name
        guard let data = fm.contents(atPath: path), let cur = String(data: data, encoding: .utf8),
              cur.contains(marker), cur != (text.hasSuffix("\n") ? text : text + "\n") else { continue }
        try? fm.removeItem(atPath: path + ".bak")
        try? fm.copyItem(atPath: path, toPath: path + ".bak")
        if write(text, path, executable: true) { changed.append(path) }
    }
    return changed
}

enum SessionState: String { case waiting, busy, idle }

struct AgentSession: Equatable {
    var id: String
    var name: String
    var pid: Int?
    var kind: String
    var cwd: String
    var project: String
    var state: SessionState
    var waitingSince: Double?
    var lastActivity: Double?
    var title: String?
    var task: String?
    var taskStatus: String?
    var taskDone: Bool
    var taskUrl: String?
    var ctx: Double?

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = (d["name"] as? String) ?? String(id.prefix(8))
        pid = d["pid"] as? Int
        kind = (d["kind"] as? String) ?? "interactive"
        cwd = (d["cwd"] as? String) ?? ""
        project = (d["project"] as? String) ?? ""
        state = SessionState(rawValue: (d["state"] as? String) ?? "") ?? .idle
        waitingSince = d["waitingSince"] as? Double
        lastActivity = d["lastActivity"] as? Double
        title = (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        task = (d["task"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        taskStatus = d["taskStatus"] as? String
        taskDone = (d["taskDone"] as? Bool) ?? false
        taskUrl = d["taskUrl"] as? String
        ctx = d["ctx"] as? Double
    }
}

struct TodayInfo: Equatable {
    var date: String
    var loggedSeconds: Int
    var tasks: Int?
    var targetSeconds: Int?

    init?(_ d: [String: Any]?) {
        guard let d, let date = d["date"] as? String,
              let logged = d["loggedSeconds"] as? Int else { return nil }
        self.date = date
        loggedSeconds = logged
        tasks = d["tasks"] as? Int
        targetSeconds = d["targetSeconds"] as? Int
    }
}

struct SessionsSnapshot {
    var sessions: [AgentSession]
    var today: TodayInfo?

    static func parse(_ obj: [String: Any]?) -> SessionsSnapshot? {
        guard let obj, let arr = obj["sessions"] as? [[String: Any]] else { return nil }
        return SessionsSnapshot(sessions: arr.compactMap(AgentSession.init),
                                today: TodayInfo(obj["today"] as? [String: Any]))
    }
}

// ── Sessions: pure logic (covered by --self-test) ─────────────────────────

/// Waiting first (longest wait on top), then busy, then idle by most recent
/// activity. Ties fall back to the name so the order is stable between polls.
func sortSessions(_ list: [AgentSession]) -> [AgentSession] {
    func rank(_ s: AgentSession) -> Int { s.state == .waiting ? 0 : s.state == .busy ? 1 : 2 }
    return list.sorted { a, b in
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if a.state == .waiting, let x = a.waitingSince, let y = b.waitingSince, x != y { return x < y }
        let la = a.lastActivity ?? 0, lb = b.lastActivity ?? 0
        if la != lb { return la > lb }
        return a.name < b.name
    }
}

func sessionsSummary(_ list: [AgentSession]) -> String {
    let busy = list.filter { $0.state == .busy }.count
    let waiting = list.filter { $0.state == .waiting }.count
    var parts = ["\(list.count) open"]
    if busy > 0 { parts.append("\(busy) busy") }
    if waiting > 0 { parts.append("\(waiting) waiting") }
    return parts.joined(separator: " · ")
}

/// "45s", "12m", "3h", "2d": compact age for the session rows.
func fmtAge(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

/// "6h 15m" / "45m" for logged time.
func fmtHM(_ seconds: Int) -> String {
    let m = max(0, seconds) / 60
    return m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m)m"
}

/// Compact logged time for the Today row: "6h", "6h 15m", "45m".
func fmtHMShort(_ seconds: Int) -> String {
    let m = max(0, seconds) / 60
    if m < 60 { return "\(m)m" }
    return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
}

/// State column of a session row: "waiting 3m", "busy", "idle 2h".
func stateLabel(_ s: AgentSession, now: Double) -> String {
    switch s.state {
    case .waiting: return "waiting " + fmtAge(now - (s.waitingSince ?? now))
    case .busy:    return "busy"
    case .idle:    return s.lastActivity.map { "idle " + fmtAge(now - $0) } ?? "idle"
    }
}

/// Today's Jira block is shown only when the record is for the local date:
/// a producer that stopped updating must not show yesterday's hours as today's.
func todayIfCurrent(_ t: TodayInfo?, localDate: String) -> TodayInfo? {
    guard let t, t.date == localDate else { return nil }
    return t
}

/// Remembers since when each session has been busy and reports the ones that
/// just finished: busy → idle after at least `minBusy` seconds. A session that
/// goes busy → waiting is not finished (it asks you something), and a session
/// that disappears is not reported (it was closed, not finished).
struct BusyTracker {
    var busySince: [String: Double] = [:]

    mutating func update(_ list: [AgentSession], now: Double, minBusy: Double) -> [(AgentSession, Double)] {
        var finished: [(AgentSession, Double)] = []
        var next: [String: Double] = [:]
        for s in list {
            switch s.state {
            case .busy:
                next[s.id] = busySince[s.id] ?? now
            case .waiting:
                // Keep the clock running: answering a prompt is part of the same job.
                if let since = busySince[s.id] { next[s.id] = since }
            case .idle:
                if let since = busySince[s.id], now - since >= minBusy {
                    finished.append((s, now - since))
                }
            }
        }
        busySince = next
        return finished
    }
}

func localDateString(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

/// The .app that owns a session's terminal: walks the parent chain from the
/// session's pid up to the first process that is a regular GUI application
/// (VS Code, iTerm, Terminal, Ghostty…). nil if none is found.
func owningApplication(pid: Int) -> NSRunningApplication? {
    var current = pid_t(pid)
    for _ in 0..<12 {
        if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
            return app
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        if parent <= 1 { return nil }
        current = parent
    }
    return nil
}

// ── Sessions: menu UI ─────────────────────────────────────────────────────

extension App {

    @objc func refreshSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let obj = runJSONScript(SESSIONS_SCRIPT_PATH)
            DispatchQueue.main.async { self?.applySessions(SessionsSnapshot.parse(obj)) }
        }
    }

    func scheduleSessionsTimer() {
        sessionsTimer?.invalidate()
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: SESSIONS_POLL_SECONDS, repeats: true) { [weak self] _ in
            self?.refreshSessions()
        }
    }

    /// `snap` is a fresh poll; nil re-applies the last one (after a Jira
    /// refresh or a settings change). A failed poll also arrives as nil and
    /// keeps the last good list.
    func applySessions(_ snap: SessionsSnapshot?) {
        let now = Date().timeIntervalSince1970
        if let snap {
            rawSessions = snap.sessions
            metaToday = snap.today
        }
        sessions = sortSessions(applyJira(rawSessions, statuses: jiraResult?.statuses ?? [:],
                                          showTasks: jiraConfig.showTasks))
        today = chooseToday(jira: jiraResult?.today, meta: metaToday,
                            showTasks: jiraConfig.showTasks, localDate: localDateString())

        if snap != nil {
            let minBusy = finishNotifyMinutes > 0 ? Double(finishNotifyMinutes * 60) : .infinity
            for (s, busyFor) in busyTracker.update(sessions, now: now, minBusy: minBusy) {
                let head = [s.name, s.task].compactMap { $0 }.joined(separator: " · ")
                let body = "Busy for \(fmtAge(busyFor))" + (s.title.map { " · \($0)" } ?? "")
                sendNotification(title: "\(head) finished", body: body)
            }
            // New task keys: fetch their status now instead of at the next 5-minute tick.
            let keys = Set(rawSessions.compactMap { $0.task })
            if keys != lastJiraKeys {
                lastJiraKeys = keys
                refreshJira()
            }
        }

        rebuildSessionItems()
        rebuildTodayItem()
        applyTrayTitle()
    }

    /// Rebuilds the SESSIONS block in place, between the header row and the
    /// separator after it. Only sessions that need you are listed in the root
    /// (waiting, then busy); idle ones collapse into one "N idle ›" row.
    func rebuildSessionItems() {
        guard let menu, let header = sessionsHeaderItem else { return }
        for item in sessionRowItems { menu.removeItem(item) }
        sessionRowItems = []

        header.isHidden = sessions.isEmpty
        header.attributedTitle = sectionLabelWithSummary("SESSIONS", sessionsSummary(sessions))
        guard !sessions.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        var index = menu.index(of: header) + 1
        func insert(_ item: NSMenuItem) {
            menu.insertItem(item, at: index)
            sessionRowItems.append(item)
            index += 1
        }
        let active = sessions.filter { $0.state != .idle }
        for s in active.prefix(SESSIONS_VISIBLE_ROWS) { insert(sessionRowItem(s, now: now)) }

        let idle = sessions.filter { $0.state == .idle } + active.dropFirst(SESSIONS_VISIBLE_ROWS)
        if !idle.isEmpty {
            let group = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            group.image = sessionStateSymbol(.idle)
            group.attributedTitle = plainSized(active.isEmpty ? "\(idle.count) idle sessions" : "\(idle.count) idle",
                                               font: Self.rowFont, color: .secondaryLabelColor)
            let sub = NSMenu()
            sub.autoenablesItems = false
            for s in idle { sub.addItem(sessionRowItem(s, now: now, withTitle: true)) }
            group.submenu = sub
            insert(group)
        }
    }

    /// One session row: name, task, state and (`withTitle`) the session title,
    /// which is also in the row's submenu and tooltip.
    func sessionRowItem(_ s: AgentSession, now: Double, withTitle: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
        item.image = sessionStateSymbol(s.state)

        let row = NSMutableAttributedString()
        let name = s.name.count > 20 ? String(s.name.prefix(19)) + "…" : s.name
        row.append(plainSized(name, font: Self.rowFont))
        if let task = s.task {
            row.append(plainSized("  " + task + (s.taskDone ? " ✓" : ""), font: Self.rowMono,
                                  color: s.taskDone ? .systemRed : .systemBlue))
        }
        let stateColor: NSColor = s.state == .waiting ? .systemOrange : s.state == .busy ? .systemGreen : .secondaryLabelColor
        row.append(plainSized("  " + stateLabel(s, now: now), font: Self.rowSmall, color: stateColor))
        if withTitle, let t = s.title {
            let short = t.count > 34 ? String(t.prefix(33)) + "…" : t
            row.append(plainSized("  " + short, font: Self.rowSmall, color: .secondaryLabelColor))
        }
        item.attributedTitle = row
        item.toolTip = [s.title, s.cwd, s.ctx.map { String(format: "context %.0f%%", $0) }]
            .compactMap { $0 }.joined(separator: "\n")
        item.submenu = sessionActionsMenu(s)
        return item
    }

    func sessionStateSymbol(_ state: SessionState) -> NSImage? {
        switch state {
        case .waiting: return tintedSymbol(name: "hand.raised.fill", color: .systemOrange)
        case .busy:    return tintedSymbol(name: "circle.fill", color: .systemGreen)
        case .idle:    return tintedSymbol(name: "circle", color: .tertiaryLabelColor)
        }
    }

    func sessionActionsMenu(_ s: AgentSession) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        func action(_ title: String, _ symbol: String, _ sel: Selector, _ value: String) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.representedObject = value
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            sub.addItem(mi)
        }
        // Read-only facts first, so the submenu also answers "what is this one doing".
        var facts: [String] = []
        if let t = s.title { facts.append(t) }
        var line2: [String] = [s.project]
        if let st = s.taskStatus, let k = s.task { line2.append("\(k) \(st)") }
        if let c = s.ctx { line2.append(String(format: "context %.0f%%", c)) }
        if s.kind != "interactive" { line2.append(s.kind) }
        facts.append(line2.joined(separator: "  ·  "))
        for f in facts {
            let mi = NSMenuItem(title: f, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            sub.addItem(mi)
        }
        sub.addItem(.separator())

        if let url = s.taskUrl, let key = s.task {
            action("Open \(key)", "arrow.up.right.square", #selector(openSessionTask(_:)), url)
        }
        if s.pid != nil {
            action("Bring its terminal to front", "macwindow", #selector(focusSessionTerminal(_:)), s.id)
        }
        action("Copy resume command", "doc.on.doc", #selector(copySessionText(_:)),
               "cd \(shellQuote(s.cwd)) && claude --resume \(s.id)")
        action("Copy session name", "at", #selector(copySessionText(_:)), s.name)
        action("Reveal transcript in Finder", "folder", #selector(revealSessionTranscript(_:)), s.id)
        return sub
    }

    @objc func openSessionTask(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copySessionText(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func focusSessionTerminal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let pid = sessions.first(where: { $0.id == id })?.pid,
              let app = owningApplication(pid: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    @objc func revealSessionTranscript(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = sessions.first(where: { $0.id == id }) else { return }
        let munged = String(s.cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        let path = "\(NSHomeDirectory())/.claude/projects/\(munged)/\(id).jsonl"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "\(NSHomeDirectory())/.claude/projects"))
        }
    }

    /// Today row: logged time vs the daily target and today's spend in one
    /// short line; tasks, sessions without a task and this week's spend in
    /// its submenu.
    func rebuildTodayItem() {
        guard let todayItem else { return }
        let spend = spendTodayAndWeek()
        guard today != nil || spend != nil else { todayItem.isHidden = true; return }
        todayItem.isHidden = false
        todayItem.image = jiraConfig.isConfigured || today != nil ? jiraMark()
                        : tintedSymbol(name: "calendar", color: .secondaryLabelColor)

        // "Jira" when there is logged time (built-in Jira or today.json);
        // otherwise the row only carries the ccusage spend and says so.
        let row = NSMutableAttributedString(attributedString: plainSized(today != nil ? "Jira  " : "Spend  ", font: Self.rowFont))
        var details: [String] = []
        if let t = today {
            let target = t.targetSeconds ?? dailyTargetHours * 3600
            let pct = target > 0 ? Double(t.loggedSeconds) / Double(target) * 100 : 0
            row.append(summaryBar(pct: pct, color: pct >= 100 ? .systemGreen : .systemBlue))
            row.append(plainSized(" \(fmtHMShort(t.loggedSeconds))", font: Self.rowMono))
            row.append(plainSized(" / \(fmtHMShort(target))", font: Self.rowSmall, color: .secondaryLabelColor))
            if let n = t.tasks { details.append("\(n) task\(n == 1 ? "" : "s") with time logged today") }
            let noTask = sessions.filter { $0.task == nil && $0.kind == "interactive" }.count
            if noTask > 0 {
                details.append("\(noTask) open session\(noTask == 1 ? "" : "s") without a task")
                row.append(summarySep())
                row.append(plainSized("\(noTask) no task", font: Self.rowSmall, color: .systemOrange))
            }
        }
        if let (day, week) = spend {
            if today == nil {
                row.append(plainSized(String(format: "$%.2f today", day), font: Self.rowSmall, color: .secondaryLabelColor))
            }
            details.append(String(format: "$%.2f spent today", day))
            if let w = week { details.append(String(format: "$%.0f spent this week", w)) }
        }
        todayItem.attributedTitle = row
        let sub = NSMenu()
        sub.autoenablesItems = false
        for d in details {
            let mi = NSMenuItem(title: d, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            sub.addItem(mi)
        }
        todayItem.submenu = details.isEmpty ? nil : sub
    }

    /// Thin rounded bar for the summary rows (the block-glyph bar is too wide there).
    func summaryBar(pct: Double, color: NSColor? = nil) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: drawnBar(pct: pct, width: 34, height: 5, color: color))
        m.append(plainSized(" ", font: Self.rowSmall))
        return m
    }

    func summarySep() -> NSAttributedString {
        plainSized("  ·  ", font: Self.rowSmall, color: .tertiaryLabelColor)
    }

    /// Agent rows. Claude: 5h bar and %, time to reset, week %, and "out …"
    /// only when the pace says the window runs out; its submenu holds the full
    /// usage blocks and `details`. Codex / Gemini / Copilot get a row each when
    /// they have data, inserted right after Claude, with their buckets in a submenu.
    func rebuildUsageSummary(fiveHourPct: Double?, resetMin: Int?, weekPct: Double?,
                             pace: (text: String, color: NSColor)?) {
        let row = NSMutableAttributedString(attributedString: plainSized("Claude  ", font: Self.rowFont))
        if let p = fiveHourPct {
            row.append(summaryBar(pct: p))
            row.append(plainSized(String(format: " %.0f%%", p), font: Self.rowMono, color: barColor(p)))
            if let m = resetMin {
                row.append(summarySep())
                row.append(plainSized(formatResetMinutes(m), font: Self.rowSmall, color: .secondaryLabelColor))
            }
            if let w = weekPct {
                row.append(summarySep())
                row.append(plainSized(String(format: "wk %.0f%%", w), font: Self.rowSmall, color: .secondaryLabelColor))
            }
            if let pace, pace.color == .systemRed {
                row.append(summarySep())
                row.append(plainSized(pace.text.replacingOccurrences(of: "runs out in", with: "out"),
                                      font: Self.rowSmall, color: .systemRed))
            }
        } else {
            row.append(plainSized("no data", font: Self.rowSmall, color: .secondaryLabelColor))
        }
        usageItem.attributedTitle = row
        rebuildProviderRows()
    }

    /// (label, pct, resets_at ISO) per bucket of a non-Claude provider.
    func providerBuckets(_ key: String, _ p: [String: Any]) -> [(String, Double, String?)] {
        switch key {
        case "codex":
            let c = p["codex"] as? [String: Any] ?? [:]
            return [("Session", "five_hour"), ("Weekly", "seven_day")].compactMap { label, k in
                guard let b = c[k] as? [String: Any], let u = b["utilization"] as? Double else { return nil }
                return (label, u, b["resets_at"] as? String)
            }
        case "gemini":
            let models = (p["gemini"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            return models.compactMap { m in
                guard let u = m["utilization"] as? Double else { return nil }
                return ((m["name"] as? String) ?? "model", u, m["resets_at"] as? String)
            }
        case "copilot":
            let c = p["copilot"] as? [String: Any] ?? [:]
            return [("Chat", "chat"), ("Completions", "completions"), ("Premium", "premium")].compactMap { label, k in
                guard let b = c[k] as? [String: Any], (b["unlimited"] as? Bool) != true,
                      let u = b["utilization"] as? Double else { return nil }
                return (label, u, b["resets_at"] as? String)
            }
        default:
            return []
        }
    }

    func rebuildProviderRows() {
        guard let menu else { return }
        for item in providerRowItems { menu.removeItem(item) }
        providerRowItems = []
        guard let p = lastPayload else { return }
        // Agent rows go right above the Jira row.
        guard let todayItem else { return }
        var index = menu.index(of: todayItem)
        let names = ["codex": "Codex", "gemini": "Gemini", "copilot": "Copilot"]
        for key in ["codex", "gemini", "copilot"] {
            let buckets = providerBuckets(key, p)
            guard let top = buckets.max(by: { $0.1 < $1.1 }) else { continue }
            let item = NSMenuItem(title: names[key]!, action: nil, keyEquivalent: "")
            item.image = tintedSymbol(name: providerSymbol(key), color: PROVIDER_COLORS[key])
            let row = NSMutableAttributedString(attributedString: plainSized(names[key]! + "  ", font: Self.rowFont))
            row.append(summaryBar(pct: top.1))
            row.append(plainSized(String(format: " %.0f%%", top.1), font: Self.rowMono, color: barColor(top.1)))
            if let iso = top.2, let m = minutesUntil(iso: iso), m > 0 {
                row.append(summarySep())
                row.append(plainSized(formatResetMinutes(m), font: Self.rowSmall, color: .secondaryLabelColor))
            }
            if key == "codex", let wk = buckets.first(where: { $0.0 == "Weekly" }) {
                row.append(summarySep())
                row.append(plainSized(String(format: "wk %.0f%%", wk.1), font: Self.rowSmall, color: .secondaryLabelColor))
            } else if buckets.count > 1 {
                // Gemini models / Copilot quotas: name the one shown.
                row.append(summarySep())
                row.append(plainSized(top.0, font: Self.rowSmall, color: .secondaryLabelColor))
            }
            item.attributedTitle = row
            let sub = NSMenu()
            sub.autoenablesItems = false
            for (label, pct, iso) in buckets {
                var line = String(format: "%@  %.0f%%", label, pct)
                if let iso, let m = minutesUntil(iso: iso), m > 0 { line += "  ·  resets in " + formatResetLong(m).trimmingCharacters(in: .whitespaces) }
                let mi = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                sub.addItem(mi)
            }
            item.submenu = sub
            menu.insertItem(item, at: index)
            providerRowItems.append(item)
            index += 1
        }
    }

    /// Jira-like mark for the Today row: two overlapping chevrons in Jira blue,
    /// drawn here (no bundled logo). 16×16, template-free so it keeps its colour.
    func jiraMark() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let blue = NSColor(srgbRed: 0.15, green: 0.52, blue: 1.0, alpha: 1.0)
            let dark = NSColor(srgbRed: 0.0, green: 0.32, blue: 0.80, alpha: 1.0)
            func diamond(_ cx: CGFloat, _ cy: CGFloat, _ h: CGFloat) -> NSBezierPath {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx, y: cy + h)); p.line(to: NSPoint(x: cx + h, y: cy))
                p.line(to: NSPoint(x: cx, y: cy - h)); p.line(to: NSPoint(x: cx - h, y: cy)); p.close()
                return p
            }
            dark.setFill(); diamond(r.midX - 2.2, r.midY, 5.2).fill()
            blue.setFill(); diamond(r.midX + 2.2, r.midY, 5.2).fill()
            NSColor.white.withAlphaComponent(0.9).setFill(); diamond(r.midX + 2.2, r.midY, 1.9).fill()
            return true
        }
    }

    /// Today's and this week's cost from ccusage's daily/weekly rows (the
    /// last row is the current period when it carries today's date).
    func spendTodayAndWeek() -> (Double, Double?)? {
        guard let p = lastPayload else { return nil }
        let daily = (p["daily"] as? [[String: Any]]) ?? []
        guard let last = daily.last, (last["period"] as? String) == localDateString(),
              let cost = last["totalCost"] as? Double else { return nil }
        let week = ((p["weekly"] as? [[String: Any]]) ?? []).last?["totalCost"] as? Double
        return (cost, week)
    }

    func sectionLabelWithSummary(_ label: String, _ summary: String) -> NSAttributedString {
        let m = NSMutableAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.tertiaryLabelColor, .kern: 1.0])
        m.append(NSAttributedString(string: "    " + summary, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return m
    }

    /// Menu-bar title = waiting badge (if any session waits on you) + the
    /// usage title built by `render(payload:)`.
    func applyTrayTitle() {
        let m = NSMutableAttributedString()
        let waiting = sessions.filter { $0.state == .waiting }.count
        if waiting > 0, let img = tintedSymbol(name: "hand.raised.fill", color: .systemOrange) {
            let att = NSTextAttachment()
            att.image = img
            att.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            m.append(NSAttributedString(attachment: att))
            m.append(NSAttributedString(string: "\(waiting)  ",
                attributes: [.font: Self.monoFont, .foregroundColor: NSColor.systemOrange]))
        }
        m.append(usageTitle)
        trayTitle = m
        statusItem?.button?.attributedTitle = m
        if waiting > 0 {
            let names = sessions.filter { $0.state == .waiting }.map { $0.name }.joined(separator: ", ")
            statusItem?.button?.toolTip = "Waiting on you: \(names)\n" + (usageTooltip ?? "")
        } else {
            statusItem?.button?.toolTip = usageTooltip
        }
    }

    // ── settings rows added in v0.6 ──

    func rebuildFinishNotifyItem() {
        let on = finishNotifyMinutes > 0
        finishNotifyItem.attributedTitle = menuToggleLabel(
            on ? "Session finished  ·  after \(finishNotifyMinutes)m busy" : "Session finished  ·  off", active: on)
        finishNotifyItem.image = tintedSymbol(name: on ? "checkmark.circle.fill" : "checkmark.circle",
                                              color: on ? .systemGreen : .tertiaryLabelColor)
        let sub = NSMenu()
        let off = NSMenuItem(title: "", action: #selector(pickFinishNotify(_:)), keyEquivalent: "")
        off.target = self; off.tag = 0
        off.attributedTitle = plain("\(on ? "   " : "✓ ")off")
        sub.addItem(off)
        sub.addItem(.separator())
        for m in FINISH_NOTIFY_OPTIONS {
            let mi = NSMenuItem(title: "", action: #selector(pickFinishNotify(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = m
            mi.attributedTitle = plain("\(m == finishNotifyMinutes ? "✓ " : "   ")after \(m) min busy")
            sub.addItem(mi)
        }
        finishNotifyItem.submenu = sub
    }

    @objc func pickFinishNotify(_ sender: NSMenuItem) {
        finishNotifyMinutes = sender.tag
        saveDisplayConfig()
        rebuildFinishNotifyItem()
    }

    func rebuildDailyTargetItem() {
        dailyTargetItem.attributedTitle = menuToggleLabel("Daily target  ·  \(dailyTargetHours)h", active: true)
        dailyTargetItem.image = tintedSymbol(name: "target", color: .systemBlue)
        let sub = NSMenu()
        for h in DAILY_TARGET_OPTIONS {
            let mi = NSMenuItem(title: "", action: #selector(pickDailyTarget(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = h
            mi.attributedTitle = plain("\(h == dailyTargetHours ? "✓ " : "   ")\(h) h")
            sub.addItem(mi)
        }
        dailyTargetItem.submenu = sub
    }

    @objc func pickDailyTarget(_ sender: NSMenuItem) {
        guard sender.tag > 0 else { return }
        dailyTargetHours = sender.tag
        saveDisplayConfig()
        rebuildDailyTargetItem()
        rebuildTodayItem()
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a bundled bash script and parses its stdout as a JSON object.
func runJSONScript(_ path: String) -> [String: Any]? {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [path]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do { try task.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// ── --self-test ───────────────────────────────────────────────────────────

/// Checks the pure session logic. Run by CI after the build:
/// `claude-usage-bar --self-test` exits 1 on the first failed group.
func runSelfTest() -> Bool {
    var failures: [String] = []
    var passed = 0
    func check(_ name: String, _ cond: Bool) {
        if cond { passed += 1 } else { failures.append(name) }
    }
    func s(_ id: String, _ state: String, waiting: Double? = nil, last: Double? = nil,
           task: String? = nil, kind: String = "interactive") -> AgentSession {
        var d: [String: Any] = ["id": id, "name": "n-\(id)", "state": state, "kind": kind]
        if let waiting { d["waitingSince"] = waiting }
        if let last { d["lastActivity"] = last }
        if let task { d["task"] = task }
        return AgentSession(d)!
    }

    // parse
    check("parse: missing id is dropped", AgentSession(["name": "x"]) == nil)
    check("parse: unknown state is idle", AgentSession(["id": "a", "state": "weird"])?.state == .idle)
    check("parse: empty title is nil", AgentSession(["id": "a", "title": ""])?.title == nil)
    check("parse: snapshot without sessions is nil", SessionsSnapshot.parse(["today": [:]]) == nil)

    // order
    let order = sortSessions([
        s("idle-old", "idle", last: 100), s("busy", "busy", last: 50),
        s("wait-new", "waiting", waiting: 900), s("idle-new", "idle", last: 500),
        s("wait-old", "waiting", waiting: 100),
    ]).map { $0.id }
    check("sort: waiting (oldest first), busy, idle (recent first)",
          order == ["wait-old", "wait-new", "busy", "idle-new", "idle-old"])

    // summary + labels
    check("summary", sessionsSummary([s("a", "busy"), s("b", "waiting"), s("c", "idle")]) == "3 open · 1 busy · 1 waiting")
    check("summary: idle only", sessionsSummary([s("a", "idle")]) == "1 open")
    check("age", fmtAge(45) == "45s" && fmtAge(125) == "2m" && fmtAge(7300) == "2h" && fmtAge(200000) == "2d")
    check("hm", fmtHM(22500) == "6h 15m" && fmtHM(2700) == "45m" && fmtHM(-5) == "0m")
    check("hm short", fmtHMShort(21600) == "6h" && fmtHMShort(22500) == "6h 15m" && fmtHMShort(2700) == "45m")
    check("state label", stateLabel(s("w", "waiting", waiting: 1000), now: 1180) == "waiting 3m"
          && stateLabel(s("i", "idle", last: 0), now: 7200) == "idle 2h")

    // today is shown only for the local date
    let t = TodayInfo(["date": "2026-10-15", "loggedSeconds": 3600])
    check("today: same date shown", todayIfCurrent(t, localDate: "2026-10-15") != nil)
    check("today: stale date hidden", todayIfCurrent(t, localDate: "2026-10-16") == nil)
    check("today: malformed is nil", TodayInfo(["date": "2026-10-15"]) == nil)

    // finished detection
    var tr = BusyTracker()
    _ = tr.update([s("a", "busy"), s("b", "busy")], now: 0, minBusy: 600)
    _ = tr.update([s("a", "waiting"), s("b", "busy")], now: 300, minBusy: 600)
    let f1 = tr.update([s("a", "busy")], now: 500, minBusy: 600)          // b disappeared: closed, not finished
    check("tracker: closed session is not reported", f1.isEmpty)
    let f2 = tr.update([s("a", "idle")], now: 700, minBusy: 600)
    check("tracker: busy→waiting→busy→idle counts from the first busy", f2.count == 1 && f2[0].1 == 700)
    let f3 = tr.update([s("a", "idle")], now: 900, minBusy: 600)
    check("tracker: reported once", f3.isEmpty)
    _ = tr.update([s("c", "busy")], now: 1000, minBusy: 600)
    check("tracker: short job is not reported", tr.update([s("c", "idle")], now: 1100, minBusy: 600).isEmpty)

    // Jira: site normalisation, status merge, visibility, today source
    check("jira site", normalizeJiraSite("x.atlassian.net") == "https://x.atlassian.net"
          && normalizeJiraSite(" https://x.atlassian.net/jira/software ") == "https://x.atlassian.net"
          && normalizeJiraSite("http://x.atlassian.net") == nil && normalizeJiraSite("") == nil)
    var withTask = s("a", "idle", task: "OPS-1")
    withTask.taskStatus = "To Do"
    let merged = applyJira([withTask], statuses: ["OPS-1": JiraStatus(name: "Done", done: true, url: "u")], showTasks: true)
    check("jira: built-in status overrides metadata", merged[0].taskStatus == "Done" && merged[0].taskDone && merged[0].taskUrl == "u")
    check("jira: hidden tasks are dropped", applyJira([withTask], statuses: [:], showTasks: false)[0].task == nil)
    let jt = TodayInfo(["date": "2026-10-15", "loggedSeconds": 100]), mt = TodayInfo(["date": "2026-10-15", "loggedSeconds": 200])
    check("today: built-in Jira wins", chooseToday(jira: jt, meta: mt, showTasks: true, localDate: "2026-10-15")?.loggedSeconds == 100)
    check("today: stale built-in falls back to metadata",
          chooseToday(jira: TodayInfo(["date": "2026-10-14", "loggedSeconds": 1]), meta: mt, showTasks: true, localDate: "2026-10-15")?.loggedSeconds == 200)
    check("today: hidden when tasks are off", chooseToday(jira: jt, meta: mt, showTasks: false, localDate: "2026-10-15") == nil)
    check("jira result: error passed through", JiraResult.parse(["ok": false, "error": "HTTP 401"]).error == "HTTP 401")

    check("shell quote", shellQuote("/a b/it's") == "'/a b/it'\\''s'")

    // support scripts: ours are upgraded with a backup, foreign ones are not touched
    let tmp = NSTemporaryDirectory() + "cub-selftest-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: tmp + "/hooks", withIntermediateDirectories: true, attributes: nil)
    let oldOurs = "#!/bin/bash\n# the claude-usage-bar widget writes the delay\nold\n"
    try? oldOurs.write(toFile: tmp + "/hooks/claude-notify.sh", atomically: true, encoding: .utf8)
    try? "#!/bin/bash\n# my own cancel hook\n".write(toFile: tmp + "/hooks/claude-notify-cancel.sh", atomically: true, encoding: .utf8)
    // Both bundled scripts point at a missing folder, so the result does not
    // depend on whether sessions.sh / jira.py happen to sit next to the binary.
    let saved = SESSIONS_SCRIPT_PATH, savedJira = JIRA_SCRIPT_PATH
    SESSIONS_SCRIPT_PATH = tmp + "/missing/sessions.sh"
    JIRA_SCRIPT_PATH = tmp + "/missing/jira.py"
    let changed = ensureSupportScripts(fm: fm, supportDir: tmp + "/support", hooksDir: tmp + "/hooks")
    let notify = (try? String(contentsOfFile: tmp + "/hooks/claude-notify.sh", encoding: .utf8)) ?? ""
    check("support: missing sessions.sh and jira.py restored from the binary",
          SESSIONS_SCRIPT_PATH == tmp + "/support/sessions.sh" && fm.isExecutableFile(atPath: SESSIONS_SCRIPT_PATH)
          && JIRA_SCRIPT_PATH == tmp + "/support/jira.py" && fm.isExecutableFile(atPath: JIRA_SCRIPT_PATH))
    check("support: our old hook upgraded, backup kept",
          notify.contains("claude-waiting-") && (try? String(contentsOfFile: tmp + "/hooks/claude-notify.sh.bak", encoding: .utf8)) == oldOurs)
    check("support: foreign hook untouched",
          (try? String(contentsOfFile: tmp + "/hooks/claude-notify-cancel.sh", encoding: .utf8)) == "#!/bin/bash\n# my own cancel hook\n")
    check("support: second run changes nothing",
          changed.count == 3 && ensureSupportScripts(fm: fm, supportDir: tmp + "/support", hooksDir: tmp + "/hooks").isEmpty)
    SESSIONS_SCRIPT_PATH = saved
    JIRA_SCRIPT_PATH = savedJira
    try? fm.removeItem(atPath: tmp)

    if failures.isEmpty {
        print("self-test: \(passed) checks passed")
        return true
    }
    for f in failures { fputs("self-test FAILED: \(f)\n", stderr) }
    print("self-test: \(passed) passed, \(failures.count) failed")
    return false
}

// ── --render-preview ──────────────────────────────────────────────────────

/// Draws the menu-bar title and the dropdown as one PNG, without opening the
/// menu: for README screenshots and for checking a change before release.
/// Custom-view rows are rendered from their views; standard rows are drawn
/// from their image + attributed title, with "▸" for submenus.
func renderMenuPreview(app: App, to path: String, dark: Bool) -> Bool {
    guard let menu = app.menu else { return false }
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    var result = false
    appearance.performAsCurrentDrawingAppearance {
        NSApp.appearance = appearance
        let pad: CGFloat = 10
        var rows: [(height: CGFloat, draw: (NSRect) -> Void)] = []

        // tray strip
        let tray = app.trayTitle
        rows.append((28, { rect in
            NSColor.controlBackgroundColor.setFill(); rect.fill()
            let size = tray.size()
            tray.draw(at: NSPoint(x: rect.maxX - size.width - pad, y: rect.midY - size.height / 2))
        }))
        rows.append((6, { _ in }))

        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                rows.append((11, { rect in
                    NSColor.separatorColor.setFill()
                    NSRect(x: rect.minX + pad, y: rect.midY, width: rect.width - 2 * pad, height: 1).fill()
                }))
            } else if let view = item.view {
                // Views not in a window don't inherit the app appearance.
                view.appearance = appearance
                view.needsDisplay = true
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let img = NSImage(size: view.bounds.size)
                img.addRepresentation(rep)
                rows.append((view.bounds.height, { rect in
                    img.draw(in: NSRect(x: rect.minX, y: rect.minY, width: img.size.width, height: img.size.height))
                }))
            } else {
                let title = NSMutableAttributedString(attributedString: item.attributedTitle
                    ?? NSAttributedString(string: item.title, attributes: [
                        .font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
                if !item.isEnabled && item.action == nil && item.submenu == nil {
                    title.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                       range: NSRange(location: 0, length: title.length))
                }
                let image = item.image
                let hasSub = item.submenu != nil
                let h = max(22, title.size().height + 6)
                rows.append((h, { rect in
                    var x = rect.minX + pad + 4
                    if let image {
                        image.draw(in: NSRect(x: x, y: rect.midY - 8, width: 16, height: 16))
                    }
                    x += 22
                    let sz = title.size()
                    title.draw(at: NSPoint(x: x, y: rect.midY - sz.height / 2))
                    if hasSub {
                        let chev = NSAttributedString(string: "›", attributes: [
                            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                            .foregroundColor: NSColor.secondaryLabelColor])
                        chev.draw(at: NSPoint(x: rect.maxX - pad - 10, y: rect.midY - chev.size().height / 2))
                    }
                }))
            }
        }

        let width = max(CONTENT_WIDTH + 2 * 14, 560)
        let height = rows.reduce(pad) { $0 + $1.height } + pad
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var y = height - pad
        for r in rows {
            y -= r.height
            r.draw(NSRect(x: 0, y: y, width: width, height: r.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            result = (try? png.write(to: URL(fileURLWithPath: path))) != nil
        }
    }
    return result
}

// ── Jira (optional, built in) ─────────────────────────────────────────────
//
// Off until the user connects: Settings › Jira › Connect… asks for the site,
// email and an API token. The token goes to the Keychain (this app's own
// item, read back without a prompt) and reaches jira.py only through the
// child's environment. jira.py returns today's logged time (local day) and
// the status of the sessions' task keys; refreshed every JIRA_POLL_SECONDS.
// "Show tasks & logged time" hides the task column and the Logged part of
// Today, whatever the source (built-in Jira or the metadata files).

let JIRA_POLL_SECONDS: TimeInterval = 300
let JIRA_KEYCHAIN_SERVICE = "claude-usage-bar-jira"
let JIRA_CONFIG_PATH = "\(NSHomeDirectory())/.cache/claude-usage-bar/jira.json"
var JIRA_SCRIPT_PATH: String = (SCRIPT_PATH as NSString).deletingLastPathComponent + "/jira.py"

struct JiraConfig: Equatable {
    var site = ""
    var email = ""
    var showTasks = true
    var isConfigured: Bool { !site.isEmpty && !email.isEmpty }

    static func load(_ path: String = JIRA_CONFIG_PATH) -> JiraConfig {
        var c = JiraConfig()
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
        c.site = (o["site"] as? String) ?? ""
        c.email = (o["email"] as? String) ?? ""
        c.showTasks = (o["showTasks"] as? Bool) ?? true
        return c
    }

    func save(_ path: String = JIRA_CONFIG_PATH) {
        let o: [String: Any] = ["site": site, "email": email, "showTasks": showTasks]
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: nil)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// "your-site.atlassian.net", "https://x.atlassian.net/jira/…" → "https://x.atlassian.net".
/// nil when it is not an https URL with a host.
func normalizeJiraSite(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if !s.contains("://") { s = "https://" + s }
    guard let u = URL(string: s), u.scheme == "https", let host = u.host, host.contains(".") else { return nil }
    return "https://" + host
}

struct JiraStatus: Equatable { var name: String; var done: Bool; var url: String }

struct JiraResult {
    var today: TodayInfo?
    var statuses: [String: JiraStatus] = [:]
    var error: String?

    static func parse(_ o: [String: Any]?) -> JiraResult {
        guard let o else { return JiraResult(error: "no answer from jira.py") }
        guard (o["ok"] as? Bool) == true else { return JiraResult(error: (o["error"] as? String) ?? "unknown error") }
        var r = JiraResult(today: TodayInfo(o["today"] as? [String: Any]))
        for (k, v) in (o["statuses"] as? [String: [String: Any]]) ?? [:] {
            r.statuses[k] = JiraStatus(name: (v["name"] as? String) ?? "?",
                                       done: (v["category"] as? String) == "done",
                                       url: (v["url"] as? String) ?? "")
        }
        return r
    }
}

/// Built-in Jira statuses override what the metadata files said; tasks are
/// dropped entirely when the user turned "Show tasks & logged time" off.
func applyJira(_ list: [AgentSession], statuses: [String: JiraStatus], showTasks: Bool) -> [AgentSession] {
    list.map { s in
        var s = s
        if !showTasks {
            s.task = nil; s.taskStatus = nil; s.taskDone = false; s.taskUrl = nil
            return s
        }
        if let k = s.task, let st = statuses[k] {
            s.taskStatus = st.name; s.taskDone = st.done; s.taskUrl = st.url
        }
        return s
    }
}

/// Today's logged time: built-in Jira when connected and fresh for today,
/// else the metadata file; nothing when tasks are hidden.
func chooseToday(jira: TodayInfo?, meta: TodayInfo?, showTasks: Bool, localDate: String) -> TodayInfo? {
    guard showTasks else { return nil }
    return todayIfCurrent(jira, localDate: localDate) ?? todayIfCurrent(meta, localDate: localDate)
}

enum JiraKeychain {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: JIRA_KEYCHAIN_SERVICE,
         kSecAttrAccount as String: account]
    }
    static func save(token: String, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrLabel as String] = "claude-usage-bar Jira API token"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// Runs jira.py with the token in its environment (never in argv).
func runJira(_ args: [String], config: JiraConfig, token: String) -> [String: Any]? {
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.arguments = ["python3", JIRA_SCRIPT_PATH] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["JIRA_SITE"] = config.site
    env["JIRA_EMAIL"] = config.email
    env["JIRA_TOKEN"] = token
    task.environment = env
    let out = Pipe()
    task.standardOutput = out
    task.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do { try task.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

extension App {

    func scheduleJiraTimer() {
        jiraTimer?.invalidate()
        jiraTimer = Timer.scheduledTimer(withTimeInterval: JIRA_POLL_SECONDS, repeats: true) { [weak self] _ in
            self?.refreshJira()
        }
    }

    @objc func refreshJira() {
        guard !previewMode, jiraConfig.isConfigured, jiraConfig.showTasks,
              let token = JiraKeychain.read(account: jiraConfig.email) else { return }
        let cfg = jiraConfig
        let keys = Array(Set(rawSessions.compactMap { $0.task }))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = JiraResult.parse(runJira(["refresh"] + keys, config: cfg, token: token))
            DispatchQueue.main.async {
                guard let self else { return }
                self.jiraResult = r
                self.applySessions(nil)
                self.rebuildJiraItem()
            }
        }
    }

    func rebuildJiraItem() {
        let connected = jiraConfig.isConfigured
        let on = connected && jiraConfig.showTasks
        jiraItem.attributedTitle = menuToggleLabel(
            connected ? (jiraConfig.showTasks ? "Jira  ·  on" : "Jira  ·  hidden") : "Jira  ·  not connected", active: on)
        jiraItem.image = tintedSymbol(name: on ? "checklist.checked" : "checklist",
                                      color: on ? .systemBlue : .tertiaryLabelColor)
        let sub = NSMenu()
        sub.autoenablesItems = false
        func info(_ text: String, color: NSColor = .secondaryLabelColor) {
            let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            mi.attributedTitle = plainSized(text, font: NSFont.systemFont(ofSize: 12), color: color)
            sub.addItem(mi)
        }
        if connected {
            info("\(jiraConfig.email) · \(jiraConfig.site.replacingOccurrences(of: "https://", with: ""))")
            if let e = jiraResult?.error { info("Last refresh failed: \(e)", color: .systemRed) }
        } else {
            info("Shows your logged time today and the status of each session's task.")
        }
        sub.addItem(.separator())
        let connect = NSMenuItem(title: connected ? "Reconnect…" : "Connect…", action: #selector(showJiraConnect), keyEquivalent: "")
        connect.target = self
        sub.addItem(connect)
        let show = NSMenuItem(title: "\(jiraConfig.showTasks ? "✓ " : "   ")Show tasks & logged time",
                              action: #selector(toggleJiraShowTasks), keyEquivalent: "")
        show.target = self
        sub.addItem(show)
        if connected {
            let disc = NSMenuItem(title: "Disconnect", action: #selector(disconnectJira), keyEquivalent: "")
            disc.target = self
            sub.addItem(disc)
        }
        jiraItem.submenu = sub
    }

    @objc func toggleJiraShowTasks() {
        jiraConfig.showTasks.toggle()
        jiraConfig.save()
        rebuildJiraItem()
        applySessions(nil)
        if jiraConfig.showTasks { refreshJira() }
    }

    @objc func disconnectJira() {
        JiraKeychain.delete(account: jiraConfig.email)
        jiraConfig.site = ""; jiraConfig.email = ""
        jiraConfig.save()
        jiraResult = nil
        rebuildJiraItem()
        applySessions(nil)
    }

    @objc func showJiraConnect() {
        let w: CGFloat = 320
        func field(_ placeholder: String, _ value: String, secure: Bool = false) -> NSTextField {
            let f: NSTextField = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
            f.placeholderString = placeholder
            f.stringValue = value
            f.frame = NSRect(x: 0, y: 0, width: w, height: 24)
            return f
        }
        let site = field("your-site.atlassian.net", jiraConfig.site)
        let email = field("you@company.com", jiraConfig.email)
        let token = field("API token", "", secure: true)
        let hint = NSTextField(wrappingLabelWithString:
            "Create a token at id.atlassian.com → Security → API tokens. It is stored in your Keychain and sent only to your Jira site.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = w
        let stack = NSStackView(views: [site, email, token, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: w, height: 150)

        let alert = NSAlert()
        alert.messageText = "Connect Jira"
        alert.informativeText = "Jira Cloud. Read-only: the widget never writes to Jira."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = jiraConfig.site.isEmpty ? site : token
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let s = normalizeJiraSite(site.stringValue) else {
            showInfo(title: "Jira not connected", message: "The site must be an https address, like your-site.atlassian.net.")
            return
        }
        let e = email.stringValue.trimmingCharacters(in: .whitespaces)
        var t = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, e == jiraConfig.email, let old = JiraKeychain.read(account: e) { t = old }
        guard !e.isEmpty, !t.isEmpty else {
            showInfo(title: "Jira not connected", message: "Email and API token are both needed.")
            return
        }
        var cfg = jiraConfig
        cfg.site = s; cfg.email = e
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = runJira(["check"], config: cfg, token: t)
            DispatchQueue.main.async {
                guard let self else { return }
                guard (r?["ok"] as? Bool) == true else {
                    self.showInfo(title: "Jira not connected", message: (r?["error"] as? String) ?? "No answer from \(s).")
                    return
                }
                if !self.jiraConfig.email.isEmpty, self.jiraConfig.email != e { JiraKeychain.delete(account: self.jiraConfig.email) }
                guard JiraKeychain.save(token: t, account: e) else {
                    self.showInfo(title: "Jira not connected", message: "Could not save the token to the Keychain.")
                    return
                }
                self.jiraConfig = cfg
                self.jiraConfig.showTasks = true
                self.jiraConfig.save()
                self.rebuildJiraItem()
                self.refreshJira()
                self.showInfo(title: "Jira connected", message: "Signed in as \((r?["name"] as? String) ?? e).")
            }
        }
    }
}
