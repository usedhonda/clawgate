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

    /// One conversation scene (a meeting): a run of segments with no gap longer
    /// than `gapSeconds` between consecutive timestamped utterances. This is a
    /// coarser layer than `blocks()` — 15-minute silences split meetings apart.
    struct Scene: Equatable {
        let id: String           // String(Int(startEpoch)), "unknown" for all-nil
        let startEpoch: Double   // first capturedAt in the scene (0 when all nil)
        let endEpoch: Double     // last capturedAt in the scene (0 when all nil)
        let timeLabel: String    // "HH:mm–HH:mm", "" when the scene has no timestamps
        let segments: [TranscriptSegment]
    }

    static func scenes(from segments: [TranscriptSegment],
                       gapSeconds: Double = 900,
                       timeZone: TimeZone) -> [Scene] {
        var result: [Scene] = []
        var current: [TranscriptSegment] = []
        var firstEpoch: Double?
        var lastEpoch: Double?

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.timeZone = timeZone

        func closeScene() {
            guard !current.isEmpty else { return }
            if let first = firstEpoch, let last = lastEpoch {
                let label = fmt.string(from: Date(timeIntervalSince1970: first))
                    + "–" + fmt.string(from: Date(timeIntervalSince1970: last))
                result.append(Scene(id: String(Int(first)),
                                    startEpoch: first, endEpoch: last,
                                    timeLabel: label, segments: current))
            } else {
                result.append(Scene(id: "unknown", startEpoch: 0, endEpoch: 0,
                                    timeLabel: "", segments: current))
            }
            current = []
            firstEpoch = nil
            lastEpoch = nil
        }

        for seg in segments {
            if let t = seg.capturedAt {
                if let last = lastEpoch, t - last > gapSeconds {
                    closeScene()
                }
                if firstEpoch == nil { firstEpoch = t }
                lastEpoch = t
            }
            current.append(seg)
        }
        closeScene()
        return result
    }
}

