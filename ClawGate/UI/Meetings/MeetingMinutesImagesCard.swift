import AppKit
import CryptoKit
import SwiftUI

/// Explanatory images generated for exactly the minutes revision being shown.
/// Images of an older revision are not shown: they may describe replaced text.
struct MeetingMinutesImage: Decodable, Identifiable {
    let index: Int
    let file: String
    let title: String
    let alt: String
    var id: Int { index }
}

enum MeetingMinutesImageStore {
    private struct Manifest: Decodable { let images: [MeetingMinutesImage] }

    static func folder(meetingDirectory: URL) -> URL? {
        for name in ["minutes-accepted.json", "minutes.json"] {
            guard let data = try? Data(contentsOf: meetingDirectory.appendingPathComponent(name)) else { continue }
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return meetingDirectory.appendingPathComponent("minutes-images/\(hex)", isDirectory: true)
        }
        return nil
    }

    static func load(meetingDirectory: URL) -> [(image: MeetingMinutesImage, picture: NSImage)] {
        guard let folder = folder(meetingDirectory: meetingDirectory),
              let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return manifest.images.compactMap { image in
            NSImage(contentsOf: folder.appendingPathComponent(image.file)).map { (image, $0) }
        }
    }
}

struct MeetingMinutesImagesCard: View {
    let meetingDirectory: URL
    let revision: String?
    @State private var loaded: [(image: MeetingMinutesImage, picture: NSImage)] = []

    var body: some View {
        Group {
            if !loaded.isEmpty {
                WorkspaceCard(title: "図解（AI生成）") {
                    Text("内容の正確さは本文を基準にしてください。")
                        .font(.system(size: 12)).foregroundColor(WorkspaceTheme.muted)
                    ForEach(loaded, id: \.image.id) { item in
                        Text(item.image.title).font(.system(size: 14, weight: .bold))
                        Image(nsImage: item.picture)
                            .resizable().scaledToFit().frame(maxWidth: .infinity)
                            .accessibilityLabel(item.image.alt)
                            .help(item.image.alt)
                    }
                }
            }
        }
        .task(id: revision) {
            let directory = meetingDirectory
            let images = await Task.detached(priority: .utility) {
                MeetingMinutesImageStore.load(meetingDirectory: directory)
            }.value
            loaded = images
        }
    }
}
