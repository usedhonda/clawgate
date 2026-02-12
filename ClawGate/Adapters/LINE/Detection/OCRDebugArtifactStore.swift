import AppKit
import Foundation

enum OCRDebugArtifactStore {
    private static let queue = DispatchQueue(label: "com.clawgate.ocr-debug-store")
    private static let rootURL = URL(fileURLWithPath: "/tmp/clawgate-ocr-debug", isDirectory: true)

    static func saveEvent(
        eventID: String,
        raw: CGImage?,
        anchor: CGImage?,
        preprocessed: CGImage?,
        metadata: [String: String],
        retention: Int = 50
    ) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

                let eventURL = rootURL.appendingPathComponent(eventID, isDirectory: true)
                try? FileManager.default.removeItem(at: eventURL)
                try FileManager.default.createDirectory(at: eventURL, withIntermediateDirectories: true)

                if let raw { writePNG(raw, to: eventURL.appendingPathComponent("raw.png")) }
                if let anchor { writePNG(anchor, to: eventURL.appendingPathComponent("anchor.png")) }
                if let preprocessed { writePNG(preprocessed, to: eventURL.appendingPathComponent("preprocessed.png")) }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(metadata)
                try data.write(to: eventURL.appendingPathComponent("meta.json"), options: [.atomic])

                prune(retention: retention)
            } catch {
                // Best-effort debug store. Never fail runtime pipeline.
            }
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func prune(retention: Int) {
        guard retention > 0 else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = entries.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lDate > rDate
        }

        if sorted.count <= retention { return }
        for old in sorted.dropFirst(retention) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