private final class AmbientLogModel: ObservableObject {
    @Published var blocks: [AmbientLogGrouping.Block] = []
    @Published var selectedDay: Date
    private let timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    private lazy var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }()
    private var cachedBlocksByDay: [Date: [AmbientLogGrouping.Block]] = [:]
    private var timer: Timer?

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        selectedDay = cal.startOfDay(for: Date())
    }

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

    func moveDay(by days: Int) {
        guard let day = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        selectedDay = clampedDay(day)
        load()
    }

    func jumpToToday() {
        selectedDay = today
        load()
    }

    var canMovePrevious: Bool {
        selectedDay > earliestDay
    }

    var canMoveNext: Bool {
        selectedDay < today
    }

    var isTodaySelected: Bool {
        selectedDay == today
    }

    var dayLabel: String {
        if isTodaySelected { return "今日" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ja_JP")
        fmt.timeZone = timeZone
        fmt.dateFormat = "M/d(E)"
        return fmt.string(from: selectedDay)
    }

    func transcriptText() -> String {
        blocks.map { block in
            var headText = block.timeLabel ?? ""
            if let name = AmbientLogPetView.speakerName(block.speaker) {
                headText += headText.isEmpty ? name : " " + name
            }
            return headText.isEmpty ? block.text : "\(headText)\n\(block.text)"
        }.joined(separator: "\n\n")
    }

    private func load() {
        let day = clampedDay(selectedDay)
        if day != selectedDay { selectedDay = day }
        let newBlocks: [AmbientLogGrouping.Block]
        if day == today {
            let (_, segs) = AmbientStorage.latestSessionSegments(limit: 2000)
            newBlocks = AmbientLogGrouping.blocks(from: segs, timeZone: timeZone)
        } else if let cached = cachedBlocksByDay[day] {
            newBlocks = cached
        } else {
            let segs = AmbientStorage.segments(forDay: day, timeZone: timeZone)
            newBlocks = AmbientLogGrouping.blocks(from: segs, timeZone: timeZone)
            cachedBlocksByDay[day] = newBlocks
        }
        if newBlocks != blocks { blocks = newBlocks }
    }

    private var today: Date {
        calendar.startOfDay(for: Date())
    }

    private var earliestDay: Date {
        calendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    private func clampedDay(_ day: Date) -> Date {
        let start = calendar.startOfDay(for: day)
        return min(max(start, earliestDay), today)
    }
}

/// "Log" tab in the pet chat panel: the ambient transcript of the surrounding
/// conversation (most recent session), grouped into time-stamped paragraphs.
/// Machine transcript — context, not quote-safe record.
struct AmbientLogPetView: View {
    @ObservedObject var model: PetModel
    @StateObject private var logModel = AmbientLogModel()
    @State private var instructionText = ""

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
        VStack(spacing: 0) {
            dayNavBar
            Divider().opacity(0.12)
            Group {
                if logModel.blocks.isEmpty {
                    emptyState
                } else {
                    logList
                }
            }
            repliesView
            actionBar
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.panelBg)
        .onAppear { logModel.start() }
        .onDisappear { logModel.stop() }
    }

    private var dayNavBar: some View {
        HStack(spacing: 8) {
            Button("‹") { logModel.moveDay(by: -1) }
                .buttonStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(logModel.canMovePrevious ? .white.opacity(0.75) : .white.opacity(0.22))
                .disabled(!logModel.canMovePrevious)
            Text(logModel.dayLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .frame(minWidth: 72)
            Button("›") { logModel.moveDay(by: 1) }
                .buttonStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(logModel.canMoveNext ? .white.opacity(0.75) : .white.opacity(0.22))
                .disabled(!logModel.canMoveNext)
            Button("今日") { logModel.jumpToToday() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(logModel.isTodaySelected ? .white.opacity(0.3) : Color(red: 0.55, green: 0.78, blue: 1.0))
                .disabled(logModel.isTodaySelected)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    Text(Self.attributedTranscript(logModel.blocks))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("ambient-log-bottom")
                }
                .padding(12)
            }
            // Follow ANY content change, not just new blocks: continuous talk
            // appends to the tail block (count unchanged), and the viewport
            // must still track it — this is what made the log look frozen
            // during a long conversation.
            .onChange(of: logModel.blocks) { _ in
                proxy.scrollTo("ambient-log-bottom", anchor: .bottom)
            }
            // Land on the newest content when the tab opens, after the first
            // layout pass (scrollTo inside onAppear itself is a no-op while
            // the text has no size yet).
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("ambient-log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var repliesView: some View {
        Group {
            if !model.logReplies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chi replies")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.logReplies.reversed().prefix(3))) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(timeString(entry.timestamp))
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.35))
                                    Text(entry.text)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.82))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().opacity(0.12)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            actionButton("質問まとめ", instruction: "この会話ログの中から、確認・回答すべき質問事項を箇条書きでまとめて。")
            actionButton("要点", instruction: "この会話ログの要点を3〜5個の箇条書きで簡潔にまとめて。")
            actionButton("TODO", instruction: "この会話ログから、やるべきこと(TODO)を抽出して。担当・期限が読み取れれば添えて。")
            actionButton("区切り", instruction: "私のカレンダーの予定に照らして、この会話ログをどの時点で区切るのが自然か提案して。予定はあなたが把握しているものを使って。")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("ちーに聞く", text: $instructionText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            Button("送信") {
                sendInstruction(instructionText)
                instructionText = ""
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.25) : Color(red: 0.55, green: 0.78, blue: 1.0))
            .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func actionButton(_ title: String, instruction: String) -> some View {
        Button(title) {
            sendInstruction(instruction)
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }

    private func sendInstruction(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.sendLogInstruction(instruction: trimmed, transcript: logModel.transcriptText())
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
