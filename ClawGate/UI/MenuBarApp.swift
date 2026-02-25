import AppKit
import SwiftUI

private extension NSColor {
    /// Bright light-gray for default log text — always readable on a dark panel background.
    static let logDefault = NSColor(white: 0.82, alpha: 1.0)
    /// Dimmer gray for "no logs" placeholder text.
    static let logDim = NSColor(white: 0.55, alpha: 1.0)
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private enum GhosttyAnchorSide {
        case right
        case left
    }

    private var statusItem: NSStatusItem?
    private var mainPanel: NSPanel?
    private var mainPanelHost: NSHostingController<MainPanelView>?
    private var refreshTimer: Timer?
    private var ghosttyFollowTimer: Timer?
    private var lastGhosttyFrame: CGRect?
    private var isGhosttySnapped = false
    private var ghosttyDetachCooldownUntil: Date?
    private var ghosttyAnchorSide: GhosttyAnchorSide = .right
    private var ghosttyLastDebugLogAt: Date = .distantPast
    private var activationObserver: NSObjectProtocol?
    private var lastAppliedPanelLevel: NSWindow.Level?
    private let mainPanelLogLimit = 30
    private let ghosttyBundleID = "com.mitchellh.ghostty"

    private let modeOrder: [String] = ["ignore", "observe", "auto", "autonomous"]

    private let runtime: AppRuntime
    private let statsCollector: StatsCollector
    private let opsLogStore: OpsLogStore
    private let settingsModel: SettingsModel
    private let panelModel = MainPanelModel()

