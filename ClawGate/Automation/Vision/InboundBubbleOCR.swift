import AppKit
import CryptoKit
import Vision

/// Recognition cache stores pixels and text, never delivery/seen state.
enum InboundBubbleOCR {
    struct Observation {
        let text: String
        /// Vision-normalized coordinates in the original, uncropped image.
        let boundingBox: CGRect
    }

    struct Result {
        let observations: [Observation]
        let bubbleCount: Int
        let recognizedPixels: Int
        let cacheHits: Int
    }

    private struct Crop {
        let rect: CGRect
        let image: CGImage
        let pixels: Data
        let hash: SHA256.Digest
    }

    private struct Entry {
        let scope: String
        let configuration: String
        let width: Int
        let height: Int
        let pixels: Data
        let hash: SHA256.Digest
        let observations: [Observation]
    }

    private static let lock = NSLock()
    private static var entries: [Entry] = []
    private static let visionDiagnosticLock = NSLock()
    private static var recentVisionDiagnostics: [String: Date] = [:]
    private static let visionDiagnosticInterval: TimeInterval = 60
    private static let maxVisionDiagnosticKeys = 64
    private static let visionDiagnosticArtifactURL = URL(fileURLWithPath: "/tmp/clawgate-ocr-debug/latest-vision-error.json")

    /// Keep only a bounded, body-free summary of nested Vision errors. Some
    /// NSError userInfo values contain image/text payloads, so never serialize
    /// anything other than the domain/code pair from NSUnderlyingErrorKey.
    /// Exposed internally for a focused contract test; values remain domain/code only.
    static func diagnosticUnderlyingErrorMetadata(_ error: NSError) -> [[String: Any]] {
        var metadata: [[String: Any]] = []
        var current: NSError? = error
        var seenKeys: Set<String> = []
        var inspected = 0
        while let item = current, inspected < 32, metadata.count < 4 {
            inspected += 1
            let key = "\(item.domain)|\(item.code)"
            if seenKeys.insert(key).inserted {
                if item !== error {
                    metadata.append(["domain": item.domain, "code": item.code])
                }
            }
            let nested = item.userInfo[NSUnderlyingErrorKey]
            current = (nested as? NSError) ?? (nested as? Error).map { $0 as NSError }
        }
        return metadata
    }

    /// Write only the bounded JSON diagnostic. The parent directory is created
    /// lazily so a fresh Mac mini still gets the artifact without changing the
    /// OCR pipeline when the best-effort write fails.
    static func writeVisionDiagnosticArtifact(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    static func clearCache() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static func logVisionFailure(_ error: Error, image: CGImage, revision: Int) {
        let nsError = error as NSError
        let key = "\(nsError.domain)|\(nsError.code)|\(image.width)x\(image.height)|\(revision)"
        let now = Date()
        visionDiagnosticLock.lock()
        let shouldLog = recentVisionDiagnostics[key].map { now.timeIntervalSince($0) >= visionDiagnosticInterval } ?? true
        if shouldLog {
            recentVisionDiagnostics[key] = now
            if recentVisionDiagnostics.count > maxVisionDiagnosticKeys,
               let oldestKey = recentVisionDiagnostics.min(by: { $0.value < $1.value })?.key {
                recentVisionDiagnostics.removeValue(forKey: oldestKey)
            }
        }
        visionDiagnosticLock.unlock()
        guard shouldLog else { return }
        let artifact: [String: Any] = [
            "domain": nsError.domain,
            "code": nsError.code,
            "width": image.width,
            "height": image.height,
            "actualRevision": revision,
            "timestamp": ISO8601DateFormatter().string(from: now),
            "underlyingErrors": diagnosticUnderlyingErrorMetadata(nsError)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys]) {
            do {
                try writeVisionDiagnosticArtifact(data, to: visionDiagnosticArtifactURL)
            } catch {
                let writeError = error as NSError
                NSLog("[InboundBubbleOCR] vision diagnostic artifact write failed domain=\(writeError.domain) code=\(writeError.code)")
            }
        }
        NSLog("[InboundBubbleOCR] vision request failed domain=\(nsError.domain) code=\(nsError.code) atlas=\(image.width)x\(image.height) revision=\(revision)")
    }

    /// Window titles can be just "LINE"; the chat header also namespaces reuse.
    static func contextFingerprint(_ image: CGImage, rect: CGRect) -> String? {
        guard rect.width > 0, rect.height > 0, let crop = crops(in: image, rects: [rect])?.first else { return nil }
        return crop.hash.description
    }

