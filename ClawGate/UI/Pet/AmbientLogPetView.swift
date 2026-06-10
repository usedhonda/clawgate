import SwiftUI

/// Groups raw whisper segments into readable conversation blocks: segments
/// whose absolute times are close (< gap) merge into one paragraph headed by
/// the wall-clock time of its first utterance. Old segments without
/// timestamps continue the current block (no time info to split on).
enum AmbientLogGrouping {
    struct Block: Equatable {
        let timeLabel: String?   // "11:02", nil when the block has no timestamp
        let text: String
    }

    static func blocks(from segments: [TranscriptSegment],
                       gapSeconds: Double = 90,
                       timeZone: TimeZone = .current) -> [Block] {
        var result: [Block] = []
        var currentTexts: [String] = []
        var currentStart: Double?
        var lastTime: Double?

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = timeZone

        func closeBlock() {
            guard !currentTexts.isEmpty else { return }
            let label = currentStart.map { fmt.string(from: Date(timeIntervalSince1970: $0)) }
            result.append(Block(timeLabel: label, text: currentTexts.joined(separator: " ")))
            currentTexts = []
            currentStart = nil
        }

        for seg in segments {
            if let t = seg.capturedAt {
                if let last = lastTime, t - last > gapSeconds {
                    closeBlock()
                }
                if currentStart == nil { currentStart = t }
                lastTime = t
            }
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { currentTexts.append(trimmed) }
        }
        closeBlock()
        return result
    }
}

private final class AmbientLogModel: ObservableObject {
    @Published var blocks: [AmbientLogGrouping.Block] = []
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
        blocks = AmbientLogGrouping.blocks(from: segs)
    }
}

/// "Log" tab in the pet chat panel: the ambient transcript of the surrounding
/// conversation (most recent session), grouped into time-stamped paragraphs.
/// Machine transcript — context, not quote-safe record.
struct AmbientLogPetView: View {
    @StateObject private var model = AmbientLogModel()

    /// Opaque panel fill so a sparse log doesn't leave the translucent window
    /// showing the desktop behind it.
    private static let panelBg = Color(red: 0.11, green: 0.12, blue: 0.16)

    var body: some View {
        Group {
            if model.blocks.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.panelBg)
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
            Text("右クリック → Start Recording で録音開始")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
            Spacer()
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(model.blocks.enumerated()), id: \.offset) { _, block in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(block.timeLabel ?? "–:–")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundColor(.white.opacity(0.45))
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 1)
                            }
                            Text(block.text)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.85))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear.frame(height: 1).id("ambient-log-bottom")
                }
                .padding(12)
            }
            .onChange(of: model.blocks.count) { _ in
                proxy.scrollTo("ambient-log-bottom", anchor: .bottom)
            }
        }
    }
}
