import AppKit
import Combine
import SwiftUI

private extension NSColor {
    /// Bright light-gray for default log text — always readable on a dark panel background.
    static let logDefault = NSColor(white: 0.82, alpha: 1.0)
    /// Dimmer gray for "no logs" placeholder text.
    static let logDim = NSColor(white: 0.55, alpha: 1.0)
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum GhosttyAnchorSide {
        case right
        case left
    }

    private var statusItem: NSStatusItem?
    private var mainPanel: NSPanel?
    private var mainPanelHost: NSHostingController<MainPanelView>?
    private var refreshTimer: Timer?
    private var ghosttyFollowTimer: DispatchSourceTimer?
    private var lastGhosttyFrame: CGRect?
    private var isGhosttySnapped = false
    private var ghosttyDetachCooldownUntil: Date?
    private var ghosttyAnchorSide: GhosttyAnchorSide = .right
    private var ghosttyLastDebugLogAt: Date = .distantPast
    private var suspendDriftDetection = false
    private var driftWatchdogGeneration: UInt64 = 0

    // Snap constants (Tproj parity)
    private let snapThreshold: CGFloat = 12
    private let snapGap: CGFloat = 2
    private let snapDetachThreshold: CGFloat = 24   // snapThreshold * 2
    private let snapDetachCooldown: TimeInterval = 0.4
    private let snapYAlignThreshold: CGFloat = 100

    private var isCollapsed = false
    private var normalPanelWidth: CGFloat = 220
    private var normalPanelOrigin: NSPoint = .zero
    private static let collapsedWidth: CGFloat = 14
    private var activationObserver: NSObjectProtocol?
    private var petVisibilityObserver: AnyCancellable?
    private var lastAppliedPanelLevel: NSWindow.Level?
    private let mainPanelLogLimit = 30
    private let ghosttyBundleID = "com.mitchellh.ghostty"

    private let modeOrder: [String] = ["ignore", "observe", "auto", "autonomous"]

    private let runtime: AppRuntime
    private let statsCollector: StatsCollector
    private let opsLogStore: OpsLogStore
    private let settingsModel: SettingsModel
    private let panelModel = MainPanelModel()
    private let petModel = PetModel()
    private var petWindowController: PetWindowController?

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

