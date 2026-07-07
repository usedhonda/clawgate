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
    @Published var scenes: [AmbientLogGrouping.Scene] = []
    @Published var selectedSceneID: String?
    @Published var selectedDay: Date
    var sceneNames: [String: String] = [:]
    private var requestedNamingDay: Date?
    private let timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    private lazy var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }()
    private var cachedBlocksByDay: [Date: [AmbientLogGrouping.Block]] = [:]
    private var cachedScenesByDay: [Date: [AmbientLogGrouping.Scene]] = [:]
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
        selectedSceneID = nil
        selectedDay = clampedDay(day)
        load()
    }

    func jumpToToday() {
        selectedSceneID = nil
        selectedDay = today
        load()
    }

    func selectScene(_ id: String?) {
        selectedSceneID = id
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

    func sceneNamingRequestPayloadIfNeeded() -> [(id: String, timeLabel: String, excerpt: String)]? {
        guard isTodaySelected, scenes.count >= 2 else { return nil }
        guard requestedNamingDay != selectedDay else { return nil }
        requestedNamingDay = selectedDay
        return scenes.map { scene in
            let excerpt = scene.segments.prefix(4)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return (id: scene.id, timeLabel: scene.timeLabel, excerpt: excerpt)
        }
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
        let allBlocks: [AmbientLogGrouping.Block]
        let newScenes: [AmbientLogGrouping.Scene]
        if day == today {
            let (_, segs) = AmbientStorage.latestSessionSegments(limit: 2000)
            newScenes = AmbientLogGrouping.scenes(from: segs, timeZone: timeZone)
            allBlocks = AmbientLogGrouping.blocks(from: segs, timeZone: timeZone)
        } else if let cached = cachedBlocksByDay[day] {
            allBlocks = cached
            newScenes = cachedScenesByDay[day] ?? []
        } else {
            let segs = AmbientStorage.segments(forDay: day, timeZone: timeZone)
            newScenes = AmbientLogGrouping.scenes(from: segs, timeZone: timeZone)
            allBlocks = AmbientLogGrouping.blocks(from: segs, timeZone: timeZone)
            cachedBlocksByDay[day] = allBlocks
            cachedScenesByDay[day] = newScenes
        }
        if newScenes != scenes { scenes = newScenes }
        let newBlocks: [AmbientLogGrouping.Block]
        if let selectedSceneID,
           let scene = newScenes.first(where: { $0.id == selectedSceneID }) {
            newBlocks = AmbientLogGrouping.blocks(from: scene.segments, timeZone: timeZone)
        } else {
            newBlocks = allBlocks
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

struct LogCustomAction: Codable, Equatable {
    var label: String
    var prompt: String
}

enum LogCustomActionStore {
    private static let key = "pet.logCustomActions"

    static func load() -> [LogCustomAction?] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LogCustomAction?].self, from: data) else {
            return Array(repeating: nil, count: 4)
        }
        return Array(decoded.prefix(4)) + Array(repeating: nil, count: max(0, 4 - decoded.count))
    }

    static func save(_ actions: [LogCustomAction?]) {
        let clamped = Array(actions.prefix(4)) + Array(repeating: nil, count: max(0, 4 - actions.count))
        guard let data = try? JSONEncoder().encode(clamped) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// "Log" tab in the pet chat panel: the ambient transcript of the surrounding
/// conversation (most recent session), grouped into time-stamped paragraphs.
/// Machine transcript — context, not quote-safe record.
struct AmbientLogPetView: View {
    @ObservedObject var model: PetModel
    @StateObject private var logModel = AmbientLogModel()
    @State private var instructionText = ""
    @State private var customActions: [LogCustomAction?] = Array(repeating: nil, count: 4)
    @State private var editingCustomActions = false
    @State private var editingActionIndex: Int?
    @State private var draftCustomLabel = ""
    @State private var draftCustomPrompt = ""

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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                dayNavBar
                sceneChipBar
                Divider().opacity(0.12)
                Group {
                    if logModel.blocks.isEmpty {
                        emptyState
                    } else {
                        logList
                    }
                }
                actionBar
                customActionBar
                inputBar
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            if model.logThreadPaneOpen {
                Divider().opacity(0.12)
                threadPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.panelBg)
        .onAppear {
            customActions = LogCustomActionStore.load()
            logModel.start()
            requestSceneNamesIfNeeded()
        }
        .onChange(of: logModel.scenes) { _ in
            requestSceneNamesIfNeeded()
        }
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

    private var sceneChipBar: some View {
        Group {
            if logModel.scenes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        sceneChip(title: "全日", selected: logModel.selectedSceneID == nil) {
                            logModel.selectScene(nil)
                        }
                        ForEach(logModel.scenes, id: \.id) { scene in
                            sceneChip(
                                title: model.logSceneNames[scene.id] ?? logModel.sceneNames[scene.id] ?? scene.timeLabel,
                                selected: logModel.selectedSceneID == scene.id
                            ) {
                                logModel.selectScene(scene.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func sceneChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.isEmpty ? "Unknown" : title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selected ? .black.opacity(0.82) : .white.opacity(0.65))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(selected ? Color(red: 0.55, green: 0.78, blue: 1.0) : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
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

    private var threadPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ちーとの対話")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Button {
                    model.logThreadPaneOpen = false
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.12)

            if model.logReplies.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.18))
                    Text("まだ会話がありません")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.38))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.logReplies) { entry in
                                threadBubble(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.logReplies.count) { _ in
                        if let last = model.logReplies.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            if let last = model.logReplies.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 360)
    }

    private func threadBubble(_ entry: NotificationEntry) -> some View {
        let isUser = entry.source == "log_user"
        return HStack {
            if isUser { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 4) {
                Text(timeString(entry.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                Text(entry.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.84))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isUser ? Color(red: 0.55, green: 0.78, blue: 1.0).opacity(0.20) : Color.white.opacity(0.06))
            )
            if !isUser { Spacer(minLength: 36) }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            actionButton("質問まとめ", instruction: "この会話ログの中から、確認・回答すべき質問事項を箇条書きでまとめて。")
            actionButton("要点", instruction: "この会話ログの要点を3〜5個の箇条書きで簡潔にまとめて。")
            actionButton("TODO", instruction: "この会話ログから、やるべきこと(TODO)を抽出して。担当・期限が読み取れれば添えて。")
            actionButton("区切り", instruction: "私のカレンダーの予定に照らして、この会話ログをどの時点で区切るのが自然か提案して。予定はあなたが把握しているものを使って。")
            Color.clear
                .frame(width: 26)
                .padding(.vertical, 7)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var customActionBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                customActionButton(index)
                    .popover(isPresented: Binding(
                        get: { editingActionIndex == index },
                        set: { if !$0 { editingActionIndex = nil } }
                    )) {
                        customActionEditor(index)
                    }
            }
            Button(editingCustomActions ? "✓" : "✎") {
                editingCustomActions.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(editingCustomActions ? Color(red: 0.55, green: 0.78, blue: 1.0) : .white.opacity(0.45))
            .frame(width: 26)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
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

    private func customActionButton(_ index: Int) -> some View {
        let action = customActions.indices.contains(index) ? customActions[index] : nil
        return Button(action?.label ?? "＋") {
            if editingCustomActions || action == nil {
                beginEditingCustomAction(index)
            } else if let action {
                sendInstruction(action.prompt)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(action == nil ? .white.opacity(0.45) : Color(red: 0.55, green: 0.78, blue: 1.0))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(action == nil ? 0.04 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.55, green: 0.78, blue: 1.0).opacity(action == nil ? 0.16 : 0.35), lineWidth: 1)
        )
    }

    private func customActionEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Action")
                .font(.system(size: 12, weight: .semibold))
            TextField("Label", text: $draftCustomLabel)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $draftCustomPrompt)
                .font(.system(size: 12))
                .frame(width: 260, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12), lineWidth: 1))
            HStack {
                Button("削除") {
                    customActions[index] = nil
                    LogCustomActionStore.save(customActions)
                    editingActionIndex = nil
                }
                .disabled(customActions[index] == nil)
                Spacer()
                Button("保存") {
                    saveCustomAction(index)
                }
                .disabled(draftCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 284)
    }

    private func beginEditingCustomAction(_ index: Int) {
        let action = customActions.indices.contains(index) ? customActions[index] : nil
        draftCustomLabel = action?.label ?? ""
        draftCustomPrompt = action?.prompt ?? ""
        editingActionIndex = index
    }

    private func saveCustomAction(_ index: Int) {
        let prompt = draftCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let label = draftCustomLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        customActions[index] = LogCustomAction(label: label.isEmpty ? "Action \(index + 1)" : label, prompt: prompt)
        LogCustomActionStore.save(customActions)
        editingActionIndex = nil
    }

    private func requestSceneNamesIfNeeded() {
        guard let payload = logModel.sceneNamingRequestPayloadIfNeeded() else { return }
        model.requestSceneNaming(scenes: payload)
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