    private static func crops(in image: CGImage, rects: [CGRect]) -> [Crop]? {
        var result: [Crop] = []
        for rect in rects {
            guard let crop = image.cropping(to: rect),
                  let context = CGContext(data: nil, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            guard let normalized = context.makeImage(), let bytes = context.data else { return nil }
            let pixels = Data(bytes: bytes, count: crop.width * crop.height * 4)
            let hash = SHA256.hash(data: pixels)
            result.append(Crop(rect: rect, image: normalized, pixels: pixels, hash: hash))
        }
        return result
    }

    /// White gutters prevent cross-bubble lines; normalized boxes preserve source mapping.
    private static func atlas(_ crops: [Crop]) -> (image: CGImage, placements: [CGRect])? {
        guard !crops.isEmpty else { return nil }
        let gutter = 12
        let expandedWidth = max(128, (crops.map { $0.image.width * 2 }.max() ?? 0) + gutter * 2)
        let expandedHeight = max(128, crops.reduce(gutter) { $0 + $1.image.height * 2 + gutter })
        let expansionFits = expandedWidth <= (16 * 1024 * 1024 / 4) / expandedHeight
        let scale = expansionFits && crops.contains { $0.image.width < 64 && $0.image.height < 48 } ? 2 : 1
        let width = max(128, (crops.map { $0.image.width * scale }.max() ?? 0) + gutter * 2)
        let height = max(128, crops.reduce(gutter) { $0 + $1.image.height * scale + gutter })
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var placements: [CGRect] = []
        var top = gutter
        for crop in crops {
            let rect = CGRect(x: gutter, y: top, width: crop.image.width * scale, height: crop.image.height * scale)
            placements.append(rect)
            context.draw(crop.image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY,
                width: rect.width, height: rect.height))
            top += crop.image.height * scale + gutter
        }
        guard let output = context.makeImage() else { return nil }
        return (output, placements)
    }

