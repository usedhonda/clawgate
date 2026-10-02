import AppKit
import ApplicationServices
import CoreImage
import CoreMedia
import CoreGraphics
import CryptoKit
import ScreenCaptureKit
import Vision

/// A single OCR line returned by the passive LINE observer.
public struct LineOCRRow: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case unknown
    }

    public let text: String
    /// Vision-normalized coordinates (origin at bottom-left of the window).
    public let box: LineObservationRect
    public let direction: Direction
    /// Deliberately nil: this observer does not parse or infer message times.
    public let confidence: Double?
    public let timestamp: Date?

    public init(text: String, box: LineObservationRect, direction: Direction = .unknown, timestamp: Date? = nil, confidence: Double? = nil) {
        self.text = text
        self.box = box
        self.direction = direction
        self.timestamp = timestamp
        self.confidence = confidence
    }
}

public struct LineObservationRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

public struct LineWindowObservation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sidebar
        case conversation
        case unknown
    }

    public enum Coverage: String, Codable, Sendable {
        case fullWindow
        case contentExcludingChrome
        case unavailable
    }

    public enum State: String, Codable, Sendable {
        case captured
        case screenRecordingDenied
        case lineNotRunning
        case noLineWindows
        case captureUnavailable
        case ocrUnavailable
        case unknownWindow
    }

    public let scope: String
    public let state: State
    public let kind: Kind
    public let coverage: Coverage
    public let windowID: UInt32?
    public let width: Int
    public let height: Int
    public let rows: [LineOCRRow]

    public init(scope: String = "line_window", state: State, kind: Kind, coverage: Coverage,
                windowID: UInt32?, width: Int, height: Int, rows: [LineOCRRow]) {
        self.scope = scope
        self.state = state
        self.kind = kind
        self.coverage = coverage
        self.windowID = windowID
        self.width = width
        self.height = height
        self.rows = rows
    }
}

/// Read-only, window-scoped LINE capture. It never activates, resizes, scrolls,
/// clicks, types into, or otherwise mutates a LINE window.
@MainActor
public final class LinePassiveCapture {
    private struct CachedRows {
        let fingerprint: SHA256.Digest
        let width: Int
        let height: Int
        let title: String?
        let kind: LineWindowObservation.Kind
        let bounds: CGRect
        let rows: [LineOCRRow]
    }

    private var cache: [UInt32: CachedRows] = [:]

    public init() {}

    public func capture() async -> [LineWindowObservation] {
        guard #available(macOS 12.3, *) else {
            return [Self.unavailable(.captureUnavailable)]
        }
        guard CGPreflightScreenCaptureAccess() else {
            return [Self.unavailable(.screenRecordingDenied)]
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return [Self.unavailable(.captureUnavailable)]
        }

