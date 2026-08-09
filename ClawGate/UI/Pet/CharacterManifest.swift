import AppKit
import CryptoKit
import Foundation

/// Character manifest loaded from manifest.json
struct CharacterManifest: Codable, Equatable {
    let name: String
    let displayName: String?
    let author: String?
    let version: String?
    let description: String?
    let states: [StateInfo]

    struct StateInfo: Codable, Equatable {
        let name: String
        let frames: [String]
        let fps: Double?
        let loop: Bool?
        let sheetColumns: Int?
        let sheetRows: Int?

        var isSheet: Bool {
            frames.count == 1 && (sheetColumns ?? 0) > 0
        }

        var shouldLoop: Bool {
            loop ?? true
        }
    }
}

struct CharacterManagerScanDiagnostic: Equatable {
    let code: String
    let count: Int
}

private struct ParsedFrameName {
    let fileName: String
    let parsedIndex: Int?
}

private struct CharacterAsset {
    let fingerprint: String
    let image: NSImage?
}

private struct ScannedBundle {
    let manifest: CharacterManifest
    let directory: URL
    let assetFingerprint: String
    let previewImage: NSImage?
}

private struct CharacterManagerScanSnapshot {
    let bundles: [ScannedBundle]
    let issueCounts: [String: Int]
    let droppedBundleCount: Int
}

private struct CharacterFrameCacheKey: Hashable {
    let characterName: String
    let stateName: String
    let frameIndex: Int
    let frameFileName: String
    let sheetColumns: Int
    let sheetRows: Int
}

private struct CharacterSheetCacheKey: Hashable {
    let characterName: String
    let stateName: String
    let frameFileName: String
    let sheetColumns: Int
    let sheetRows: Int
}

final class LoadedCharacter {
    var manifest: CharacterManifest
    var directory: URL
    var preview: NSImage?
    private var assetFingerprint: String

    private var frameCache: [CharacterFrameCacheKey: NSImage] = [:]
    private var sheetFrameCache: [CharacterSheetCacheKey: [NSImage]] = [:]

    private(set) var decodedFrameCount: Int = 0
    private(set) var frameCacheHitCount: Int = 0

    init(manifest: CharacterManifest, directory: URL, assetFingerprint: String, previewImage: NSImage?) {
        self.manifest = manifest
        self.directory = directory
        self.assetFingerprint = assetFingerprint
        self.preview = previewImage
    }

    func refresh(manifest: CharacterManifest, directory: URL, assetFingerprint: String, previewImage: NSImage?) {
        guard self.manifest != manifest || self.directory != directory || self.assetFingerprint != assetFingerprint else {
            return
        }

        self.manifest = manifest
        self.directory = directory
        self.assetFingerprint = assetFingerprint
        self.preview = previewImage
        frameCache.removeAll(keepingCapacity: true)
        sheetFrameCache.removeAll(keepingCapacity: true)
        decodedFrameCount = 0
        frameCacheHitCount = 0
    }

    /// Get animation frames for a given state
    func frames(for state: String) -> [NSImage] {
        guard let info = manifest.states.first(where: { $0.name == state }) else {
            return []
        }

        if info.isSheet {
            return splitSheetFrames(for: info)
        }
        return loadIndividualFrames(for: info)
    }

    /// FPS for a given state
    func fps(for state: String) -> Double {
        manifest.states.first(where: { $0.name == state })?.fps ?? 4.0
    }

    /// Whether the state should loop
    func shouldLoop(for state: String) -> Bool {
        manifest.states.first(where: { $0.name == state })?.shouldLoop ?? true
    }

    /// All available state names
    var stateNames: [String] {
        manifest.states.map(\.name)
    }

    private func loadIndividualFrames(for info: CharacterManifest.StateInfo) -> [NSImage] {
        return info.frames.enumerated().compactMap { index, filename in
            guard let frameRef = parseFrameName(filename) else {
                return nil
            }

            let key = CharacterFrameCacheKey(
                characterName: manifest.name,
                stateName: info.name,
                frameIndex: index,
                frameFileName: frameRef.fileName,
                sheetColumns: 0,
                sheetRows: 0
            )

            if let cached = frameCache[key] {
                frameCacheHitCount += 1
                return cached
            }

            let path = directory.appendingPathComponent(frameRef.fileName)
            guard let image = NSImage(contentsOf: path) else {
                return nil
            }

            frameCache[key] = image
            decodedFrameCount += 1
            return image
        }
    }

