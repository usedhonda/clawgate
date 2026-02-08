import AppKit
import ApplicationServices
import Foundation

final class LINEInboundWatcher {
    private let eventBus: EventBus
    private let logger: AppLogger
    private let pollInterval: TimeInterval
    private let recentSendTracker: RecentSendTracker
    private var timer: Timer?
    private let bundleIdentifier = "jp.naver.line.mac"

    /// Snapshot of chat row frames from last poll (sorted by Y coordinate)
    private var lastRowSnapshot: [CGRect] = []
    private var lastRowCount: Int = 0

    /// Pixel-change detection state
    private var lastImageHash: UInt64 = 0
    private var lastOCRText: String = ""
    private var baselineCaptured: Bool = false

    init(eventBus: EventBus, logger: AppLogger, pollIntervalSeconds: Int, recentSendTracker: RecentSendTracker) {
        self.eventBus = eventBus
        self.logger = logger
        self.pollInterval = TimeInterval(pollIntervalSeconds)
        self.recentSendTracker = recentSendTracker
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        logger.log(.info, "LINEInboundWatcher started (interval: \(pollInterval)s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.log(.info, "LINEInboundWatcher stopped")
    }

    private func poll() {
        BlockingWork.queue.async { [weak self] in
            self?.doPoll()
        }
    }

    private func doPoll() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return
        }

        let appElement = AXQuery.applicationElement(pid: app.processIdentifier)

        // Try focused window first, fall back to first window (works when LINE is background)
        guard let window = AXQuery.focusedWindow(appElement: appElement)
            ?? AXQuery.windows(appElement: appElement).first else {
            return
        }

        let windowTitle = AXQuery.copyStringAttribute(window, attribute: kAXTitleAttribute as String)

        // Find chat area: the AXList that contains AXRow children (message bubbles)
        // The chat list is the one in the right pane with the most rows
        let nodes = AXQuery.descendants(of: window, maxDepth: 4, maxNodes: 200)
        guard let chatList = findChatList(in: nodes) else {
            return
        }

        // Get AXRow children of the chat list directly
        let rowChildren = AXQuery.children(of: chatList)
        let rowFrames: [CGRect] = rowChildren.compactMap { child in
            let role = AXQuery.copyStringAttribute(child, attribute: kAXRoleAttribute)
            guard role == "AXRow" else { return nil }
            return AXQuery.copyFrameAttribute(child)
        }.sorted { $0.origin.y < $1.origin.y }

        let currentCount = rowFrames.count
        guard currentCount > 0 else { return }

        let lastFrame = rowFrames.last!
        let previousCount = lastRowCount
        let previousFrames = lastRowSnapshot

        // Update snapshot
        lastRowSnapshot = rowFrames
        lastRowCount = currentCount

        // Skip first poll (baseline)
        guard previousCount > 0 else {
            logger.log(.debug, "LINEInboundWatcher: baseline captured (\(currentCount) rows)")
            return
        }

        // Detect changes:
        // 1. Row count increased → new message(s) arrived
        // 2. Last row position changed (scrolled) → new content
        let countChanged = currentCount != previousCount
        let bottomChanged: Bool
        if let prevLast = previousFrames.last {
            bottomChanged = Int(lastFrame.origin.y) != Int(prevLast.origin.y)
                || Int(lastFrame.size.height) != Int(prevLast.size.height)
        } else {
            bottomChanged = false
        }