        let windows = content.windows.filter { Self.isLINEWindow($0) && $0.windowLayer == 0 && $0.frame.width >= 180 && $0.frame.height >= 160 }
        let liveIDs = Set(windows.map(\.windowID))
        cache = cache.filter { liveIDs.contains($0.key) }
        guard !windows.isEmpty else {
            let hasLINEProcess = NSWorkspace.shared.runningApplications.contains {
                Self.isLINEApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName)
            }
            return [Self.unavailable(hasLINEProcess ? .noLineWindows : .lineNotRunning)]
        }

        var results: [LineWindowObservation] = []
        for window in windows {
            results.append(await capture(window: window))
        }
        return results
    }

    @available(macOS 12.3, *)
    private func capture(window: SCWindow) async -> LineWindowObservation {
        let width = max(0, Int(window.frame.width.rounded()))
        let height = max(0, Int(window.frame.height.rounded()))
        guard width > 0, height > 0 else {
            return LineWindowObservation(state: .captureUnavailable, kind: .unknown, coverage: .unavailable,
                                         windowID: window.windowID, width: width, height: height, rows: [])
        }

        guard let evidence = Self.readOnlyAXEvidence(for: window) else {
            return LineWindowObservation(state: .unknownWindow, kind: .unknown, coverage: .unavailable,
                                         windowID: window.windowID, width: width, height: height, rows: [])
        }

        guard let image = await captureImage(for: window, width: width, height: height) else {
            return LineWindowObservation(state: .captureUnavailable, kind: .unknown, coverage: .unavailable,
                                         windowID: window.windowID, width: width, height: height, rows: [])
        }
        guard Self.readOnlyAXEvidence(for: window)?.contentFrame == evidence.contentFrame else {
            return LineWindowObservation(state: .unknownWindow, kind: .unknown, coverage: .unavailable,
                                         windowID: window.windowID, width: width, height: height, rows: [])
        }
        let cropRect = Self.pixelCrop(content: evidence.contentFrame, window: window.frame, imageWidth: image.width, imageHeight: image.height)
        guard let cropped = image.cropping(to: cropRect), cropRect.width > 0, cropRect.height > 0 else {
            return LineWindowObservation(state: .unknownWindow, kind: .unknown, coverage: .unavailable,
                                         windowID: window.windowID, width: width, height: height, rows: [])
        }
        let fingerprint = Self.fingerprint(cropped)
        if let previous = cache[window.windowID], previous.fingerprint == fingerprint,
           previous.width == image.width, previous.height == image.height, previous.title == window.title, previous.bounds == evidence.contentFrame {
            let known = previous.kind != .unknown
            return LineWindowObservation(state: known ? .captured : .unknownWindow, kind: previous.kind,
                                         coverage: known ? .contentExcludingChrome : .unavailable,
                                         windowID: window.windowID, width: previous.width, height: previous.height, rows: previous.rows)
        }

        let rawRows: [(text: String, boundingBox: CGRect, confidence: Double)]
        do {
            rawRows = try await Task.detached(priority: .utility) { try Self.recognize(cropped) }.value
        } catch {
            return LineWindowObservation(state: .ocrUnavailable, kind: .unknown, coverage: .unavailable,
                                         windowID: window.windowID, width: width, height: height, rows: [])
        }
        let kind = evidence.kind
        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        let usable: [LineOCRRow] = rawRows.map { row -> LineOCRRow in
            let box = row.boundingBox
            let left: CGFloat = (cropRect.minX + box.minX * cropRect.width) / imageW
            let bottom: CGFloat = (imageH - cropRect.maxY + box.minY * cropRect.height) / imageH
            let mappedWidth: CGFloat = box.width * cropRect.width / imageW
            let mappedHeight: CGFloat = box.height * cropRect.height / imageH
            let full = CGRect(x: left, y: bottom, width: mappedWidth, height: mappedHeight)
            return LineOCRRow(text: row.text, box: LineObservationRect(full), confidence: row.confidence)
        }.sorted { lhs, rhs in
            abs(lhs.box.y - rhs.box.y) > 0.01 ? lhs.box.y > rhs.box.y : lhs.box.x < rhs.box.x
        }
        cache[window.windowID] = CachedRows(fingerprint: fingerprint, width: image.width, height: image.height,
                                            title: window.title,
                                            kind: kind, bounds: evidence.contentFrame, rows: usable)
        return LineWindowObservation(state: .captured, kind: kind, coverage: .contentExcludingChrome,
                                     windowID: window.windowID, width: image.width, height: image.height, rows: usable)
    }

    private static func unavailable(_ state: LineWindowObservation.State) -> LineWindowObservation {
        LineWindowObservation(state: state, kind: .unknown, coverage: .unavailable,
                              windowID: nil, width: 0, height: 0, rows: [])
    }

    @available(macOS 12.3, *)
    private static func isLINEWindow(_ window: SCWindow) -> Bool {
        isLINEApplication(bundleIdentifier: window.owningApplication?.bundleIdentifier,
                          name: window.owningApplication?.applicationName)
    }

    private static func isLINEApplication(bundleIdentifier: String?, name: String?) -> Bool {
        if bundleIdentifier?.lowercased() == "jp.naver.line.mac" { return true }
        return false
    }

    private struct AXEvidence {
        let kind: LineWindowObservation.Kind
        let contentFrame: CGRect
    }

    /// AX is used only as read-only semantic geometry. No actions, focus, or
    /// window attributes are written. Without structural evidence we fail closed.
    @available(macOS 12.3, *)
    private static func readOnlyAXEvidence(for window: SCWindow) -> AXEvidence? {
        guard AXIsProcessTrusted(), let pid = window.owningApplication?.processID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let matching = windows.filter { root in
            guard let frame = axFrame(root) else { return false }
            return abs(frame.minX - window.frame.minX) < 3 && abs(frame.minY - window.frame.minY) < 3 &&
                   abs(frame.width - window.frame.width) < 3 && abs(frame.height - window.frame.height) < 3
        }
        guard matching.count == 1, let root = matching.first else { return nil }
        var roles: [(String, CGRect)] = []
        collectAX(root, into: &roles, depth: 0)
        let composers = roles.filter { $0.0 == "AXTextArea" }.map(\.1)
        let searches = roles.filter { $0.0 == "AXTextField" || $0.0 == "AXSearchField" }.map(\.1)
        let lists = roles.filter { ["AXList", "AXTable", "AXOutline", "AXScrollArea"].contains($0.0) }.map(\.1)
        let kind = Self.structuralKind(hasList: !lists.isEmpty, hasSearch: !searches.isEmpty, hasComposer: !composers.isEmpty)
        guard kind != .unknown else { return nil }
        let exclusions = composers + searches
        guard let contentFrame = Self.safeContentFrame(lists: lists, excluded: exclusions, window: window.frame) else { return nil }
        return AXEvidence(kind: kind, contentFrame: contentFrame)
    }

    nonisolated static func structuralKind(hasList: Bool, hasSearch: Bool, hasComposer: Bool) -> LineWindowObservation.Kind {
        guard hasList else { return .unknown }
        if hasComposer { return .conversation }
        return hasSearch ? .sidebar : .unknown
    }

    nonisolated static func safeContentFrame(lists: [CGRect], excluded: [CGRect], window: CGRect) -> CGRect? {
        lists.filter { frame in
            frame.width >= 100 && frame.height >= 80 && window.contains(frame) &&
            !excluded.contains { frame.intersects($0) }
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// AX uses global top-left points; CGImage cropping uses window-relative top-left pixels.
    nonisolated static func pixelCrop(content: CGRect, window: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let scaleX = CGFloat(imageWidth) / window.width
        let scaleY = CGFloat(imageHeight) / window.height
        let left = ceil((content.minX-window.minX)*scaleX)
        let top = ceil((content.minY-window.minY)*scaleY)
        let right = floor((content.maxX-window.minX)*scaleX)
        let bottom = floor((content.maxY-window.minY)*scaleY)
        return CGRect(x: left, y: top, width: max(0,right-left), height: max(0,bottom-top))
            .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }

    private static func collectAX(_ element: AXUIElement, into roles: inout [(String, CGRect)], depth: Int) {
        guard depth < 8, roles.count < 600 else { return }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String, let frame = axFrame(element) {
            roles.append((role, frame))
            // The content container geometry is enough; do not walk virtualized
            // history rows or read any editable values just to locate a crop.
            if ["AXList", "AXTable", "AXOutline", "AXTextArea", "AXTextField", "AXSearchField"].contains(role) { return }
        }
        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
              let children = childValue as? [AXUIElement] else { return }
        for child in children { collectAX(child, into: &roles, depth: depth + 1) }
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    nonisolated private static func recognize(_ image: CGImage) throws -> [(text: String, boundingBox: CGRect, confidence: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox, Double(candidate.confidence))
        }
    }

    /// Pixel fingerprint only; image bytes are not retained or written.
    private static func fingerprint(_ image: CGImage) -> SHA256.Digest {
        guard let provider = image.dataProvider, let data = provider.data as Data? else {
            return SHA256.hash(data: Data("\(image.width)x\(image.height)".utf8))
        }
        var bytes = Data()
        bytes.reserveCapacity(16 + data.count)
        bytes.append(contentsOf: withUnsafeBytes(of: UInt64(image.width).bigEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: UInt64(image.height).bigEndian, Array.init))
        bytes.append(data)
        return SHA256.hash(data: bytes)
    }

    @available(macOS 12.3, *)
    private func captureImage(for window: SCWindow, width: Int, height: Int) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        if #available(macOS 13.0, *) { configuration.capturesAudio = false }
        if #available(macOS 14.0, *) {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                return nil
            }
        }
        return await StreamOneFrame.capture(filter: filter, configuration: configuration)
    }
}

@available(macOS 12.3, *)
private final class StreamOneFrame: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<CGImage?, Never>
    private let lock = NSLock()
    private var finished = false
    private var stream: SCStream?

    private init(continuation: CheckedContinuation<CGImage?, Never>) {
        self.continuation = continuation
    }

    static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let worker = StreamOneFrame(continuation: continuation)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: worker)
            worker.stream = stream
            worker.start(stream: stream)
        }
    }

    private func start(stream: SCStream) {
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "clawgate.line.passive"))
            stream.startCapture { [weak self, weak stream] error in
                if error != nil { self?.finish(nil, stream: stream) }
            }
            // A denied or unsupported stream may never deliver a frame. Bound
            // the fallback so capture() cannot leave an async continuation open.
            Task { [self, stream] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.finish(nil, stream: stream)
            }
        } catch {
            finish(nil, stream: stream)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent)
        finish(image, stream: stream)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(nil, stream: stream)
    }

    private func finish(_ image: CGImage?, stream: SCStream?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        stream?.stopCapture { _ in }
        self.stream = nil
        continuation.resume(returning: image)
    }
}