    private func splitSheetFrames(for info: CharacterManifest.StateInfo) -> [NSImage] {
        guard let firstFrame = info.frames.first,
              let frameRef = parseFrameName(firstFrame) else {
            return []
        }

        let cols = info.sheetColumns ?? 1
        let rows = info.sheetRows ?? 1
        let sheetKey = CharacterSheetCacheKey(
            characterName: manifest.name,
            stateName: info.name,
            frameFileName: frameRef.fileName,
            sheetColumns: cols,
            sheetRows: rows
        )

        let sheetFrames: [NSImage]
        if let cached = sheetFrameCache[sheetKey] {
            sheetFrames = cached
        } else {
            let path = directory.appendingPathComponent(frameRef.fileName)
            guard let sheet = NSImage(contentsOf: path) else {
                return []
            }
            decodedFrameCount += 1
            let splitFrames = splitSpriteSheet(sheet, columns: cols, rows: rows)
            sheetFrameCache[sheetKey] = splitFrames
            sheetFrames = splitFrames
        }

        return sheetFrames.enumerated().compactMap { index, frame in
            let key = CharacterFrameCacheKey(
                characterName: manifest.name,
                stateName: info.name,
                frameIndex: index,
                frameFileName: frameRef.fileName,
                sheetColumns: cols,
                sheetRows: rows
            )

            if let cached = frameCache[key] {
                frameCacheHitCount += 1
                return cached
            }

            frameCache[key] = frame
            return frame
        }
    }

    private func splitSpriteSheet(_ image: NSImage, columns: Int, rows: Int) -> [NSImage] {
        guard columns > 0, rows > 0 else {
            return []
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [image]
        }

        let frameWidth = cgImage.width / columns
        let frameHeight = cgImage.height / rows
        guard frameWidth > 0, frameHeight > 0 else {
            return []
        }

        var frames: [NSImage] = []
        for row in 0..<rows {
            for col in 0..<columns {
                let rect = CGRect(
                    x: col * frameWidth,
                    y: row * frameHeight,
                    width: frameWidth,
                    height: frameHeight
                )
                if let cropped = cgImage.cropping(to: rect) {
                    let nsImage = NSImage(
                        cgImage: cropped,
                        size: NSSize(width: frameWidth, height: frameHeight)
                    )
                    frames.append(nsImage)
                }
            }
        }
        return frames
    }
}

/// Manages available characters (bundled + custom)
final class CharacterManager: ObservableObject {
    @Published private(set) var characters: [CharacterManifest] = []
    @Published var selectedName: String = "chi-claw"
    @Published private(set) var lastScanDiagnostics: [CharacterManagerScanDiagnostic] = []
    @Published private(set) var lastScanDroppedBundleCount: Int = 0

    private static let diagnosticEntryLimit = 8
    private static let maxStatesPerManifest = 128
    private static let maxFramesPerState = 512
    private static let maxSpriteCellCount = 8192
    private static let maxParsedFrameIndex = 10_000

    static let missingManifestCode = "character.bundle.missing_manifest"
    static let invalidManifestJSONCode = "character.bundle.invalid_manifest_json"
    static let invalidCharacterNameCode = "character.bundle.invalid_character_name"
    static let missingStatesCode = "character.bundle.missing_states"
    static let tooManyStatesCode = "character.bundle.too_many_states"
    static let invalidStateNameCode = "character.bundle.invalid_state_name"
    static let duplicateStateNameCode = "character.bundle.duplicate_state_name"
    static let invalidFramesCode = "character.bundle.invalid_frames"
    static let invalidFrameReferenceCode = "character.bundle.invalid_frame_reference"
    static let missingFrameFileCode = "character.bundle.missing_frame_file"
    static let invalidImageFileCode = "character.bundle.invalid_image_file"
    static let invalidSpriteConfigCode = "character.bundle.invalid_sprite_config"
    static let invalidFpsCode = "character.bundle.invalid_fps"
    static let duplicateBundleNameCode = "character.bundle.duplicate_name"

