import AppKit
import CryptoKit
import Dispatch
import Foundation

enum ScreenshotSourceKind: String {
    case clipboardImage = "clipboard_image"
    case savedFile = "saved_file"
}

enum ScreenshotAction {
    case copyMention
}

struct ScreenshotOffer: Identifiable {
    let id: String
    let sourceKind: ScreenshotSourceKind
    let originalPath: String?
    let tempPath: String
    let mentionText: String
    let capturedAt: Date
    let pixelSize: CGSize
    let sourceApp: String?
    let fingerprint: ScreenshotFingerprint
}

struct ScreenshotFingerprint: Equatable {
    let width: Int
    let height: Int
    let sha256Prefix: String
}

private struct ScreenshotCandidate {
    let sourceKind: ScreenshotSourceKind
    let originalPath: String?
    let tempPath: String
    let mentionText: String
    let capturedAt: Date
    let pixelSize: CGSize
    let fingerprint: ScreenshotFingerprint
}

struct ScreenshotFileClassifier {
    private static let nameHints = [
        "screen shot",
        "screenshot",
        "スクリーンショット",
    ]

    private static let folderHints = [
        "screenshots",
        "screen shots",
        "スクリーンショット",
    ]

    static func looksLikeScreenshot(filename: String, directoryName: String) -> Bool {
        let lowerName = filename.lowercased()
        let lowerDir = directoryName.lowercased()
        if folderHints.contains(where: { lowerDir.contains($0) }) {
            return true
        }
        return nameHints.contains(where: { lowerName.contains($0) })
    }
}

struct ScreenshotSaveLocationResolver {
    static func resolve(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }
}

struct ScreenshotTempStore {
    private static let canonicalTempURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    private static let currentPrefix = "chi-shot-"

    static func makeTempURL(now: Date = Date()) -> URL {
        _ = now
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return canonicalTempURL
            .appendingPathComponent("\(currentPrefix)\(suffix).png")
    }

    static func pruneOldFiles(olderThan: TimeInterval = 24 * 60 * 60) {
        let tmpURL = canonicalTempURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-olderThan)
        for url in entries where url.lastPathComponent.hasPrefix(currentPrefix) && url.pathExtension.lowercased() == "png" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    var onScreenshot: ((ScreenshotOffer) -> Void)?

    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount: Int
    private var suppressUntil: Date?

    private var watchedDirectoryURL: URL?
    private var watchedDirectoryFD: CInt = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private let directoryQueue = DispatchQueue(label: "com.clawgate.screenshot-watcher")
    private var knownFiles: [String: Date] = [:]
    private var rescanScheduled = false

    private var lastEmittedFingerprint: ScreenshotFingerprint?
    private var lastEmittedAt: Date?
    private let dedupWindow: TimeInterval = 2.0

    private init() {
        lastClipboardChangeCount = NSPasteboard.general.changeCount
    }

    private var directoryWatchStarted = false

    func start() {
        stop()
        ScreenshotTempStore.pruneOldFiles()
        startClipboardPolling()
        // Directory watch deferred until first clipboard image detected
        // to avoid Desktop access prompt on every launch
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        directorySource?.cancel()
        directorySource = nil
        if watchedDirectoryFD >= 0 {
            close(watchedDirectoryFD)
            watchedDirectoryFD = -1
        }
        watchedDirectoryURL = nil
        knownFiles.removeAll()
        rescanScheduled = false
    }

    func suppress(for duration: TimeInterval = 2.0) {
        suppressUntil = Date().addingTimeInterval(duration)
    }

    private func startClipboardPolling() {
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = current

        if let until = suppressUntil, Date() < until { return }
        guard let image = NSImage(pasteboard: pasteboard) else { return }

        // Lazily start directory watch on first clipboard image
        if !directoryWatchStarted {
            directoryWatchStarted = true
            configureDirectoryWatch()
        }

        emitCandidate(from: image, sourceKind: .clipboardImage, originalPath: nil)
    }