        // Start pet character.
        // Honor persisted isVisible so that turning the avatar off in Settings
        // survives app restarts. Pet bookkeeping (start()) still runs so that
        // toggling the avatar back on works without a restart.
        petWindowController = PetWindowController(model: petModel)
        petModel.start()
        if petModel.isVisible {
            petWindowController?.show()
        }
        // React to Settings toggle at runtime so users can hide/show the pet
        // without restarting the app.
        petVisibilityObserver = petModel.$isVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.petWindowController?.show()
                } else {
                    self.petWindowController?.hide()
                }
            }
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        button.target = self
        button.action = #selector(toggleMainPanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func showStatusItemMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit ClawGate", action: #selector(quit), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear menu so left-click goes back to toggle action
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    private func configureMainPanel() {
        let view = MainPanelView(
            settingsModel: settingsModel,
            panelModel: panelModel,
            petModel: petModel,
            modeOrder: modeOrder,
            onSetSessionMode: { [weak self] sessionType, project, mode in
                self?.setSessionMode(sessionType: sessionType, project: project, next: mode)
            },
            onToggleCollapse: { [weak self] in
                self?.toggleCollapse()
            },
            logLimit: mainPanelLogLimit
        )
        let host = NSHostingController(rootView: view)
        mainPanelHost = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 600),
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

        // Restore saved width only; position is determined at open time
        if let rect = Self.loadSavedFrame(), rect.width >= panel.minSize.width {
            normalPanelWidth = rect.width
        }

        mainPanel = panel
        startFrameObserver(panel)
        applyMainPanelLevel(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func startFrameObserver(_ panel: NSPanel) {
        panel.delegate = self
    }

    private static let frameFile: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clawgate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("panel-frame.txt")
    }()

    private func saveCurrentFrame() {
        guard let panel = mainPanel, !isCollapsed, !isGhosttySnapped else { return }
        let frame = panel.frame
        guard frame.width >= panel.minSize.width else { return }
        try? NSStringFromRect(frame).write(to: Self.frameFile, atomically: true, encoding: .utf8)
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let str = try? String(contentsOf: frameFile, encoding: .utf8) else { return nil }
        let rect = NSRectFromString(str)
        guard rect.width > 0 && rect.height > 0 else { return nil }
        return rect
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

    private func capabilityRoleLabel() -> String {
        let cfg = runtime.configStore.load()
        return "line=\(cfg.lineEnabled) tmux=true remote=true"
    }

    @objc private func toggleMainPanel(_ sender: Any?) {
        // Right-click → show context menu with Quit
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusItemMenu()
            return
        }

        guard let panel = mainPanel else { return }

        if panel.isVisible {
            closeMainPanel(sender)
            return
        }

        // Menu bar icon open should always start from expanded mode.
        prepareExpandedPanelForOpen(panel)
        settingsModel.reload()
        refreshSessionsMenu(sessions: runtime.allCCSessions())
        refreshStatsAndTimeline()

        // Ghostty visible → always snap to Ghostty (Tproj parity).
        // Saved frame is only used when Ghostty is absent.
        if let ghosttyFrame = findGhosttyFrame() {
            // Restore saved width if available
            if let saved = Self.loadSavedFrame(), saved.width >= panel.minSize.width {
                normalPanelWidth = saved.width
                var frame = panel.frame
                frame.size.width = normalPanelWidth
                panel.setFrame(frame, display: false)
            }
            let placement = ghosttyAnchoredOrigin(for: ghosttyFrame, panelSize: panel.frame.size, preferredSide: nil)
            panel.setFrameOrigin(placement.origin)
            ghosttyAnchorSide = placement.side
            isGhosttySnapped = true
            ghosttyDetachCooldownUntil = nil
            lastGhosttyFrame = ghosttyFrame
            logGhosttyFollow("opened near Ghostty origin=\(placement.origin) side=\(placement.side)")
        } else if let saved = Self.loadSavedFrame(),
                  saved.width >= panel.minSize.width, saved.height >= panel.minSize.height,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            panel.setFrame(saved, display: true)
            normalPanelWidth = saved.width
        } else {
            fitPanelToContent(panel)
            positionPanelBelowStatusItem(panel)
        }

        startGhosttyFollow()
        updateGhosttyFollowInterval()
        applyMainPanelLevel(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        panel.makeKeyAndOrderFront(nil)
    }

    private func prepareExpandedPanelForOpen(_ panel: NSPanel) {
        guard isCollapsed else { return }

        isCollapsed = false
        panelModel.isCollapsed = false
        isCollapseAnimating = false
        suspendDriftDetection = false

        panel.minSize = NSSize(width: 200, height: panel.minSize.height)
        setTrafficLightsHidden(false)
        panel.isMovable = true
        panel.isMovableByWindowBackground = true

        let targetWidth = min(max(normalPanelWidth, panel.minSize.width), panel.maxSize.width)
        if abs(panel.frame.width - targetWidth) > 0.5 {
            var frame = panel.frame
            frame.size.width = targetWidth
            panel.setFrame(frame, display: false)
        }
    }

    private func shouldDebugGhosttyFollow() -> Bool {
        runtime.configStore.load().debugLogging
    }

    private func logGhosttyFollow(_ message: String, level: String = "debug") {
        guard shouldDebugGhosttyFollow() else { return }
        let role = capabilityRoleLabel()
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

    private func visibleUnionFrame() -> CGRect? {
        let frames = NSScreen.screens.map(\.visibleFrame)
        guard var union = frames.first else { return nil }
        for frame in frames.dropFirst() { union = union.union(frame) }
        return union
    }

    private func clampPanelOrigin(_ origin: CGPoint, panelSize: CGSize, margin: CGFloat = 8) -> CGPoint {
        guard let union = visibleUnionFrame() else { return origin }
        let maxX = max(union.minX, union.maxX - panelSize.width - margin)
        let maxY = max(union.minY, union.maxY - panelSize.height - margin)
        return CGPoint(
            x: min(max(origin.x, union.minX + margin), maxX),
            y: min(max(origin.y, union.minY + margin), maxY)
        )
    }

    private func ghosttyAnchoredOrigin(
        for ghosttyFrame: CGRect,
        panelSize: CGSize,
        preferredSide: GhosttyAnchorSide?
    ) -> (origin: CGPoint, side: GhosttyAnchorSide) {
        let gap = snapGap
        let candidateScreen = NSScreen.screens.first(where: { $0.frame.intersects(ghosttyFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = candidateScreen?.visibleFrame

        let rightX = ghosttyFrame.maxX + gap
        let leftX = ghosttyFrame.minX - panelSize.width - gap
        let y = ghosttyFrame.maxY - panelSize.height  // always top-align

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
        ghosttyFollowTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.tickGhosttyFollow()
        }
        timer.resume()
        ghosttyFollowTimer = timer
    }

    private func stopGhosttyFollow() {
        ghosttyFollowTimer?.cancel()
        ghosttyFollowTimer = nil
        lastGhosttyFrame = nil
        isGhosttySnapped = false
        ghosttyDetachCooldownUntil = nil
        ghosttyAnchorSide = .right
    }

    private func updateGhosttyFollowInterval() {
        guard let timer = ghosttyFollowTimer else { return }
        let ms: Int
        if isGhosttySnapped {
            ms = 16      // 60 fps - smooth follow
        } else if lastGhosttyFrame != nil {
            ms = 100     // Ghostty visible - snap detection
        } else {
            ms = 500     // Ghostty absent - minimal resource
        }
        timer.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
    }

    private func detectSnapSide(panelFrame: CGRect, ghosttyFrame: CGRect, threshold: CGFloat) -> GhosttyAnchorSide? {
        let yOverlap = panelFrame.maxY > ghosttyFrame.minY && panelFrame.minY < ghosttyFrame.maxY
        guard yOverlap else { return nil }

        let rightDistance = abs(panelFrame.minX - ghosttyFrame.maxX)
        let leftDistance = abs(panelFrame.maxX - ghosttyFrame.minX)
        guard rightDistance <= threshold || leftDistance <= threshold else { return nil }
        return rightDistance <= leftDistance ? .right : .left
    }

    /// Suspend drift detection with a 1.0s watchdog that forces it back to false.
    /// Prevents permanent suspension if animation completion is dropped.
    private func suspendDriftWithWatchdog() {
        suspendDriftDetection = true
        driftWatchdogGeneration &+= 1
        let gen = driftWatchdogGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.driftWatchdogGeneration == gen, self.suspendDriftDetection else { return }
            self.suspendDriftDetection = false
            self.logGhosttyFollow("drift watchdog fired — forced suspendDriftDetection=false", level: "warning")
        }
    }

    private func updateSnapOffset() {
        guard let panel = mainPanel, let ghosttyFrame = findGhosttyFrame(), isGhosttySnapped else { return }
        lastGhosttyFrame = ghosttyFrame
        let target = ghosttyAnchoredOrigin(for: ghosttyFrame, panelSize: panel.frame.size, preferredSide: ghosttyAnchorSide)
        let topGap = abs(panel.frame.maxY - ghosttyFrame.maxY)
        let followOrigin = (topGap <= snapYAlignThreshold)
            ? target.origin
            : CGPoint(x: target.origin.x, y: panel.frame.origin.y)
        panel.setFrameOrigin(followOrigin)
        ghosttyAnchorSide = target.side
    }

    private func tickGhosttyFollow() {
        guard let panel = mainPanel, panel.isVisible else {
            stopGhosttyFollow()
            return
        }
        guard let currentGhosttyFrame = findGhosttyFrame() else {
            let changed = isGhosttySnapped || lastGhosttyFrame != nil
            if isGhosttySnapped { isGhosttySnapped = false }
            lastGhosttyFrame = nil
            if changed { updateGhosttyFollowInterval() }
            return
        }

        let prevSnapped = isGhosttySnapped
        let previousGhosttyFrame = lastGhosttyFrame
        let currentFrame = panel.frame
        let target = ghosttyAnchoredOrigin(
            for: currentGhosttyFrame,
            panelSize: currentFrame.size,
            preferredSide: ghosttyAnchorSide
        )
        let currentOrigin = currentFrame.origin

        if isGhosttySnapped {
            if suspendDriftDetection {
                lastGhosttyFrame = currentGhosttyFrame
                return
            }

            // Detach by X-only (Y movement never triggers detach)
            let xDrift = abs(currentOrigin.x - target.origin.x)
            let ghostMotion: CGFloat
            if let previousGhosttyFrame {
                ghostMotion = hypot(
                    currentGhosttyFrame.origin.x - previousGhosttyFrame.origin.x,
                    currentGhosttyFrame.origin.y - previousGhosttyFrame.origin.y
                )
            } else {
                ghostMotion = 0
            }
            if xDrift >= snapDetachThreshold && ghostMotion < 2 {
                isGhosttySnapped = false
                ghosttyDetachCooldownUntil = Date().addingTimeInterval(snapDetachCooldown)
                lastGhosttyFrame = currentGhosttyFrame
                logGhosttyFollow("detached from Ghostty manually (distance=\(Int(xDrift)))")
                if isGhosttySnapped != prevSnapped { updateGhosttyFollowInterval() }
                return
            }

            ghosttyAnchorSide = target.side
            let topGap = abs(currentFrame.maxY - currentGhosttyFrame.maxY)
            let snapY = (topGap <= snapYAlignThreshold) ? target.origin.y : currentOrigin.y
            let followOrigin = CGPoint(x: target.origin.x, y: snapY)
            if abs(currentOrigin.x - followOrigin.x) >= 0.5 || abs(currentOrigin.y - followOrigin.y) >= 0.5 {
                panel.setFrameOrigin(followOrigin)
            }
        } else {
            if let cooldownEnd = ghosttyDetachCooldownUntil, Date() < cooldownEnd {
                lastGhosttyFrame = currentGhosttyFrame
                return
            }
            ghosttyDetachCooldownUntil = nil

            if let snapSide = detectSnapSide(panelFrame: currentFrame, ghosttyFrame: currentGhosttyFrame, threshold: snapThreshold) {
                ghosttyAnchorSide = snapSide
                let snapTarget = ghosttyAnchoredOrigin(
                    for: currentGhosttyFrame,
                    panelSize: currentFrame.size,
                    preferredSide: snapSide
                )
                let topGap = abs(currentFrame.maxY - currentGhosttyFrame.maxY)
                let snapOrigin = (topGap <= snapYAlignThreshold)
                    ? snapTarget.origin
                    : CGPoint(x: snapTarget.origin.x, y: currentFrame.origin.y)
                panel.setFrameOrigin(snapOrigin)
                isGhosttySnapped = true
                ghosttyAnchorSide = snapTarget.side
                logGhosttyFollow("resnapped to Ghostty side=\(snapTarget.side)")
            }
        }

        lastGhosttyFrame = currentGhosttyFrame
        if isGhosttySnapped != prevSnapped {
            updateGhosttyFollowInterval()
        }
    }

    // MARK: - Collapse / Expand

    private func shouldAnchorLeft() -> Bool {
        guard let panel = mainPanel, let ghostty = findGhosttyFrame() else { return false }
        return abs(panel.frame.minX - ghostty.maxX) < abs(panel.frame.maxX - ghostty.minX)
    }

    private func setTrafficLightsHidden(_ hidden: Bool) {
        guard let panel = mainPanel else { return }
        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(buttonType)?.isHidden = hidden
        }
    }

    func toggleCollapse() {
        if isCollapsed {
            expandPanel()
        } else {
            collapsePanel()
        }
    }

    private var isCollapseAnimating = false

    private func collapsePanel() {
        guard let panel = mainPanel, !isCollapseAnimating else { return }
        isCollapseAnimating = true
        normalPanelWidth = panel.frame.width
        normalPanelOrigin = panel.frame.origin
        suspendDriftWithWatchdog()

        let targetWidth = Self.collapsedWidth
        panel.minSize = NSSize(width: targetWidth, height: panel.minSize.height)

        let ghostty = findGhosttyFrame()
        let anchorLeft = shouldAnchorLeft()

        let newX: CGFloat
        if let g = ghostty {
            newX = anchorLeft ? g.maxX : g.minX - targetWidth
        } else {
            newX = anchorLeft ? panel.frame.origin.x : panel.frame.maxX - targetWidth
        }
        let newY: CGFloat
        if let g = ghostty {
            let topGap = abs(panel.frame.maxY - g.maxY)
            newY = (topGap <= 100) ? g.maxY - panel.frame.height : panel.frame.origin.y
        } else {
            newY = panel.frame.origin.y
        }

        // Switch to CollapsedBarView BEFORE animation so SwiftUI's minWidth:200 doesn't fight the shrink
        isCollapsed = true
        panelModel.isCollapsed = true
        setTrafficLightsHidden(true)
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let newFrame = NSRect(origin: NSPoint(x: newX, y: newY),
                                  size: NSSize(width: targetWidth, height: panel.frame.height))
            panel.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.updateSnapOffset()
                self?.suspendDriftDetection = false
                self?.isCollapseAnimating = false
            }
        })
    }

    private func expandPanel() {
        guard let panel = mainPanel, !isCollapseAnimating else { return }
        isCollapseAnimating = true
        suspendDriftWithWatchdog()

        let targetWidth = normalPanelWidth

        if normalPanelOrigin == .zero, let g = findGhosttyFrame() {
            let topGap = abs(panel.frame.maxY - g.maxY)
            let fallbackY: CGFloat = (topGap <= 100)
                ? g.maxY - panel.frame.height
                : panel.frame.origin.y
            normalPanelOrigin = NSPoint(x: g.minX - targetWidth, y: fallbackY)
        }

        setTrafficLightsHidden(false)
        panel.isMovable = true
        panel.isMovableByWindowBackground = true

        let expandOrigin: NSPoint
        if isGhosttySnapped, let g = findGhosttyFrame() {
            let target = ghosttyAnchoredOrigin(for: g, panelSize: NSSize(width: targetWidth, height: panel.frame.height), preferredSide: ghosttyAnchorSide)
            let topGap = abs(panel.frame.maxY - g.maxY)
            expandOrigin = (topGap <= 100) ? target.origin : NSPoint(x: target.origin.x, y: panel.frame.origin.y)
        } else {
            expandOrigin = normalPanelOrigin
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let newFrame = NSRect(origin: expandOrigin,
                                  size: NSSize(width: targetWidth, height: panel.frame.height))
            panel.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                panel.minSize = NSSize(width: 200, height: panel.minSize.height)
                self?.updateSnapOffset()
                self?.suspendDriftDetection = false
                self?.isCollapsed = false
                self?.panelModel.isCollapsed = false
                self?.isCollapseAnimating = false
            }
        })
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

        logGhosttyFollow("Ghostty not found at open; using status-item placement", level: "warning")

        // Check if current panel position is visible on any screen
        let currentFrame = panel.frame
        let isCurrentVisible = NSScreen.screens.map { $0.visibleFrame }.contains { screen in
            currentFrame.intersects(screen.insetBy(dx: -40, dy: -40))
        }

        if !isCurrentVisible || currentFrame.origin == .zero {
            // Fallback: position below status item
            guard let button = statusItem?.button, let buttonWindow = button.window else { return }
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            let x = screenRect.midX - panelSize.width / 2
            let y = screenRect.minY - panelSize.height - 4
            panel.setFrameOrigin(clampPanelOrigin(CGPoint(x: x, y: y), panelSize: panelSize))
        }

        // Start follow timer even without Ghostty so we auto-snap when it appears
        startGhosttyFollow()
        updateGhosttyFollowInterval()
    }

    /// Called by AppRuntime after CCStatusBarClient updates sessions.
    func refreshSessionsMenu(sessions: [SessionSnapshot]) {
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
        _ sessions: [SessionSnapshot]
    ) -> [SessionSnapshot] {
        let priority = ["running": 2, "waiting_input": 1]
        var best: [String: SessionSnapshot] = [:]
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

        // Draw the claw that Chi wears — the same red lobster claw as in
        // the desktop pet's hide-claw sprite. Loaded from bundle.
        let clawRect = NSRect(x: 1, y: 0, width: 16, height: 16)
        if let clawURL = Bundle.module.url(forResource: "menubar-claw@2x", withExtension: "png"),
           let clawImage = NSImage(contentsOf: clawURL) {
            clawImage.draw(in: clawRect,
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1.0)
        } else {
            // Fallback: lobster emoji if the bundled image is missing
            let fallbackStyle = NSMutableParagraphStyle()
            fallbackStyle.alignment = .center
            ("🦞" as NSString).draw(in: clawRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .paragraphStyle: fallbackStyle,
            ])
        }

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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    func refreshStatsAndTimeline() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
            self?.saveCurrentFrame()
        }
    }

    func windowDidMove(_ notification: Notification) { saveCurrentFrame() }
    func windowDidResize(_ notification: Notification) { saveCurrentFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveCurrentFrame() }
    func windowWillClose(_ notification: Notification) { saveCurrentFrame() }

    private func closeMainPanel(_ sender: Any?) {
        guard let panel = mainPanel, panel.isVisible else { return }
        saveCurrentFrame()
        stopGhosttyFollow()
        panel.orderOut(sender)
    }
}