    private let frameAssetReader: (URL) throws -> Data
    private var loadedCache: [String: LoadedCharacter] = [:]
    private let searchPathsOverride: [URL]?

    init(
        searchPaths: [URL]? = nil,
        frameAssetReader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.searchPathsOverride = searchPaths
        self.frameAssetReader = frameAssetReader
    }

    /// Directories to scan for characters
    private var searchPaths: [URL] {
        if let override = searchPathsOverride {
            return override
        }

        var paths: [URL] = []
        let customDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawgate/characters")
        paths.append(customDir)

        if let moduleCharacters = Bundle.module.resourceURL?.appendingPathComponent("Characters") {
            paths.append(moduleCharacters)
        }

        if let appCharacters = Bundle.main.resourceURL?.appendingPathComponent("Characters") {
            paths.append(appCharacters)
        }

        return paths
    }

    func scan() {
        let snapshot = collectScanSnapshot()

        var nextCache: [String: LoadedCharacter] = [:]
        for bundle in snapshot.bundles {
            if let existing = loadedCache[bundle.manifest.name] {
                existing.refresh(
                    manifest: bundle.manifest,
                    directory: bundle.directory,
                    assetFingerprint: bundle.assetFingerprint,
                    previewImage: bundle.previewImage
                )
                nextCache[bundle.manifest.name] = existing
            } else {
                nextCache[bundle.manifest.name] = LoadedCharacter(
                    manifest: bundle.manifest,
                    directory: bundle.directory,
                    assetFingerprint: bundle.assetFingerprint,
                    previewImage: bundle.previewImage
                )
            }
        }

        loadedCache = nextCache
        characters = snapshot.bundles.map { $0.manifest }
        lastScanDroppedBundleCount = snapshot.droppedBundleCount
        lastScanDiagnostics = snapshot.issueCounts
            .map { CharacterManagerScanDiagnostic(code: $0.key, count: $0.value) }
            .sorted { $0.code < $1.code }
            .prefix(CharacterManager.diagnosticEntryLimit)
            .map { $0 }

        if characters.isEmpty {
            selectedName = ""
        } else if !characters.contains(where: { $0.name == selectedName }) {
            selectedName = characters[0].name
        }
    }

    /// Get the loaded character for the current selection
    func current() -> LoadedCharacter? {
        loadedCache[selectedName]
    }

    private func collectScanSnapshot() -> CharacterManagerScanSnapshot {
        var issueCounts: [String: Int] = [:]
        var bundles: [ScannedBundle] = []
        var seenNames = Set<String>()
        var droppedBundleCount = 0

        for searchPath in searchPaths {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: searchPath,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )) ?? []

