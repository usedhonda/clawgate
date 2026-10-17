import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs inbound bubble OCR in a short-lived copy of this executable.
///
/// On some hosts the Vision text recognizer succeeds for the first request of a
/// process and then fails every later one (E5RT code 13, surfaced as
/// CRImageReaderError 1) until the process exits; device pinning does not help.
/// A fresh process per request sidesteps that without restarting ClawGate.
/// Only recognition moves out of process: the caller still owns caching and
/// every delivery decision.
enum OutOfProcessOCR {
    static let helperFlag = "--inbound-ocr-helper"
    private static let timeout: TimeInterval = 120
    private static let lock = NSLock()
    private static var inFlight = false
    private static let queue = DispatchQueue(label: "com.clawgate.inbound-ocr-helper", qos: .userInitiated)

    /// At most one helper runs at a time; a request made while one is running is
    /// dropped, and the watcher's next poll asks again.
    static func recognizeInBackground(_ image: CGImage, config: VisionOCR.OCRConfig,
                                      completion: @escaping ([InboundBubbleOCR.RawObservation]) -> Void) {
        lock.lock()
        guard !inFlight, let executable = Bundle.main.executableURL else { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        queue.async {
            defer {
                lock.lock()
                inFlight = false
                lock.unlock()
            }
            guard let raw = run(executable: executable, image: image, config: config) else { return }
            completion(raw)
        }
    }

    private static func run(executable: URL, image: CGImage,
                            config: VisionOCR.OCRConfig) -> [InboundBubbleOCR.RawObservation]? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawgate-ocr-helper-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        // The atlas holds message pixels; never leave it behind.
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("atlas.png")
        guard let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = [helperFlag, input.path, String(config.revision),
                             config.usesLanguageCorrection ? "1" : "0", String(config.candidateCount)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let started = Date()
        do { try process.run() } catch {
            NSLog("[OutOfProcessOCR] helper launch failed")
            return nil
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        guard process.terminationStatus == 0,
              let raw = try? JSONDecoder().decode([InboundBubbleOCR.RawObservation].self, from: data) else {
            NSLog("[OutOfProcessOCR] helper failed status=\(process.terminationStatus) ms=\(elapsed)")
            return nil
        }
        NSLog("[OutOfProcessOCR] helper recognized observations=\(raw.count) ms=\(elapsed)")
        return raw
    }

    /// Entry point for the helper process: `<png> <revision> <languageCorrection> <candidateCount>`.
    /// Writes `[RawObservation]` JSON to stdout and returns the exit status.
    static func runHelper(arguments: [String]) -> Int32 {
        guard arguments.count == 4,
              let revision = Int(arguments[1]), let candidateCount = Int(arguments[3]),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[0]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return 2 }
        var config = VisionOCR.OCRConfig()
        config.revision = revision
        config.usesLanguageCorrection = arguments[2] == "1"
        config.candidateCount = candidateCount
        guard let raw = try? InboundBubbleOCR.performVision(on: image, config: config),
              let data = try? JSONEncoder().encode(raw) else { return 1 }
        FileHandle.standardOutput.write(data)
        return 0
    }
}