    private func configureDirectoryWatch() {
        let directory = ScreenshotSaveLocationResolver.resolve()
        watchedDirectoryURL = directory
        seedKnownFiles(in: directory)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("[ScreenshotWatcher] could not watch directory: %@", directory.path)
            return
        }
        watchedDirectoryFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .attrib],
            queue: directoryQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRescan()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        directorySource = source
        source.resume()
    }

    private func seedKnownFiles(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            knownFiles.removeAll()
            return
        }
        knownFiles = Dictionary(uniqueKeysWithValues: entries.map { url in
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url.path, modifiedAt)
        })
    }

    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        directoryQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.rescanScheduled = false
            self.rescanDirectory()
        }
    }

    private func rescanDirectory() {
        guard let directory = watchedDirectoryURL else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        let directoryName = directory.lastPathComponent
        let imageExtensions = Set(["png", "jpg", "jpeg", "tiff", "heic", "heif"])

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey])
            guard values?.isRegularFile == true else { continue }

            let modifiedAt = values?.contentModificationDate ?? .distantPast
            if let known = knownFiles[url.path], known >= modifiedAt {
                continue
            }
            knownFiles[url.path] = modifiedAt

            let createdAt = values?.creationDate ?? modifiedAt
            guard now.timeIntervalSince(createdAt) <= 5 else { continue }
            guard ScreenshotFileClassifier.looksLikeScreenshot(
                filename: url.lastPathComponent,
                directoryName: directoryName
            ) else { continue }
            guard let image = NSImage(contentsOf: url) else { continue }
            emitCandidate(from: image, sourceKind: .savedFile, originalPath: url.path, capturedAt: createdAt)
        }
    }

    private func emitCandidate(
        from image: NSImage,
        sourceKind: ScreenshotSourceKind,
        originalPath: String?,
        capturedAt: Date = Date()
    ) {
        guard let normalized = normalizedPNGData(from: image),
              let pixelSize = pixelSize(for: normalized.image) else { return }
        guard pixelSize.width >= 100, pixelSize.height >= 100 else { return }

        let fingerprint = ScreenshotFingerprint(
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            sha256Prefix: sha256Prefix(for: normalized.pngData)
        )
        if shouldSuppress(fingerprint: fingerprint, capturedAt: capturedAt) {
            return
        }

        let tempURL = ScreenshotTempStore.makeTempURL(now: capturedAt)
        do {
            try normalized.pngData.write(to: tempURL, options: .atomic)
        } catch {
            NSLog("[ScreenshotWatcher] failed to write temp screenshot: %@", String(describing: error))
            return
        }

        let candidate = ScreenshotCandidate(
            sourceKind: sourceKind,
            originalPath: originalPath,
            tempPath: tempURL.path,
            mentionText: "@\(tempURL.path)",
            capturedAt: capturedAt,
            pixelSize: pixelSize,
            fingerprint: fingerprint
        )
        markEmitted(fingerprint: fingerprint, capturedAt: capturedAt)
        onScreenshot?(ScreenshotOffer(
            id: UUID().uuidString,
            sourceKind: candidate.sourceKind,
            originalPath: candidate.originalPath,
            tempPath: candidate.tempPath,
            mentionText: candidate.mentionText,
            capturedAt: candidate.capturedAt,
            pixelSize: candidate.pixelSize,
            sourceApp: nil,
            fingerprint: candidate.fingerprint
        ))
    }

    private func shouldSuppress(fingerprint: ScreenshotFingerprint, capturedAt: Date) -> Bool {
        guard let lastFingerprint = lastEmittedFingerprint, let lastEmittedAt else { return false }
        return lastFingerprint == fingerprint && capturedAt.timeIntervalSince(lastEmittedAt) <= dedupWindow
    }

    private func markEmitted(fingerprint: ScreenshotFingerprint, capturedAt: Date) {
        lastEmittedFingerprint = fingerprint
        lastEmittedAt = capturedAt
    }

    private func normalizedPNGData(from image: NSImage) -> (image: NSImage, pngData: Data)? {
        let targetImage = image
        guard let tiffData = targetImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return (targetImage, pngData)
    }

    private func pixelSize(for image: NSImage) -> CGSize? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        if let rep = image.representations.first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return nil
    }

    private func sha256Prefix(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