            let orderedDirs = dirs
                .filter(\.hasDirectoryPath)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for dir in orderedDirs {
                guard let bundle = loadValidatedBundle(from: dir, issueCounts: &issueCounts) else {
                    droppedBundleCount += 1
                    continue
                }

                if seenNames.insert(bundle.manifest.name).inserted {
                    bundles.append(bundle)
                } else {
                    issueCounts[Self.duplicateBundleNameCode, default: 0] += 1
                    droppedBundleCount += 1
                }
            }
        }

        return CharacterManagerScanSnapshot(
            bundles: bundles,
            issueCounts: issueCounts,
            droppedBundleCount: droppedBundleCount
        )
    }

    private func loadValidatedBundle(from directory: URL, issueCounts: inout [String: Int]) -> ScannedBundle? {
        let manifestPath = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestPath) else {
            issueCounts[Self.missingManifestCode, default: 0] += 1
            return nil
        }

        let manifest: CharacterManifest
        do {
            manifest = try JSONDecoder().decode(CharacterManifest.self, from: data)
        } catch {
            issueCounts[Self.invalidManifestJSONCode, default: 0] += 1
            return nil
        }

        var assetFingerprints: [String] = []
        var frameAssetCache: [String: CharacterAsset?] = [:]
        guard isValidBundle(
            manifest,
            in: directory,
            issueCounts: &issueCounts,
            assetFingerprints: &assetFingerprints,
            frameAssetCache: &frameAssetCache
        ) else {
            return nil
        }

        let previewImage: NSImage?
        if let preview = makePreviewAsset(in: directory, reader: frameAssetReader) {
            assetFingerprints.append(preview.fingerprint)
            previewImage = preview.image
        } else {
            previewImage = nil
        }

        guard let fingerprint = makeBundleFingerprint(manifest: manifest, frameFingerprints: assetFingerprints) else {
            return nil
        }

        return ScannedBundle(
            manifest: manifest,
            directory: directory,
            assetFingerprint: fingerprint,
            previewImage: previewImage
        )
    }

    private func isValidBundle(
        _ manifest: CharacterManifest,
        in directory: URL,
        issueCounts: inout [String: Int],
        assetFingerprints: inout [String],
        frameAssetCache: inout [String: CharacterAsset?]
    ) -> Bool {
        let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            issueCounts[Self.invalidCharacterNameCode, default: 0] += 1
            return false
        }

        guard !manifest.states.isEmpty else {
            issueCounts[Self.missingStatesCode, default: 0] += 1
            return false
        }

        guard manifest.states.count <= Self.maxStatesPerManifest else {
            issueCounts[Self.tooManyStatesCode, default: 0] += 1
            return false
        }

        var seenStateNames = Set<String>()
        for state in manifest.states {
            let trimmedStateName = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedStateName.isEmpty else {
                issueCounts[Self.invalidStateNameCode, default: 0] += 1
                return false
            }

            guard seenStateNames.insert(trimmedStateName).inserted else {
                issueCounts[Self.duplicateStateNameCode, default: 0] += 1
                return false
            }

            guard isValidState(
                state,
                in: directory,
                issueCounts: &issueCounts,
                assetFingerprints: &assetFingerprints,
                frameAssetCache: &frameAssetCache
            ) else {
                return false
            }
        }

        return true
    }

    private func isValidState(
        _ state: CharacterManifest.StateInfo,
        in directory: URL,
        issueCounts: inout [String: Int],
        assetFingerprints: inout [String],
        frameAssetCache: inout [String: CharacterAsset?]
    ) -> Bool {
        guard !state.frames.isEmpty, state.frames.count <= Self.maxFramesPerState else {
            issueCounts[Self.invalidFramesCode, default: 0] += 1
            return false
        }

        if state.isSheet {
            let cols = state.sheetColumns ?? 0
            let rows = state.sheetRows ?? 0
            guard cols > 0, rows > 0 else {
                issueCounts[Self.invalidSpriteConfigCode, default: 0] += 1
                return false
            }
            let product = cols.multipliedReportingOverflow(by: rows)
            guard !product.overflow, product.partialValue <= Self.maxSpriteCellCount else {
                issueCounts[Self.invalidSpriteConfigCode, default: 0] += 1
                return false
            }
            guard state.frames.count == 1 else {
                issueCounts[Self.invalidSpriteConfigCode, default: 0] += 1
                return false
            }
        } else if (state.sheetColumns ?? 0) > 0 || (state.sheetRows ?? 0) > 0 {
            issueCounts[Self.invalidSpriteConfigCode, default: 0] += 1
            return false
        }

        if let fps = state.fps, (!fps.isFinite || fps <= 0) {
            issueCounts[Self.invalidFpsCode, default: 0] += 1
            return false
        }

        for rawFrame in state.frames {
            guard let frameRef = parseFrameName(rawFrame) else {
                issueCounts[Self.invalidFrameReferenceCode, default: 0] += 1
                return false
            }
            let framePath = directory.appendingPathComponent(frameRef.fileName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: framePath.path, isDirectory: &isDir), !isDir.boolValue else {
                issueCounts[Self.missingFrameFileCode, default: 0] += 1
                return false
            }

            guard let frameAsset = decodeAndFingerprintFrame(
                at: framePath,
                cache: &frameAssetCache,
                reader: frameAssetReader
            ) else {
                issueCounts[Self.invalidImageFileCode, default: 0] += 1
                return false
            }
            assetFingerprints.append(frameAsset.fingerprint)
            guard let frameImage = frameAsset.image else {
                issueCounts[Self.invalidImageFileCode, default: 0] += 1
                return false
            }

            if state.isSheet {
                let cols = state.sheetColumns ?? 1
                let rows = state.sheetRows ?? 1
                guard isValidSpriteGrid(image: frameImage, columns: cols, rows: rows) else {
                    issueCounts[Self.invalidSpriteConfigCode, default: 0] += 1
                    return false
                }
            }

            if let parsedIndex = frameRef.parsedIndex, parsedIndex > Self.maxParsedFrameIndex {
                issueCounts[Self.invalidFrameReferenceCode, default: 0] += 1
                return false
            }
        }

        return true
    }
}

