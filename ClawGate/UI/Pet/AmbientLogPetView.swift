import SwiftUI

private struct AmbientLogEntry: Identifiable {
    let id = UUID()
    let text: String
}

private final class AmbientLogModel: ObservableObject {
    @Published var entries: [AmbientLogEntry] = []
    @Published var sessionLabel: String = ""
    private var timer: Timer?

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        let (label, segs) = AmbientStorage.latestSessionSegments(limit: 300)
        sessionLabel = label
        entries = segs.map { AmbientLogEntry(text: $0.text) }
    }
}

/// "Log" tab in the pet chat panel: the ambient transcript of the surrounding
/// conversation (most recent session), scrollable to browse past messages and
/// auto-refreshing. Machine transcript — context, not quote-safe record.
struct AmbientLogPetView: View {
    @StateObject private var model = AmbientLogModel()

    var body: some View {
        Group {
            if model.entries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("周囲の会話ログはまだありません")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
            Text("右クリック → Start Context Stream で録音開始")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
            Spacer()
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.entries) { entry in
                        Text(entry.text)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("ambient-log-bottom")
                }
                .padding(12)
            }
            .onChange(of: model.entries.count) { _ in
                proxy.scrollTo("ambient-log-bottom", anchor: .bottom)
            }
        }
    }
}
