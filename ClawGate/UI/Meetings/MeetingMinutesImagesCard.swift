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
    struct Revision: Hashable {
        let folder: URL
        let manifestSHA256: String?
    }

    static func folder(meetingDirectory: URL) -> URL? {
        for name in ["minutes-accepted.json", "minutes.json"] {
            guard let data = try? Data(contentsOf: meetingDirectory.appendingPathComponent(name)) else { continue }
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return meetingDirectory.appendingPathComponent("minutes-images/\(hex)", isDirectory: true)
        }
        return nil
    }

    static func revision(folder: URL) -> Revision {
        let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        return Revision(folder: folder, manifestSHA256: data.map { MeetingMinutesPublication.digest($0) })
    }

    static func load(revision: Revision) -> [(image: MeetingMinutesImage, picture: NSImage)] {
        guard let data = try? Data(contentsOf: revision.folder.appendingPathComponent("manifest.json")),
              MeetingMinutesPublication.digest(data) == revision.manifestSHA256,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return manifest.images.compactMap { image in
            NSImage(contentsOf: revision.folder.appendingPathComponent(image.file)).map { (image, $0) }
        }
    }
}

struct MeetingMinutesImagesCard: View {
    let revision: MeetingMinutesImageStore.Revision?
    @State private var loaded: [(image: MeetingMinutesImage, picture: NSImage)] = []
    @State private var loadedRevision: MeetingMinutesImageStore.Revision?

    var body: some View {
        Group {
            if loadedRevision == revision, !loaded.isEmpty {
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
            guard let revision else { loaded = []; loadedRevision = nil; return }
            let images = await Task.detached(priority: .utility) {
                MeetingMinutesImageStore.load(revision: revision)
            }.value
            guard !Task.isCancelled else { return }
            loaded = images
            loadedRevision = revision
        }
    }
}
