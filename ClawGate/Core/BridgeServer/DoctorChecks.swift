import AppKit
import Foundation

/// Builds the ordered list of health checks for /v1/doctor. Extracted from
/// BridgeCore (ES-03) so the probe logic lives in one cohesive unit; BridgeCore.doctor()
/// remains the thin entry that wraps these checks in a DoctorReport. The check names,
/// order, status strings ("ok"/"warning"/"error"), and message text form a public API
/// surface consumed by ops tooling — do not change them.
struct DoctorChecks {
    let core: BridgeCore

    func buildChecks() -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let cfg = core.configStore.load()
        let lineEnabled = cfg.lineEnabled

        // Check 1: App signature authority (avoid TCC re-prompt churn)
        checks.append(appSignatureCheck())

        // Check 2: Accessibility permission
        let axTrusted = AXIsProcessTrusted()
        checks.append(DoctorCheck(
            name: "accessibility_permission",
            status: axTrusted ? "ok" : "error",
            message: axTrusted ? "Accessibility permission is granted" : "Accessibility permission is not granted",
            details: axTrusted ? nil : "System Settings > Privacy & Security > Accessibility"
        ))

        // Check 3: Messenger (LINE adapter) running
        let lineRunning = lineEnabled && (NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first != nil)
        checks.append(DoctorCheck(
            name: "line_running",
            status: lineEnabled ? (lineRunning ? "ok" : "warning") : "ok",
            message: lineEnabled ? (lineRunning ? "Messenger app (LINE) is running" : "Messenger app (LINE) is not running") : "Messenger checks disabled",
            details: lineEnabled ? (lineRunning ? nil : "Please launch LINE") : "Enable Messenger (LINE) in Settings when needed"
        ))

        // Check 4: LINE inbound watcher freshness
        checks.append(lineWatcherFreshnessCheck(lineEnabled: lineEnabled, lineRunning: lineRunning))

        // Check 4b: LINE inbound flow (poll loop stopped detection)
        checks.append(lineInboundFlowCheck(lineEnabled: lineEnabled, lineRunning: lineRunning))

        // Check 5: LINE inbound dedup suppression health
        checks.append(lineInboundDedupHealthCheck(lineEnabled: lineEnabled, lineRunning: lineRunning))

        // Check 6: LINE caretaker state
        checks.append(lineCaretakerStateCheck(lineEnabled: lineEnabled, lineRunning: lineRunning))

        // Check 7: LINE window accessible (only if LINE is running and AX is trusted)
        if lineEnabled && axTrusted && lineRunning {
            let windowCheck = checkLINEWindowAccessible()
            checks.append(windowCheck)
        } else {
            checks.append(DoctorCheck(
                name: "line_window_accessible",
                status: lineEnabled ? "warning" : "ok",
                message: "Messenger window check skipped (LINE adapter)",
                details: lineEnabled ? (!axTrusted ? "Accessibility permission required" : "LINE app is not running") : "lineEnabled=false"
            ))
        }

        // Check 7b: LINE outbound surface health (abnormal => sends fail; today's outage class)
        checks.append(lineSurfaceHealthCheck(lineEnabled: lineEnabled, lineRunning: lineRunning))

        // Check 8: Port 8765 (we're already listening, so this is informational)
        let portDetails = "0.0.0.0:\(BridgeServer.defaultPort) (remote access)"
        let federationSuffix = cfg.federationEnabled ? " + ws:/federation" : ""
        checks.append(DoctorCheck(
            name: "server_port",
            status: "ok",
            message: "Server is listening on port \(BridgeServer.defaultPort)",
            details: portDetails + federationSuffix
        ))

        // Check 9: Screen Recording permission (for Vision OCR)
        let screenOk = CGPreflightScreenCaptureAccess()
        checks.append(DoctorCheck(
            name: "screen_recording_permission",
            status: screenOk ? "ok" : "warning",
            message: screenOk ? "Screen recording permission granted" : "Screen recording not granted (OCR disabled)",
            details: screenOk ? nil : "System Settings > Privacy > Screen Recording"
        ))

