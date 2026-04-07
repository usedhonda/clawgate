import AppKit
import Foundation

/// Character manifest loaded from manifest.json
struct CharacterManifest: Codable {
    let name: String
    let author: String?
    let frameSize: Int           // e.g. 128, 192
    let states: [StateInfo]

    struct StateInfo: Codable {
        let name: String         // "idle", "speak"
        let file: String         // "idle.png" (sprite sheet or single frame)
        let frameCount: Int      // number of horizontal frames in sheet
        let fps: Double?         // animation speed, default 4
    }
}

/// Loaded character ready for rendering
struct LoadedCharacter {
    let manifest: CharacterManifest
    let directory: URL
    let preview: NSImage?
    private var frameCache: [String: [NSImage]] = [:]

    init(manifest: CharacterManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
        let previewPath = directory.appendingPathComponent("preview.png")
        self.preview = NSImage(contentsOf: previewPath)
    }

    /// Get animation frames for a given state
    mutating func frames(for state: String) -> [NSImage] {
        if let cached = frameCache[state] { return cached }
        guard let info = manifest.states.first(where: { $0.name == state }) else { return [] }
        let path = directory.appendingPathComponent(info.file)
        guard let sheet = NSImage(contentsOf: path) else { return [] }

        if info.frameCount <= 1 {
            frameCache[state] = [sheet]
            return [sheet]
        }

        // Split horizontal sprite sheet into individual frames
        let frames = splitSpriteSheet(sheet, frameCount: info.frameCount)
        frameCache[state] = frames
        return frames
    }

    /// FPS for a given state
    func fps(for state: String) -> Double {
        manifest.states.first(where: { $0.name == state })?.fps ?? 4.0
    }

    private func splitSpriteSheet(_ image: NSImage, frameCount: Int) -> [NSImage] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [image]
        }
        let frameWidth = cgImage.width / frameCount
        let frameHeight = cgImage.height
        var frames: [NSImage] = []
        for i in 0..<frameCount {
            let rect = CGRect(x: i * frameWidth, y: 0, width: frameWidth, height: frameHeight)
            if let cropped = cgImage.cropping(to: rect) {
                let nsImage = NSImage(cgImage: cropped, size: NSSize(width: frameWidth, height: frameHeight))
                frames.append(nsImage)
            }
        }
        return frames
    }
}

/// Manages available characters (bundled + custom)
final class CharacterManager: ObservableObject {
    @Published private(set) var characters: [CharacterManifest] = []
    @Published var selectedName: String = "chi"

    private var loadedCache: [String: LoadedCharacter] = [:]

    /// Directories to scan for characters
    private var searchPaths: [URL] {
        var paths: [URL] = []
        // Custom characters
        let customDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawgate/characters")
        paths.append(customDir)
        // Bundled characters (in app resources)
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Characters") {
            paths.append(bundled)
        }
        return paths
    }

    func scan() {
        var found: [CharacterManifest] = []
        for searchPath in searchPaths {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: searchPath, includingPropertiesForKeys: nil
            ) else { continue }
            for dir in entries where dir.hasDirectoryPath {
                let manifestPath = dir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestPath),
                      let manifest = try? JSONDecoder().decode(CharacterManifest.self, from: data) else {
                    continue
                }
                found.append(manifest)
                loadedCache[manifest.name] = LoadedCharacter(manifest: manifest, directory: dir)
            }
        }
        characters = found
        // If selected character not found, fall back to first available
        if !characters.contains(where: { $0.name == selectedName }), let first = characters.first {
            selectedName = first.name
        }
    }

    /// Get the loaded character for the current selection
    func current() -> LoadedCharacter? {
        loadedCache[selectedName]
    }
}