    init(runtime: AppRuntime, statsCollector: StatsCollector, opsLogStore: OpsLogStore) {
        self.runtime = runtime
        self.statsCollector = statsCollector
        self.opsLogStore = opsLogStore
        self.settingsModel = SettingsModel(configStore: runtime.configStore)
        super.init()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        configureStatusButton()
        configureMainPanel()
        startWindowLevelObserver()

        runtime.startServer()
        refreshSessionsMenu(sessions: runtime.allCCSessions())
        refreshStatsAndTimeline()
        startRefreshTimer()
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(toggleMainPanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureMainPanel() {
        let view = MainPanelView(
            settingsModel: settingsModel,
            panelModel: panelModel,
            modeOrder: modeOrder,
            modeLabel: { [weak self] mode in
                self?.modeLabel(mode) ?? mode.capitalized
            },
            onSetSessionMode: { [weak self] sessionType, project, mode in
                self?.setSessionMode(sessionType: sessionType, project: project, next: mode)
            },
            onQuit: { [weak self] in
                self?.quit()
            },
            logLimit: mainPanelLogLimit
        )
        let host = NSHostingController(rootView: view)
        mainPanelHost = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 275, height: 600),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.backgroundColor = PanelTheme.backgroundNSColor
        panel.isOpaque = false
        panel.contentViewController = host
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 200, height: 300)
        panel.maxSize = NSSize(width: 700, height: 1400)
        mainPanel = panel
        applyMainPanelLevel(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func startWindowLevelObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.applyMainPanelLevel(frontmostBundleID: app?.bundleIdentifier)
        }
        applyMainPanelLevel(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func applyMainPanelLevel(frontmostBundleID: String?) {
        guard let panel = mainPanel else { return }
        let desiredLevel: NSWindow.Level = (frontmostBundleID == ghosttyBundleID) ? .floating : .normal
        guard desiredLevel != lastAppliedPanelLevel else { return }
        panel.level = desiredLevel
        panel.isFloatingPanel = (desiredLevel == .floating)
        lastAppliedPanelLevel = desiredLevel
    }

    private func fitPanelToContent(_ panel: NSPanel) {
        guard let host = mainPanelHost else { return }
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize

        let w = min(max(fitting.width, panel.minSize.width), panel.maxSize.width)

        let screenMaxH: CGFloat
        if let screen = NSScreen.main {
            screenMaxH = screen.visibleFrame.height - 28
        } else {
            screenMaxH = panel.maxSize.height
        }
        // 580: enough to show QR code section when switching to Config tab
        let minH = max(panel.minSize.height, 580)
        let h = min(max(fitting.height, minH), min(panel.maxSize.height, screenMaxH))

        panel.setContentSize(NSSize(width: w, height: h))
    }

    @objc private func toggleMainPanel(_ sender: Any?) {
        guard let panel = mainPanel else { return }

        if panel.isVisible {
            closeMainPanel(sender)
            return
        }

        settingsModel.reload()
        refreshSessionsMenu(sessions: runtime.allCCSessions())
        refreshStatsAndTimeline()
        fitPanelToContent(panel)
        positionPanelBelowStatusItem(panel)
        applyMainPanelLevel(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        panel.makeKeyAndOrderFront(nil)
    }

    private func shouldDebugGhosttyFollow() -> Bool {
        runtime.configStore.load().debugLogging
    }

    private func logGhosttyFollow(_ message: String, level: String = "debug") {
        guard shouldDebugGhosttyFollow() else { return }
        let role = runtime.configStore.load().nodeRole.rawValue
        opsLogStore.append(
            level: level,
            event: "ghostty_follow",
            role: role,
            script: "clawgate.app",
            message: message
        )
    }

    private func logGhosttyFollowThrottled(_ message: String, level: String = "debug", minInterval: TimeInterval = 1.0) {
        guard shouldDebugGhosttyFollow() else { return }
        let now = Date()
        guard now.timeIntervalSince(ghosttyLastDebugLogAt) >= minInterval else { return }
        ghosttyLastDebugLogAt = now
        logGhosttyFollow(message, level: level)
    }

    private func visibleArea(for frame: CGRect) -> CGFloat {
        NSScreen.screens.reduce(CGFloat.zero) { partial, screen in
            let intersection = frame.intersection(screen.visibleFrame)
            if intersection.isNull || intersection.isEmpty {
                return partial
            }
            return partial + (intersection.width * intersection.height)
        }
    }

    private func appKitFrameFromCGWindowBounds(_ cgFrame: CGRect) -> CGRect {
        let globalTop = NSScreen.screens.map(\.frame.maxY).max() ?? cgFrame.maxY
        let appKitY = globalTop - cgFrame.minY - cgFrame.height
        return CGRect(x: cgFrame.minX, y: appKitY, width: cgFrame.width, height: cgFrame.height)
    }

    private func findGhosttyFrame() -> CGRect? {
        guard
            let windowInfo = CGWindowListCopyWindowInfo(
                [.excludeDesktopElements, .optionOnScreenOnly],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }

        let minWindowDimension: CGFloat = 40
        var bestFrame: CGRect?
        var bestVisibleArea: CGFloat = 0

        for info in windowInfo {
            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let ownerLower = ownerName.lowercased()
            let ownerMatches = ownerLower.contains("ghostty")

            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.intValue) }
            let bundleID = ownerPID.flatMap { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased()
            }
            let bundleMatches = bundleID?.contains("ghostty") ?? false

            guard ownerMatches || bundleMatches else {
                continue
            }

            let layerValue = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layerValue == 0 else { continue }

            guard
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let cgFrame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }
            let convertedFrame = appKitFrameFromCGWindowBounds(cgFrame)
            let rawVisibleArea = visibleArea(for: cgFrame)
            let convertedVisibleArea = visibleArea(for: convertedFrame)
            let frame: CGRect
            let visibleArea: CGFloat
            if convertedVisibleArea >= rawVisibleArea {
                frame = convertedFrame
                visibleArea = convertedVisibleArea
            } else {
                frame = cgFrame
                visibleArea = rawVisibleArea
            }

            guard
                frame.width >= minWindowDimension,
                frame.height >= minWindowDimension
            else {
                continue
            }

            guard visibleArea > 0 else { continue }
            if visibleArea > bestVisibleArea {
                bestVisibleArea = visibleArea
                bestFrame = frame
            }
        }

        if let bestFrame {
            logGhosttyFollowThrottled(
                "Ghostty frame detected frame=\(bestFrame.integral) visibleArea=\(Int(bestVisibleArea))",
                minInterval: 0.8
            )
        } else {
            logGhosttyFollowThrottled(
                "Ghostty frame not detected (window scan returned no eligible frame)",
                level: "warning",
                minInterval: 1.5
            )
        }

        return bestFrame
    }

