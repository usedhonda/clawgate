import AppKit
import Foundation

/// Character manifest loaded from manifest.json
struct CharacterManifest: Codable {
    let name: String
    let displayName: String?
    let author: String?
    let version: String?
    let description: String?
    let states: [StateInfo]

    struct StateInfo: Codable {
        let name: String             // "idle", "speak", "walk-right"
        let frames: [String]         // frame filenames (individual PNGs or single sprite sheet)
        let fps: Double?             // animation speed, default 4
        let loop: Bool?              // loop animation, default true
        let sheetColumns: Int?       // if sprite sheet: number of columns
        let sheetRows: Int?          // if sprite sheet: number of rows

        var isSheet: Bool {
            frames.count == 1 && (sheetColumns ?? 0) > 0
        }

        var shouldLoop: Bool {
            loop ?? true
        }
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

        let result: [NSImage]
        if info.isSheet {
            // Sprite sheet mode: split single image into grid
            let path = directory.appendingPathComponent(info.frames[0])
            guard let sheet = NSImage(contentsOf: path) else { return [] }
            let cols = info.sheetColumns ?? 1
            let rows = info.sheetRows ?? 1
            result = splitSpriteSheet(sheet, columns: cols, rows: rows)
        } else {
            // Individual frames mode: load each file
            result = info.frames.compactMap { filename in
                let path = directory.appendingPathComponent(filename)
                return NSImage(contentsOf: path)
            }
        }

        frameCache[state] = result
        return result
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

    private func splitSpriteSheet(_ image: NSImage, columns: Int, rows: Int) -> [NSImage] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [image]
        }
        let frameWidth = cgImage.width / columns
        let frameHeight = cgImage.height / rows
        var frames: [NSImage] = []
        for row in 0..<rows {
            for col in 0..<columns {
                let rect = CGRect(x: col * frameWidth, y: row * frameHeight,
                                  width: frameWidth, height: frameHeight)
                if let cropped = cgImage.cropping(to: rect) {
                    let nsImage = NSImage(cgImage: cropped,
                                          size: NSSize(width: frameWidth, height: frameHeight))
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
        // SwiftPM module bundle
        let moduleBundle = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/ClawGate_ClawGate.bundle/Contents/Resources/Characters")
        if FileManager.default.fileExists(atPath: moduleBundle.path) {
            paths.append(moduleBundle)
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
        if !characters.contains(where: { $0.name == selectedName }), let first = characters.first {
            selectedName = first.name
        }
    }

    /// Get the loaded character for the current selection
    func current() -> LoadedCharacter? {
        loadedCache[selectedName]
    }
}