private func parseFrameName(_ raw: String) -> ParsedFrameName? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !trimmed.contains("/") && !trimmed.contains("\\") else { return nil }

    let url = URL(fileURLWithPath: trimmed)
    let fileName = url.lastPathComponent
    guard !fileName.isEmpty else { return nil }

    let stem = url.deletingPathExtension().lastPathComponent
    guard !stem.isEmpty else { return nil }

    return ParsedFrameName(
        fileName: fileName,
        parsedIndex: parseTrailingIndex(from: stem)
    )
}

private func parseTrailingIndex(from stem: String) -> Int? {
    let components = stem.split(separator: "-")
    guard let last = components.last, let index = Int(last), index >= 0 else {
        return nil
    }
    return index
}

private func decodeFrameImage(from data: Data) -> NSImage? {
    guard let image = NSImage(data: data) else {
        return nil
    }

    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
    }

    guard cgImage.width > 0, cgImage.height > 0 else {
        return nil
    }

    return image
}

private func isValidSpriteGrid(image: NSImage, columns: Int, rows: Int) -> Bool {
    guard columns > 0, rows > 0 else { return false }
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    guard cgImage.width > 0, cgImage.height > 0 else { return false }
    guard cgImage.width % columns == 0, cgImage.height % rows == 0 else {
        return false
    }
    let frameWidth = cgImage.width / columns
    let frameHeight = cgImage.height / rows
    return frameWidth > 0 && frameHeight > 0
}

private func makePreviewAsset(
    in directory: URL,
    reader: (URL) throws -> Data
) -> CharacterAsset? {
    let previewPath = directory.appendingPathComponent("preview.png")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: previewPath.path, isDirectory: &isDir), !isDir.boolValue else {
        return nil
    }

    guard let data = try? reader(previewPath) else {
        return nil
    }

    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let filename = previewPath.lastPathComponent
    return CharacterAsset(
        fingerprint: "\(filename):\(data.count):\(hex)",
        image: decodeFrameImage(from: data)
    )
}

private func decodeAndFingerprintFrame(
    at path: URL,
    cache: inout [String: CharacterAsset?],
    reader: (URL) throws -> Data
) -> CharacterAsset? {
    let cacheKey = path.standardizedFileURL.path
    if let cached = cache[cacheKey] {
        return cached
    }

    guard let data = try? reader(path) else {
        cache[cacheKey] = nil
        return nil
    }

    let digest = SHA256.hash(data: data)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let filename = path.lastPathComponent
    let fingerprint = "\(filename):\(data.count):\(hex)"
    let asset = CharacterAsset(fingerprint: fingerprint, image: decodeFrameImage(from: data))
    cache[cacheKey] = asset
    return asset
}

private func makeBundleFingerprint(
    manifest: CharacterManifest,
    frameFingerprints: [String]
) -> String? {
    let manifestDigest = makeManifestFingerprint(manifest)
    guard let manifestDigest else { return nil }
    let payload = ([manifestDigest] + frameFingerprints).joined(separator: "|")
    guard let data = payload.data(using: .utf8) else { return nil }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func makeManifestFingerprint(_ manifest: CharacterManifest) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(manifest) else {
        return nil
    }
    let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return hex
}