        // Check 10: Federation status
        if cfg.federationEnabled && cfg.federationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clientCount = core.federationServer?.clientCount() ?? 0
            checks.append(DoctorCheck(
                name: "federation",
                status: "ok",
                message: "Federation server active (\(clientCount) client\(clientCount == 1 ? "" : "s") connected)",
                details: "Accepting connections on /federation"
            ))
        } else if cfg.federationEnabled {
            checks.append(DoctorCheck(
                name: "federation",
                status: "ok",
                message: "Federation client enabled",
                details: "Connecting to \(cfg.federationURL)"
            ))
        }

        // Check 11a: TmuxDirectPoller freshness — detects silent-stuck mode where the
        // ClawGate process is alive (pgrep + /v1/health pass) but the tmux session
        // poller stops running. Covers the 2026-05-23 failure mode that pgrep-based
        // watchdogs miss. See .local/plans/2026-05-28-clawgate-recurrence-prevention.md.
        if let poller = core.tmuxDirectPoller {
            let stale: TimeInterval = max(90, poller.configuredPollInterval * 4.5)
            let sessionCount = poller.observedSessionCount
            let diagnostics = poller.diagnosticsSnapshot
            let diagnosticsDetails = "rawPaneCount=\(diagnostics.rawPaneCount) builtSessionCount=\(diagnostics.builtSessionCount)"
            if let last = poller.lastSuccessfulPollAt {
                let pollAge = Date().timeIntervalSince(last)
                if pollAge > stale {
                    checks.append(DoctorCheck(
                        name: "tmux_session_discovery",
                        status: "error",
                        message: "TmuxDirectPoller stuck",
                        details: "lastSuccessfulPoll age=\(Int(pollAge))s sessions=\(sessionCount) threshold=\(Int(stale))s \(diagnosticsDetails)"
                    ))
                } else {
                    checks.append(DoctorCheck(
                        name: "tmux_session_discovery",
                        status: "ok",
                        message: "TmuxDirectPoller fresh",
                        details: "lastSuccessfulPoll age=\(Int(pollAge))s sessions=\(sessionCount) \(diagnosticsDetails)"
                    ))
                }
            } else {
                checks.append(DoctorCheck(
                    name: "tmux_session_discovery",
                    status: "warning",
                    message: "TmuxDirectPoller has not yet completed a poll",
                    details: "sessions=\(sessionCount) \(diagnosticsDetails)"
                ))
            }
        }

        // Check 11b: EventBus activity — informational. Long idle period after
        // earlier activity hints at upstream stuck. Pure idle (no events ever) is
        // expected for some adapter mixes and is reported as ok.
        if let lastAppend = core.eventBus.lastAppendAt {
            let appendAge = Date().timeIntervalSince(lastAppend)
            let activityStale: TimeInterval = 1800
            if appendAge > activityStale {
                checks.append(DoctorCheck(
                    name: "eventbus_activity",
                    status: "warning",
                    message: "EventBus inactive since last seen",
                    details: "lastAppend age=\(Int(appendAge))s threshold=\(Int(activityStale))s"
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "eventbus_activity",
                    status: "ok",
                    message: "EventBus active",
                    details: "lastAppend age=\(Int(appendAge))s"
                ))
            }
        } else {
            checks.append(DoctorCheck(
                name: "eventbus_activity",
                status: "ok",
                message: "EventBus idle (no events appended yet)",
                details: nil
            ))
        }

        // Check 11: Gateway poll freshness — Gateway is expected to poll this host.
        let age = Date().timeIntervalSince(core.lastGatewayPollAt)
        let staleThreshold: TimeInterval = 120
        if core.lastGatewayPollAt == .distantPast {
            checks.append(DoctorCheck(
                name: "gateway_poll_freshness",
                status: "warning",
                message: "Gateway has never polled",
                details: "No /v1/poll requests received"
            ))
        } else if age > staleThreshold {
            checks.append(DoctorCheck(
                name: "gateway_poll_freshness",
                status: "error",
                message: "Gateway poll is stale",
                details: "age=\(Int(age))s threshold=\(Int(staleThreshold))s"
            ))
        } else {
            checks.append(DoctorCheck(
                name: "gateway_poll_freshness",
                status: "ok",
                message: "Gateway poll is fresh",
                details: "age=\(Int(age))s"
            ))
        }

        // Check 11c: Ambient capture liveness — detects the silent wedge where
        // the AVAudioEngine stops delivering buffers but captureState still says
        // "capturing" (pgrep + /v1/health both miss it; 2026-06-21 cost 80min of
        // lost recording). Keyed on tap-staleness, which is silence-safe: the tap
        // fires even in a quiet room, so it only goes stale when the engine dies —
        // never on empty transcripts (a quiet room correctly produces none).
        if let ambient = core.ambientController, ambient.isAvailable {
            let s = ambient.snapshot()
            if !s.streaming {
                checks.append(DoctorCheck(
                    name: "ambient_capture_liveness",
                    status: "ok",
                    message: "Ambient not streaming",
                    details: "captureState=\(s.captureState)"
                ))
            } else if s.captureLiveness == "wedged" {
                checks.append(DoctorCheck(
                    name: "ambient_capture_liveness",
                    status: "error",
                    message: "Ambient capture wedged (engine stopped delivering audio)",
                    details: "secondsSinceLastTap=\(s.secondsSinceLastTap)s chunksSurfaced=\(s.chunksSurfaced) recoveryCount=\(s.recoveryCount)"
                ))
            } else if s.captureLiveness == "stale" {
                checks.append(DoctorCheck(
                    name: "ambient_capture_liveness",
                    status: "warning",
                    message: "Ambient capture tap stale",
                    details: "secondsSinceLastTap=\(s.secondsSinceLastTap)s chunksSurfaced=\(s.chunksSurfaced)"
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "ambient_capture_liveness",
                    status: "ok",
                    message: "Ambient capture live",
                    details: "captureLiveness=\(s.captureLiveness) secondsSinceLastTap=\(s.secondsSinceLastTap)s chunksSurfaced=\(s.chunksSurfaced)"
                ))
            }
        }

        return checks
    }

    // MARK: - Individual checks

    private func checkLINEWindowAccessible() -> DoctorCheck {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "jp.naver.line.mac").first else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "Messenger app (LINE) is not running",
                details: nil
            )
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)
        guard let window = AXQuery.focusedWindow(appElement: appElement) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "Messenger window (LINE) not accessible (bring it to foreground)",
                details: "Qt limitation: AX tree unavailable in background"
            )
        }

        guard let _ = AXQuery.copyFrameAttribute(window) else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "Could not retrieve window frame",
                details: nil
            )
        }

        let nodes = AXQuery.descendants(of: window)
        let hasInput = nodes.contains { $0.role == "AXTextArea" }

        if hasInput {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "ok",
                message: "Messenger window (LINE) is accessible (input field present)",
                details: "Node count: \(nodes.count)"
            )
        } else {
            return DoctorCheck(
                name: "line_window_accessible",
                status: "warning",
                message: "Messenger window (LINE) is in sidebar view — thread not open (input field missing)",
                details: "Node count: \(nodes.count). LINE inbound watcher cannot scrape messages until a conversation thread is open."
            )
        }
    }

    private func appSignatureCheck() -> DoctorCheck {
        let appPath = Bundle.main.bundlePath
        guard let output = runProcess(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", appPath]) else {
            return DoctorCheck(
                name: "app_signature",
                status: "warning",
                message: "Could not verify app signature",
                details: "codesign output unavailable"
            )
        }

        let authorities = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let prefix = "Authority="
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }

        // Accept either the legacy self-signed "ClawGate Dev" cert OR an Apple
        // Developer ID Application cert. The Developer ID path gives stable TCC
        // binding across rebuilds (Team ID + Bundle ID) and is preferred.
        let hasDeveloperID = authorities.contains { $0.hasPrefix("Developer ID Application") }
        let hasClawGateDev = authorities.contains("ClawGate Dev")
        if hasDeveloperID || hasClawGateDev {
            let authorityLabel = hasDeveloperID
                ? (authorities.first { $0.hasPrefix("Developer ID Application") } ?? "Developer ID Application")
                : "ClawGate Dev"
            return DoctorCheck(
                name: "app_signature",
                status: "ok",
                message: "App signature authority is \(authorityLabel)",
                details: nil
            )
        }

        let detail = authorities.first.map { "Current authority: \($0)" } ?? "No authority found in signature"
        return DoctorCheck(
            name: "app_signature",
            status: "error",
            message: "App is not signed with ClawGate Dev or Developer ID Application",
            details: detail
        )
    }

    private func lineWatcherFreshnessCheck(lineEnabled: Bool, lineRunning: Bool) -> DoctorCheck {
        guard lineEnabled else {
            return DoctorCheck(
                name: "line_inbound_watcher_freshness",
                status: "ok",
                message: "LINE watcher freshness check skipped",
                details: "lineEnabled=false"
            )
        }
        guard lineRunning else {
            return DoctorCheck(
                name: "line_inbound_watcher_freshness",
                status: "ok",
                message: "LINE watcher freshness check skipped",
                details: "LINE is not running"
            )
        }
        let snapshot = core.lineInboundWatcher?.snapshotState() ?? core.defaultLineWatcherSnapshot()
        guard let lastCompleted = core.parseISODate(snapshot.lastCompletedPollAt) else {
            return DoctorCheck(
                name: "line_inbound_watcher_freshness",
                status: "warning",
                message: "LINE watcher has not completed a poll yet",
                details: "isPolling=\(snapshot.isPolling) skipped=\(snapshot.skippedPollCount)"
            )
        }
        let ageSeconds = Int(max(0, Date().timeIntervalSince(lastCompleted)))
        let status = ageSeconds > 60 ? "warning" : "ok"
        let message = status == "ok"
            ? "LINE watcher freshness is healthy"
            : "LINE watcher freshness is stale"
        let details = "age_seconds=\(ageSeconds) isPolling=\(snapshot.isPolling) timeouts=\(snapshot.consecutiveTimeouts) skipped=\(snapshot.skippedPollCount)"
        return DoctorCheck(name: "line_inbound_watcher_freshness", status: status, message: message, details: details)
    }

    private func lineInboundDedupHealthCheck(lineEnabled: Bool, lineRunning: Bool) -> DoctorCheck {
        guard lineEnabled else {
            return DoctorCheck(
                name: "line_inbound_dedup_health",
                status: "ok",
                message: "LINE inbound dedup health check skipped",
                details: "lineEnabled=false"
            )
        }
        guard lineRunning else {
            return DoctorCheck(
                name: "line_inbound_dedup_health",
                status: "ok",
                message: "LINE inbound dedup health check skipped",
                details: "LINE is not running"
            )
        }

        let metrics = core.lineInboundWatcher?.dedupSnapshot().suppressionMetrics ?? .empty
        // recent5minCount >= 3 (LineHealthCaretaker.Constants.dedupDegradedThreshold5min)
        // means the inbound pipeline is repeatedly suppressing/re-reading — surface the
        // "繰り返し読んでしまう" degradation as an error, not just a warning.
        let status: String
        if metrics.recent5minCount <= 1 {
            status = "ok"
        } else if metrics.recent5minCount < 3 {
            status = "warning"
        } else {
            status = "error"
        }
        let message: String
        if metrics.recent5minCount <= 1 {
            message = "LINE inbound dedup suppression is healthy"
        } else if metrics.recent5minCount <= 5 {
            message = "Dedup pipeline has suppressed \(metrics.recent5minCount) primary events in the last 5 minutes"
        } else {
            message = "Dedup pipeline is repeatedly suppressing primary evidence without positioned lines"
        }
        let details = [
            "recent5min_count=\(metrics.recent5minCount)",
            "recent60min_count=\(metrics.recent60minCount)",
            "last_at=\(metrics.lastAt)",
            "last_primary_reason=\(metrics.lastPrimaryReason)",
            "recent5min_primary_reasons=\(formatReasonCounts(metrics.recent5minPrimaryReasons))",
            "recent60min_primary_reasons=\(formatReasonCounts(metrics.recent60minPrimaryReasons))"
        ].joined(separator: " ")
        return DoctorCheck(name: "line_inbound_dedup_health", status: status, message: message, details: details)
    }

    private func formatReasonCounts(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    private func lineCaretakerStateCheck(lineEnabled: Bool, lineRunning: Bool) -> DoctorCheck {
        guard lineEnabled else {
            return DoctorCheck(
                name: "line_caretaker_state",
                status: "ok",
                message: "LINE caretaker check skipped",
                details: "lineEnabled=false"
            )
        }
        let snapshot = core.lineHealthCaretaker?.snapshot() ?? core.defaultLineCaretakerSnapshot()
        if !lineRunning {
            return DoctorCheck(
                name: "line_caretaker_state",
                status: "ok",
                message: "LINE caretaker is idle",
                details: "assessment=\(snapshot.lastAssessmentReason)"
            )
        }
        if snapshot.lastRepairSucceeded == false,
           let cooldownUntil = core.parseISODate(snapshot.cooldownUntil),
           cooldownUntil > Date() {
            return DoctorCheck(
                name: "line_caretaker_state",
                status: "warning",
                message: "LINE caretaker recently failed to repair the surface",
                details: "assessment=\(snapshot.lastAssessmentReason) repair_reason=\(snapshot.lastRepairReason)"
            )
        }
        return DoctorCheck(
            name: "line_caretaker_state",
            status: "ok",
            message: "LINE caretaker is healthy",
            details: "assessment=\(snapshot.lastAssessmentReason) next_forced=\(snapshot.nextForcedRepairDueAt)"
        )
    }

    /// Surface the LINE outbound send surface health directly. Reads the caretaker's
    /// cached lastSurface (refreshed every tick) rather than doing a live AX probe, to
    /// avoid doctor() causing AX churn. abnormal=true means sends will fail — this is
    /// the signal that was available but un-escalated during the 2026-06-07 outage
    /// (reason=message_input_missing).
    private func lineSurfaceHealthCheck(lineEnabled: Bool, lineRunning: Bool) -> DoctorCheck {
        guard lineEnabled else {
            return DoctorCheck(name: "line_surface_health", status: "ok", message: "LINE surface health check skipped", details: "lineEnabled=false")
        }
        guard lineRunning else {
            return DoctorCheck(name: "line_surface_health", status: "ok", message: "LINE surface health check skipped", details: "LINE is not running")
        }
        let snapshot = core.lineHealthCaretaker?.snapshot() ?? core.defaultLineCaretakerSnapshot()
        guard let surface = snapshot.lastSurface else {
            return DoctorCheck(name: "line_surface_health", status: "warning", message: "LINE outbound surface not probed yet", details: "assessment=\(snapshot.lastAssessmentReason)")
        }
        let details = "abnormal=\(surface.abnormal) reason=\(surface.reason) has_message_input=\(surface.hasMessageInput) matches_expected=\(surface.matchesExpectedConversation) probed_at=\(surface.timestamp)"
        if surface.abnormal {
            return DoctorCheck(name: "line_surface_health", status: "error", message: "LINE outbound surface is abnormal (sends will fail)", details: details)
        }
        return DoctorCheck(name: "line_surface_health", status: "ok", message: "LINE outbound surface is healthy", details: details)
    }

    /// Detect a stopped inbound poll loop. Note: a stale lastAcceptedAt alone is NOT an
    /// error — it just means no one has sent a message recently (normal). Only a poll
    /// loop that is not running AND has not completed a poll recently is a real fault.
    private func lineInboundFlowCheck(lineEnabled: Bool, lineRunning: Bool) -> DoctorCheck {
        guard lineEnabled else {
            return DoctorCheck(name: "line_inbound_flow", status: "ok", message: "LINE inbound flow check skipped", details: "lineEnabled=false")
        }
        guard lineRunning else {
            return DoctorCheck(name: "line_inbound_flow", status: "ok", message: "LINE inbound flow check skipped", details: "LINE is not running")
        }
        let snapshot = core.lineInboundWatcher?.snapshotState() ?? core.defaultLineWatcherSnapshot()
        let pollAge = core.parseISODate(snapshot.lastCompletedPollAt).map { Int(max(0, Date().timeIntervalSince($0))) }
        let details = "poll_age=\(pollAge.map(String.init) ?? "never") last_accepted=\(snapshot.lastAcceptedAt) is_polling=\(snapshot.isPolling) timeouts=\(snapshot.consecutiveTimeouts)"
        if !snapshot.isPolling, (pollAge ?? Int.max) > 90 {
            return DoctorCheck(name: "line_inbound_flow", status: "error", message: "LINE inbound poll loop appears stopped", details: details)
        }
        return DoctorCheck(name: "line_inbound_flow", status: "ok", message: "LINE inbound flow is active", details: details)
    }

    // MARK: - Shared helpers (doctor-only, moved verbatim from BridgeCore)

    private func runProcess(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = [out, err].joined(separator: "\n")
        return merged.isEmpty ? nil : merged
    }
}