    private func clampPanelOrigin(_ origin: CGPoint, panelSize: CGSize, margin: CGFloat = 8) -> CGPoint {
        let panelRect = CGRect(origin: origin, size: panelSize)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panelRect) })
            ?? NSScreen.screens.first(where: { $0.visibleFrame.contains(origin) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen = screen else { return origin }

        let visibleFrame = targetScreen.visibleFrame
        let minX = visibleFrame.minX + margin
        let minY = visibleFrame.minY + margin
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - margin)
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - margin)

        let clampedX = max(minX, min(origin.x, maxX))
        let clampedY = max(minY, min(origin.y, maxY))
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func ghosttyAnchoredOrigin(
        for ghosttyFrame: CGRect,
        panelSize: CGSize,
        preferredSide: GhosttyAnchorSide?
    ) -> (origin: CGPoint, side: GhosttyAnchorSide) {
        let gap: CGFloat = 2
        let candidateScreen = NSScreen.screens.first(where: { $0.frame.intersects(ghosttyFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = candidateScreen?.visibleFrame

        let rightX = ghosttyFrame.maxX + gap
        let leftX = ghosttyFrame.minX - panelSize.width - gap
        let y = ghosttyFrame.maxY - panelSize.height

        let fitsRight = visibleFrame.map { rightX + panelSize.width <= $0.maxX - 0.5 } ?? true
        let fitsLeft = visibleFrame.map { leftX >= $0.minX + 0.5 } ?? true

        var side = preferredSide ?? (fitsRight ? .right : .left)
        if side == .right && !fitsRight && fitsLeft {
            side = .left
        } else if side == .left && !fitsLeft && fitsRight {
            side = .right
        }

        let x = (side == .right) ? rightX : leftX
        let clamped = clampPanelOrigin(CGPoint(x: x, y: y), panelSize: panelSize, margin: 2)
        return (CGPoint(x: round(clamped.x), y: round(clamped.y)), side)
    }

    private func startGhosttyFollow() {
        ghosttyFollowTimer?.invalidate()
        ghosttyFollowTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.tickGhosttyFollow()
        }
    }

    private func stopGhosttyFollow() {
        ghosttyFollowTimer?.invalidate()
        ghosttyFollowTimer = nil
        lastGhosttyFrame = nil
        isGhosttySnapped = false
        ghosttyDetachCooldownUntil = nil
        ghosttyAnchorSide = .right
    }

    private func detectSnapSide(panelFrame: CGRect, ghosttyFrame: CGRect, threshold: CGFloat) -> GhosttyAnchorSide? {
        let yOverlap = panelFrame.maxY > ghosttyFrame.minY && panelFrame.minY < ghosttyFrame.maxY
        guard yOverlap else { return nil }

        let rightDistance = abs(panelFrame.minX - ghosttyFrame.maxX)
        let leftDistance = abs(panelFrame.maxX - ghosttyFrame.minX)
        guard rightDistance <= threshold || leftDistance <= threshold else { return nil }
        return rightDistance <= leftDistance ? .right : .left
    }

    private func tickGhosttyFollow() {
        guard let panel = mainPanel, panel.isVisible else {
            stopGhosttyFollow()
            return
        }
        guard let currentGhosttyFrame = findGhosttyFrame() else {
            logGhosttyFollow("stop follow: ghostty frame unavailable", level: "warning")
            stopGhosttyFollow()
            return
        }
        let previousGhosttyFrame = lastGhosttyFrame
        let currentFrame = panel.frame
        let target = ghosttyAnchoredOrigin(
            for: currentGhosttyFrame,
            panelSize: currentFrame.size,
            preferredSide: ghosttyAnchorSide
        )
        let currentOrigin = currentFrame.origin

        if isGhosttySnapped {
            let detachDistance = hypot(currentOrigin.x - target.origin.x, currentOrigin.y - target.origin.y)
            let ghostMotion: CGFloat
            if let previousGhosttyFrame {
                ghostMotion = hypot(
                    currentGhosttyFrame.origin.x - previousGhosttyFrame.origin.x,
                    currentGhosttyFrame.origin.y - previousGhosttyFrame.origin.y
                )
            } else {
                ghostMotion = 0
            }
            if detachDistance >= 28 && ghostMotion < 2 {
                isGhosttySnapped = false
                ghosttyDetachCooldownUntil = Date().addingTimeInterval(0.45)
                lastGhosttyFrame = currentGhosttyFrame
                logGhosttyFollow("detached from Ghostty manually (distance=\(Int(detachDistance)))")
                return
            }

            ghosttyAnchorSide = target.side
            if detachDistance >= 1.0 {
                panel.setFrameOrigin(target.origin)
            }
        } else {
            if let cooldownEnd = ghosttyDetachCooldownUntil, Date() < cooldownEnd {
                lastGhosttyFrame = currentGhosttyFrame
                return
            }
            ghosttyDetachCooldownUntil = nil

            if let snapSide = detectSnapSide(panelFrame: currentFrame, ghosttyFrame: currentGhosttyFrame, threshold: 14) {
                ghosttyAnchorSide = snapSide
                let snapTarget = ghosttyAnchoredOrigin(
                    for: currentGhosttyFrame,
                    panelSize: currentFrame.size,
                    preferredSide: snapSide
                )
                panel.setFrameOrigin(snapTarget.origin)
                isGhosttySnapped = true
                ghosttyAnchorSide = snapTarget.side
                logGhosttyFollow("resnapped to Ghostty side=\(snapTarget.side)")
            }
        }

        lastGhosttyFrame = currentGhosttyFrame
    }

    private func positionPanelBelowStatusItem(_ panel: NSPanel) {
        let panelSize = panel.frame.size

        if let ghosttyFrame = findGhosttyFrame() {
            let placement = ghosttyAnchoredOrigin(for: ghosttyFrame, panelSize: panelSize, preferredSide: nil)
            panel.setFrameOrigin(placement.origin)
            ghosttyAnchorSide = placement.side
            isGhosttySnapped = true
            ghosttyDetachCooldownUntil = nil
            lastGhosttyFrame = ghosttyFrame
            logGhosttyFollow("opened near Ghostty origin=\(placement.origin) side=\(placement.side)")
            startGhosttyFollow()
            return
        }

        stopGhosttyFollow()
        logGhosttyFollow("Ghostty not found at open; using status-item placement", level: "warning")

        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let x = screenRect.midX - panelSize.width / 2
        let y = screenRect.minY - panelSize.height - 4
        panel.setFrameOrigin(clampPanelOrigin(CGPoint(x: x, y: y), panelSize: panelSize))
    }

    /// Called by AppRuntime after CCStatusBarClient updates sessions.
    func refreshSessionsMenu(sessions: [CCStatusBarClient.CCSession]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStatusIcon()
            let deduped = self.deduplicateByProject(sessions)
            let sorted = deduped.sorted {
                $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
            }
            self.panelModel.codexSessions = sorted.filter { $0.sessionType == "codex" }
            self.panelModel.claudeSessions = sorted.filter { $0.sessionType == "claude_code" }
            self.panelModel.sessionModes = self.runtime.configStore.load().tmuxSessionModes
        }
    }

    /// Deduplicate sessions by (sessionType, project): keep the most-active one.
    /// Priority: running (2) > waiting_input (1) > other (0)
    private func deduplicateByProject(
        _ sessions: [CCStatusBarClient.CCSession]
    ) -> [CCStatusBarClient.CCSession] {
        let priority = ["running": 2, "waiting_input": 1]
        var best: [String: CCStatusBarClient.CCSession] = [:]
        for session in sessions {
            let key = "\(session.sessionType):\(session.project)"
            if let existing = best[key] {
                let ep = priority[existing.status] ?? 0
                let np = priority[session.status] ?? 0
                if np > ep { best[key] = session }
            } else {
                best[key] = session
            }
        }
        return Array(best.values)
    }

    private func setSessionMode(sessionType: String, project: String, next: String) {
        let key = AppConfig.modeKey(sessionType: sessionType, project: project)
        var config = runtime.configStore.load()
        if next == "ignore" {
            config.tmuxSessionModes.removeValue(forKey: key)
        } else {
            config.tmuxSessionModes[key] = next
        }
        runtime.configStore.save(config)
        refreshSessionsMenu(sessions: runtime.allCCSessions())
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let mode = dominantSessionMode()
        let dotColor: NSColor
        switch mode {
        case "autonomous":
            dotColor = .systemRed
        case "auto":
            dotColor = .systemOrange
        case "observe":
            dotColor = .systemBlue
        default:
            dotColor = .systemGray
        }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = statusIconImage(dotColor: dotColor)
        button.imagePosition = .imageOnly
    }

    private func statusIconImage(dotColor: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let crabRect = NSRect(x: 1, y: 0, width: 16, height: 16)
        let crabStyle = NSMutableParagraphStyle()
        crabStyle.alignment = .center
        let crabAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .paragraphStyle: crabStyle,
        ]
        ("🦀" as NSString).draw(in: crabRect, withAttributes: crabAttributes)

        let badgeRect = NSRect(x: 13, y: 1, width: 8, height: 8)
        let badgePath = NSBezierPath(ovalIn: badgeRect)
        dotColor.setFill()
        badgePath.fill()
        NSColor.white.setStroke()
        badgePath.lineWidth = 1.0
        badgePath.stroke()

        image.isTemplate = false
        return image
    }

    private func dominantSessionMode() -> String {
        let modes = runtime.configStore.load().tmuxSessionModes.values
        if modes.contains("autonomous") { return "autonomous" }
        if modes.contains("auto") { return "auto" }
        if modes.contains("observe") { return "observe" }
        return "ignore"
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "ignore": return "Ignore"
        case "observe": return "Observe"
        case "auto": return "Auto"
        case "autonomous": return "Autonomous"
        default: return mode.capitalized
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    func refreshStatsAndTimeline() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelModel.autonomousStatus = self.runtime.autonomousStatusSummary()
            let entries = self.opsLogStore.recent(limit: self.mainPanelLogLimit)
            if entries.isEmpty {
                let now = Self.timeFormatter.string(from: Date())
                self.panelModel.logs = [
                    MainPanelLogLine(text: "\(now) • No recent logs", color: .logDim, event: ""),
                ]
                return
            }

            let rawLines = entries.map { entry in
                let t = Self.timeFormatter.string(from: entry.date)
                let style = self.compactLogStyle(for: entry)
                return MainPanelLogLine(text: "\(t) \(style.text)", color: style.color, event: entry.event)
            }
            self.panelModel.logs = deduplicateRuns(rawLines)
        }
    }

    /// Collapse consecutive runs of the same `event` into one line with "×N" suffix.
    /// Input is newest-first (as returned by opsLogStore.recent).
    private func deduplicateRuns(_ lines: [MainPanelLogLine]) -> [MainPanelLogLine] {
        var result: [MainPanelLogLine] = []
        var i = 0
        while i < lines.count {
            let current = lines[i]
            var runCount = 1
            // Count how many consecutive entries share the same event key
            while i + runCount < lines.count && lines[i + runCount].event == current.event && !current.event.isEmpty {
                runCount += 1
            }
            if runCount >= 2 {
                let collapsed = MainPanelLogLine(
                    text: current.text + " \u{00D7}\(runCount)",
                    color: current.color,
                    event: current.event
                )
                result.append(collapsed)
            } else {
                result.append(current)
            }
            i += runCount
        }
        return result
    }

    private func compactMessage(_ text: String, max: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        if single.count <= max { return single }
        return String(single.prefix(max)) + "..."
    }

    private func humanReadableSummary(for entry: OpsLogEntry) -> String {
        let fields = parseMessageFields(entry.message)
        let project = shortProject(fields.project)
        let bytes = fields.bytes.map { "\($0)b" } ?? "-b"
        let preview = compactMessage(fields.text, max: 32)

        switch entry.event {
        case "federation.connected":
            return "FED UP \(compactMessage(entry.message, max: 32))"
        case "federation.connecting":
            return "FED CONNECT \(compactMessage(entry.message, max: 28))"
        case "federation.closed":
            return "FED CLOSED \(compactMessage(entry.message, max: 24))"
        case "federation.receive_failed", "federation.send_failed", "federation.error":
            return "FED ERR \(compactMessage(entry.message, max: 28))"
        case "federation.disabled", "federation.invalid_url":
            return "FED OFF \(compactMessage(entry.message, max: 28))"
        case "tmux.completion":
            return "CAP DONE \(project) \(bytes) \(preview)"
        case "tmux.question":
            return "CAP Q \(project) \(bytes) \(preview)"
        case "tmux.progress":
            return "CAP PROG \(project) \(bytes) \(preview)"
        case "tmux.forward":
            return "FWD \(project) \(bytes) \(preview)"
        case "tmux_gateway_deliver":
            return "ACK \(project)"
        case "line_send_ok":
            return "MSG OUT OK"
        case "line_send_start":
            return "MSG SEND"
        case "send_failed":
            let parts = parseKeyValueMessage(entry.message)
            let code = parts["error_code"] ?? "unknown"
            let msg = compactMessage(parts["error_message"] ?? "", max: 32)
            return "ERR \(project) \(code) \(msg)"
        case "ingress_received":
            return "SRV IN"
        case "ingress_validated":
            return "SRV VALID"
        default:
            let fallback = compactMessage(entry.message, max: 40)
            if fallback.isEmpty {
                return entry.event
            }
            return "\(entry.event) \(fallback)"
        }
    }

    private struct ParsedMessageFields {
        let project: String?
        let bytes: Int?
        let text: String
    }

    private func parseMessageFields(_ message: String) -> ParsedMessageFields {
        let kv = parseKeyValueMessage(message)
        let project = kv["project"]
        let bytes = kv["bytes"].flatMap(Int.init)

        let text: String
        if let range = message.range(of: "text=") {
            text = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }
        return ParsedMessageFields(project: project, bytes: bytes, text: text)
    }

    private func parseKeyValueMessage(_ message: String) -> [String: String] {
        var result: [String: String] = [:]
        let tokens = message.split(separator: " ")
        for token in tokens {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            let value = String(token[token.index(after: eq)...])
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func shortProject(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "-" }
        return String(trimmed.prefix(16))
    }

    private func compactLogStyle(for entry: OpsLogEntry) -> (text: String, color: NSColor) {
        let text = humanReadableSummary(for: entry)
        switch entry.event {
        case "federation.connected":
            return (text, .systemGreen)
        case "federation.connecting":
            return (text, .systemBlue)
        case "federation.closed", "federation.receive_failed", "federation.send_failed", "federation.error":
            return (text, .systemRed)
        case "federation.disabled", "federation.invalid_url":
            return (text, .systemOrange)
        case "tmux.completion", "tmux.question", "tmux.progress":
            return (text, .logDefault)
        case "line_send_ok":
            return (text, .systemGreen)
        case "line_send_start":
            return (text, .systemBlue)
        case "tmux.forward":
            return (text, .systemBlue)
        case "tmux_gateway_deliver":
            return (text, .systemPurple)
        case "ingress_received", "ingress_validated":
            return (text, .systemPurple)
        case "send_failed", "decode_failed":
            return (text, .systemRed)
        default:
            if entry.level.lowercased() == "error" {
                return (text, .systemRed)
            }
            return (text, .logDefault)
        }
    }

    @objc private func quit() {
        closeMainPanel(nil)
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopGhosttyFollow()
        runtime.stopServer()
        NSApplication.shared.terminate(nil)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatsAndTimeline()
            self?.refreshSessionsMenu(sessions: self?.runtime.allCCSessions() ?? [])
        }
    }

    private func closeMainPanel(_ sender: Any?) {
        guard let panel = mainPanel, panel.isVisible else { return }
        stopGhosttyFollow()
        panel.orderOut(sender)
    }
}