        if countChanged || bottomChanged {
            let newRowCount = max(0, currentCount - previousCount)
            let conversation = windowTitle ?? ""

            // Determine new row frames (rows not present in previous snapshot)
            let newRowFrames: [CGRect]
            if currentCount > previousCount {
                newRowFrames = Array(rowFrames.suffix(currentCount - previousCount))
            } else {
                // Row count same or decreased but bottom changed — take last row
                newRowFrames = [lastFrame]
            }

            // Vision OCR: extract text from new rows (batch — single capture)
            let ocrText = VisionOCR.extractText(from: newRowFrames, padding: 4) ?? ""

            // Echo suppression: temporal window is the sole signal for now.
            // OCR text matching is not reliable enough because the watcher may read
            // adjacent rows (not the actual new message row), producing false negatives.
            let isEcho = recentSendTracker.isLikelyEcho()

            let eventType = isEcho ? "echo_message" : "inbound_message"

            _ = eventBus.append(
                type: eventType,
                adapter: "line",
                payload: [
                    "text": ocrText,
                    "conversation": conversation,
                    "row_count_delta": String(newRowCount),
                    "total_rows": String(currentCount),
                    "source": "poll",
                ]
            )
            logger.log(.debug, "LINEInboundWatcher: \(eventType) detected (rows: \(previousCount)->\(currentCount), bottomY: \(previousFrames.last?.origin.y ?? 0)->\(lastFrame.origin.y), ocr: \(ocrText.prefix(50)))")
        }

        // --- Pixel change detection (chat area only) ---
        guard let chatListFrame = AXQuery.copyFrameAttribute(chatList) else { return }

        // Hash only the bottom half of chat area (where new messages appear)
        let bottomHalf = CGRect(
            x: chatListFrame.origin.x,
            y: chatListFrame.origin.y + chatListFrame.height / 2,
            width: chatListFrame.width,
            height: chatListFrame.height / 2
        )
        guard let image = CGWindowListCreateImage(
            bottomHalf, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]
        ) else { return }

        let hash = computeImageHash(image)

        if !baselineCaptured {
            lastImageHash = hash
            lastOCRText = VisionOCR.extractText(from: chatListFrame) ?? ""
            baselineCaptured = true
            logger.log(.debug, "LINEInboundWatcher: pixel baseline captured (hash: \(hash))")
            return
        }

        guard hash != lastImageHash else { return }
        let previousHash = lastImageHash
        lastImageHash = hash

        // Pixels changed -> run OCR on chat list area (screen coordinates)
        // NOTE: AXRow frames are virtual scroll coordinates (y=-17000 etc),
        // NOT screen coordinates. Only chatListFrame has real screen position.
        let pixelOCRText = VisionOCR.extractText(from: chatListFrame) ?? ""
        guard pixelOCRText != lastOCRText else {
            logger.log(.debug, "LINEInboundWatcher: pixel hash changed (\(previousHash)->\(hash)) but OCR text unchanged")
            return
        }

        lastOCRText = pixelOCRText

        let isPixelEcho = recentSendTracker.isLikelyEcho()
        let pixelEventType = isPixelEcho ? "echo_message" : "inbound_message"

        _ = eventBus.append(
            type: pixelEventType,
            adapter: "line",
            payload: [
                "text": pixelOCRText,
                "conversation": windowTitle ?? "",
                "source": "pixel_diff",
            ]
        )
        logger.log(.debug, "LINEInboundWatcher: \(pixelEventType) via pixel_diff (hash: \(previousHash)->\(hash), ocr: \(pixelOCRText.prefix(80)))")
    }

    /// Downsample image to 32x32 and compute FNV-1a hash for fast change detection.
    private func computeImageHash(_ image: CGImage) -> UInt64 {
        let size = 32
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return 0 }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 14695981039346656037  // FNV offset basis
        for i in 0..<(size * size * 4) {
            hash ^= UInt64(bytes[i])
            hash &*= 1099511628211  // FNV prime
        }
        return hash
    }

    /// Find the chat message list element.
    /// Strategy: look for AXList nodes and pick the one with the most AXRow children
    /// that is positioned in the right portion of the window (chat area, not sidebar).
    private func findChatList(in nodes: [AXNode]) -> AXUIElement? {
        var bestList: AXUIElement?
        var bestRowCount = 0

        for node in nodes {
            guard node.role == "AXList" else { continue }

            // The chat list is typically in the right pane (x > midpoint)
            // Check if it has AXRow children
            let children = AXQuery.children(of: node.element)
            let rowCount = children.filter { child in
                AXQuery.copyStringAttribute(child, attribute: kAXRoleAttribute) == "AXRow"
            }.count

            if rowCount > bestRowCount {
                bestRowCount = rowCount
                bestList = node.element
            }
        }

        return bestList
    }
}