    static func preview(_ image: CGImage) -> (image: CGImage?, overlay: CGImage?, status: String, rects: String) {
        let detection = InboundBubbleDetector.detect(in: image)
        let prepared = crops(in: image, rects: detection.rects)
        let output = prepared.flatMap(atlas)?.image
        let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context?.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.setLineWidth(2)
        for rect in detection.rects {
            context?.stroke(CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY,
                width: rect.width, height: rect.height))
        }
        return (output, context?.makeImage(), String(describing: detection.status),
            detection.rects.map { NSStringFromRect($0) }.joined(separator: ";"))
    }

    /// Why `recognize` gave up. A nil with no recorded reason used to be
    /// indistinguishable from a quiet room, so a stuck recogniser could drop
    /// every new bubble for days without leaving a trace.
    enum RecognizeFailure: String {
        case detectorUncertain = "detector_uncertain"
        case cropFailed = "crop_failed"
        case atlasFailed = "atlas_failed"
        case visionError = "vision_error"
        case visionNoResults = "vision_no_results"
        case incompleteRecognition = "incomplete_recognition"
    }

    /// One Vision text observation, detached from VNRecognizedTextObservation so
    /// the out-of-process helper can hand it back as JSON.
    struct RawObservation: Codable {
        struct Candidate: Codable {
            let text: String
            let confidence: Float
        }
        /// Vision-normalized box in the recognized image.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let candidates: [Candidate]
    }

    enum RawVisionError: Error {
        case noResults
    }

    private static func makeRequest(_ config: VisionOCR.OCRConfig) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = config.usesLanguageCorrection
        // A long atlas must not silently raise the minimum message font size.
        request.minimumTextHeight = 0
        if #available(macOS 14, *), config.revision >= 3 {
            request.revision = VNRecognizeTextRequestRevision3
        } else if #available(macOS 13, *), config.revision >= 2 {
            request.revision = VNRecognizeTextRequestRevision2
        }
        return request
    }

    private static func requestedRevision(_ config: VisionOCR.OCRConfig) -> Int {
        makeRequest(config).revision
    }

    static func performVision(on image: CGImage, config: VisionOCR.OCRConfig) throws -> [RawObservation] {
        let request = makeRequest(config)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let results = request.results else { throw RawVisionError.noResults }
        return results.map { observation in
            let box = observation.boundingBox
            return RawObservation(x: box.minX, y: box.minY, width: box.width, height: box.height,
                candidates: observation.topCandidates(config.candidateCount).map {
                    RawObservation.Candidate(text: $0.string, confidence: $0.confidence)
                })
        }
    }

    /// Maps atlas observations back to their bubbles, sorted top to bottom.
    static func assign(_ raw: [RawObservation], placements: [CGRect], imageSize: CGSize,
                       config: VisionOCR.OCRConfig) -> [[Observation]] {
        var recognized = [[Observation]](repeating: [], count: placements.count)
        for observation in raw {
            let candidates = observation.candidates
            guard let text = candidates.first(where: { $0.confidence >= config.confidenceAccept })
                ?? candidates.first.flatMap({ $0.confidence >= config.confidenceFallback ? $0 : nil }) else { continue }
            let pixels = CGRect(x: observation.x * imageSize.width,
                y: (1 - observation.y - observation.height) * imageSize.height,
                width: observation.width * imageSize.width, height: observation.height * imageSize.height)
            guard let index = placements.firstIndex(where: { $0.contains(pixels) }) else { continue }
            let placement = placements[index]
            let normalized = CGRect(x: (pixels.minX - placement.minX) / placement.width,
                y: 1 - (pixels.maxY - placement.minY) / placement.height,
                width: pixels.width / placement.width, height: pixels.height / placement.height)
            recognized[index].append(Observation(text: text.text, boundingBox: normalized))
        }
        return recognized.map { $0.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY } }
    }

    /// Caller holds `lock`.
    private static func store(_ recognized: [[Observation]], crops: [Crop], scope: String, configuration: String) {
        if !scope.isEmpty {
            for (slot, crop) in crops.enumerated() {
                entries.append(Entry(scope: scope, configuration: configuration,
                    width: crop.image.width, height: crop.image.height, pixels: crop.pixels,
                    hash: crop.hash, observations: recognized[slot]))
            }
        }
        // Memory only, bounded; a miss costs OCR, never changes delivery semantics.
        while entries.count > 64 || entries.reduce(0, { $0 + $1.pixels.count }) > 16 * 1024 * 1024 {
            entries.removeFirst()
        }
    }

    static func recognize(_ image: CGImage, scope: String, config: VisionOCR.OCRConfig,
                          failure: UnsafeMutablePointer<RecognizeFailure?>? = nil) -> Result? {
        let detection = InboundBubbleDetector.detect(in: image)
        guard detection.status != .uncertain else { failure?.pointee = .detectorUncertain; return nil }
        guard let crops = crops(in: image, rects: detection.rects) else { failure?.pointee = .cropFailed; return nil }
        guard !crops.isEmpty else {
            return Result(observations: [], bubbleCount: 0, recognizedPixels: 0, cacheHits: 0)
        }
        let configuration = "\(config.revision)|\(config.confidenceAccept)|\(config.confidenceFallback)|\(config.candidateCount)|\(config.usesLanguageCorrection)"
        var local = [[Observation]?](repeating: nil, count: crops.count)
        var pending: [Int] = []
        var hits = 0
        lock.lock()
        for (index, crop) in crops.enumerated() {
            // Exact bytes (not only a hash) avoid treating a collision as unchanged text.
            if !scope.isEmpty, let entry = entries.last(where: {
                $0.scope == scope && $0.configuration == configuration
                    && $0.width == crop.image.width && $0.height == crop.image.height
                    && $0.hash == crop.hash && $0.pixels == crop.pixels
            }) {
                local[index] = entry.observations
                hits += 1
            } else { pending.append(index) }
        }
        lock.unlock()

        var recognizedPixels = 0
        if !pending.isEmpty {
            guard let prepared = atlas(pending.map { crops[$0] }) else { failure?.pointee = .atlasFailed; return nil }
            recognizedPixels = prepared.image.width * prepared.image.height
            let raw: [RawObservation]
            do { raw = try performVision(on: prepared.image, config: config) }
            catch RawVisionError.noResults { failure?.pointee = .visionNoResults; return nil }
            catch {
                logVisionFailure(error, image: prepared.image, revision: requestedRevision(config))
                // Fill the cache from a fresh process; a later poll then hits it.
                OutOfProcessOCR.recognizeInBackground(prepared.image, config: config) { raw in
                    let recognized = assign(raw, placements: prepared.placements,
                                            imageSize: CGSize(width: prepared.image.width, height: prepared.image.height),
                                            config: config)
                    guard recognized.allSatisfy({ !$0.isEmpty }) else { return }
                    lock.lock()
                    store(recognized, crops: pending.map { crops[$0] }, scope: scope, configuration: configuration)
                    lock.unlock()
                }
                failure?.pointee = .visionError
                return nil
            }
            let recognized = assign(raw, placements: prepared.placements,
                                    imageSize: CGSize(width: prepared.image.width, height: prepared.image.height),
                                    config: config)
            // A partial OCR failure must not advance the watcher's previous frame.
            guard recognized.allSatisfy({ !$0.isEmpty }) else { failure?.pointee = .incompleteRecognition; return nil }
            lock.lock()
            for (slot, index) in pending.enumerated() {
                local[index] = recognized[slot]
            }
            store(recognized, crops: pending.map { crops[$0] }, scope: scope, configuration: configuration)
            lock.unlock()
        }
        var output: [Observation] = []
        for (index, crop) in crops.enumerated() {
            for item in local[index] ?? [] {
                output.append(Observation(text: item.text,
                    boundingBox: originalBox(item.boundingBox, crop: crop.rect,
                        imageSize: CGSize(width: image.width, height: image.height))))
            }
        }
        return Result(observations: output, bubbleCount: crops.count, recognizedPixels: recognizedPixels, cacheHits: hits)
    }

    static func originalBox(_ box: CGRect, crop: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: (crop.minX + box.minX * crop.width) / imageSize.width,
            y: 1 - (crop.minY + (1 - box.minY) * crop.height) / imageSize.height,
            width: box.width * crop.width / imageSize.width, height: box.height * crop.height / imageSize.height)
    }
}
