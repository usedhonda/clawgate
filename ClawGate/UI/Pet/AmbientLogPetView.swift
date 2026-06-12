import SwiftUI

/// Groups raw whisper segments into readable conversation blocks: segments
/// whose absolute times are close (< gap) and share a speaker merge into one
/// paragraph headed by the wall-clock time of its first utterance. A speaker
/// change starts a new block. Old segments without timestamps continue the
/// current block (no time info to split on).
enum AmbientLogGrouping {
    struct Block: Equatable {
        let timeLabel: String?   // "11:02", nil when the block has no timestamp
        let speaker: String?     // "self" | "other" | nil (unlabeled/legacy)
        let text: String
    }

    static func blocks(from segments: [TranscriptSegment],
                       gapSeconds: Double = 90,
                       timeZone: TimeZone = .current) -> [Block] {
        var result: [Block] = []
        var currentTexts: [String] = []
        var currentStart: Double?
        var currentSpeaker: String?
        var lastTime: Double?

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = timeZone

        func closeBlock() {
            guard !currentTexts.isEmpty else { return }
            let label = currentStart.map { fmt.string(from: Date(timeIntervalSince1970: $0)) }
            result.append(Block(timeLabel: label,
                                speaker: currentSpeaker,
                                text: currentTexts.joined(separator: " ")))
            currentTexts = []
            currentStart = nil
        }

        for seg in segments {
            if !currentTexts.isEmpty && seg.speaker != currentSpeaker {
                closeBlock()
            }
            if let t = seg.capturedAt {
                if let last = lastTime, t - last > gapSeconds {
                    closeBlock()
                }
                if currentStart == nil { currentStart = t }
                lastTime = t
            }
            currentSpeaker = seg.speaker
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
        // Publish only on change: each publish rebuilds the Text and clears
        // any in-progress selection — copy-paste must survive quiet refreshes.
        if label != sessionLabel { sessionLabel = label }
        let newBlocks = AmbientLogGrouping.blocks(from: segs)
        if newBlocks != blocks { blocks = newBlocks }
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

    static func speakerName(_ speaker: String?) -> String? {
        switch speaker {
        case "self": return "ご主人様"
        case "other": return "相手"
        default: return nil
        }
    }

    static func speakerColor(_ speaker: String?) -> Color {
        speaker == "self" ? Color(red: 0.55, green: 0.78, blue: 1.0) : .white.opacity(0.6)
    }

    /// The whole log as ONE attributed text. SwiftUI text selection is scoped
    /// to a single Text view — per-block Texts made it impossible to select
    /// across utterances for copy-paste. Heads ("11:02 ご主人様") stay styled
    /// and are included in the copied text, which reads like a transcript.
    static func attributedTranscript(_ blocks: [AmbientLogGrouping.Block]) -> AttributedString {
        var out = AttributedString()
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            var headText = block.timeLabel ?? ""
            if let name = speakerName(block.speaker) {
                headText += headText.isEmpty ? name : " " + name
            }
            if !headText.isEmpty {
                var head = AttributedString(headText + "\n")
                head.font = .system(size: 10, weight: .bold).monospacedDigit()
                head.foregroundColor = speakerColor(block.speaker)
                out += head
            }
            var body = AttributedString(block.text)
            body.font = .system(size: 13)
            body.foregroundColor = .white.opacity(0.85)
            out += body
        }
        return out
    }

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
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.attributedTranscript(model.blocks))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
