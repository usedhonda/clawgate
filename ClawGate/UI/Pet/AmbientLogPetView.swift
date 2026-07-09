import AppKit
import SwiftUI

private let petLogThreadPaneFractionKey = "PetLogThreadPaneFraction"
private let petLogThreadPaneDefaultFraction: CGFloat = 0.43
private let petLogThreadPaneMinFraction: CGFloat = 0.25
private let petLogThreadPaneMaxFraction: CGFloat = 0.6
private let petLogThreadPaneMinPixelWidth: CGFloat = 240
private let petLogThreadPaneLeftMinWidth: CGFloat = 360
private let petLogThreadPaneHandleWidth: CGFloat = 8
private let petLogMinFontSize: CGFloat = 12
private let petLogMaxFontSize: CGFloat = 22

private func clampedLogThreadPaneFraction(_ fraction: CGFloat) -> CGFloat {
    min(max(fraction, petLogThreadPaneMinFraction), petLogThreadPaneMaxFraction)
}

private func preferredLogThreadPaneFraction() -> CGFloat {
    guard let stored = UserDefaults.standard.object(forKey: petLogThreadPaneFractionKey) as? Double else {
        return petLogThreadPaneDefaultFraction
    }
    return clampedLogThreadPaneFraction(CGFloat(stored))
}

private func saveLogThreadPaneFraction(_ fraction: CGFloat) {
    UserDefaults.standard.set(Double(clampedLogThreadPaneFraction(fraction)), forKey: petLogThreadPaneFractionKey)
}

private struct PetPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct PaneResizeHandleView: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> PaneResizeHandleNSView {
        PaneResizeHandleNSView(onDrag: onDrag, onEnd: onEnd)
    }

    func updateNSView(_ nsView: PaneResizeHandleNSView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private final class PaneResizeHandleNSView: NSView {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    init(onDrag: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
        self.onDrag = onDrag
        self.onEnd = onEnd
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            onDrag(gesture.translation(in: self).x)
        case .ended, .cancelled, .failed:
            onEnd()
            gesture.setTranslation(.zero, in: self)
        default:
            break
        }
    }
}


private struct AmbientTranscriptTextView: NSViewRepresentable {
    let attributedTranscript: AttributedString
    let textRevision: Int
    let scrollRevision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.lastTextRevision != textRevision {
            textView.textStorage?.setAttributedString(NSAttributedString(attributedTranscript))
            context.coordinator.lastTextRevision = textRevision
        }
        if context.coordinator.lastScrollRevision != scrollRevision {
            context.coordinator.lastScrollRevision = scrollRevision
            context.coordinator.scrollToBottom(textView)
        }
    }

    final class Coordinator {
        var lastTextRevision: Int?
        var lastScrollRevision: Int?

        func scrollToBottom(_ textView: NSTextView) {
            DispatchQueue.main.async {
                let location = textView.string.utf16.count
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            }
        }
    }
}

private struct ThreadPaneResizeHandleChrome: View {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(isHovering ? 0.08 : 0.001))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(Color.white.opacity(isHovering ? 0.28 : 0.12))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.55 : 0.35))
                        .frame(width: 2, height: 2)
                }
            }
            PaneResizeHandleView(onDrag: onDrag, onEnd: onEnd)
                .frame(width: petLogThreadPaneHandleWidth)
        }
        .frame(width: petLogThreadPaneHandleWidth)
        .frame(maxHeight: .infinity)
        .onHover { isHovering = $0 }
    }
}

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
    @Published private(set) var cachedTranscript: AttributedString
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var transcriptScrollRevision = 0
    @Published private(set) var fontSize: CGFloat
    @Published var scenes: [AmbientLogGrouping.Scene] = []
    @Published var selectedSceneIDs: Set<String> = []
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
    private var cachedTranscriptFontSize: CGFloat
    private var timer: Timer?

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        selectedDay = cal.startOfDay(for: Date())
        let size = min(max(ConfigStore().load().ambientLogFontSize, petLogMinFontSize), petLogMaxFontSize)
        fontSize = size
        cachedTranscriptFontSize = size
        cachedTranscript = AmbientLogPetView.attributedTranscript([], fontSize: size)
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
        selectedSceneIDs = []
        selectedDay = clampedDay(day)
        load()
    }

    func jumpToToday() {
        selectedSceneIDs = []
        selectedDay = today
        load()
    }

    func selectAllScenes() {
        selectedSceneIDs = []
        load()
    }

    func selectScene(_ id: String, toggling: Bool) {
        if toggling {
            if selectedSceneIDs.contains(id) {
                selectedSceneIDs.remove(id)
            } else {
                selectedSceneIDs.insert(id)
            }
        } else {
            selectedSceneIDs = [id]
        }
        load()
    }

    func adjustFontSize(by delta: CGFloat) {
        let next = clampedFontSize(fontSize + delta)
        guard next != fontSize else { return }
        fontSize = next
        var cfg = ConfigStore().load()
        cfg.ambientLogFontSize = next
        ConfigStore().save(cfg)
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

    func sceneNamingRequestPayloadIfNeeded(markRequested: Bool = false) -> [(id: String, timeLabel: String, excerpt: String)]? {
        guard isTodaySelected, scenes.count >= 2 else { return nil }
        guard requestedNamingDay != selectedDay else { return nil }
        if markRequested { requestedNamingDay = selectedDay }
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
            var segs = AmbientStorage.segments(forDay: day, timeZone: timeZone)
            if segs.count > 2000 { segs = Array(segs.suffix(2000)) }
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
        let selectedScenes = newScenes.filter { selectedSceneIDs.contains($0.id) }
        if !selectedSceneIDs.isEmpty, !selectedScenes.isEmpty {
            let selectedSegments = selectedScenes.flatMap(\.segments)
            newBlocks = AmbientLogGrouping.blocks(from: selectedSegments, timeZone: timeZone)
        } else {
            newBlocks = allBlocks
        }
        let blocksChanged = newBlocks != blocks
        let fontSizeChanged = cachedTranscriptFontSize != fontSize
        if blocksChanged {
            blocks = newBlocks
            transcriptScrollRevision += 1
        }
        if blocksChanged || fontSizeChanged {
            cachedTranscript = AmbientLogPetView.attributedTranscript(newBlocks, fontSize: fontSize)
            cachedTranscriptFontSize = fontSize
            transcriptRevision += 1
        }
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

    private func clampedFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, petLogMinFontSize), petLogMaxFontSize)
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
    @State private var threadPaneFraction: CGFloat = petLogThreadPaneDefaultFraction
    @State private var threadPaneDragStartFraction: CGFloat?
    @State private var sceneNamingWorkItem: DispatchWorkItem?

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
    static func attributedTranscript(_ blocks: [AmbientLogGrouping.Block], fontSize: CGFloat = 16) -> AttributedString {
        var out = AttributedString()
        let headerSize = fontSize * 0.75
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            var headText = block.timeLabel ?? ""
            if let name = speakerName(block.speaker) {
                headText += headText.isEmpty ? name : " " + name
            }
            if !headText.isEmpty {
                var head = AttributedString(headText + "\n")
                head.font = .system(size: headerSize, weight: .bold).monospacedDigit()
                head.foregroundColor = speakerColor(block.speaker)
                head.paragraphStyle = paragraph
                out += head
            }
            var body = AttributedString(block.text)
            body.font = .system(size: fontSize)
            body.foregroundColor = .white.opacity(0.85)
            body.paragraphStyle = paragraph
            out += body
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
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
                .frame(minWidth: petLogThreadPaneLeftMinWidth, maxWidth: .infinity, maxHeight: .infinity)

                if model.logThreadPaneOpen {
                    threadPaneResizeHandle(totalWidth: geo.size.width)
                    threadPane(totalWidth: geo.size.width)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.panelBg)
        .onAppear {
            customActions = LogCustomActionStore.load()
            threadPaneFraction = preferredLogThreadPaneFraction()
            logModel.start()
            scheduleSceneNamesIfNeeded()
        }
        .onChange(of: logModel.scenes) { _ in
            scheduleSceneNamesIfNeeded()
        }
        .onChange(of: model.logThreadPaneOpen) { open in
            if open { threadPaneFraction = preferredLogThreadPaneFraction() }
        }
        .onDisappear {
            cancelPendingSceneNaming()
            logModel.stop()
        }
    }

    private var dayNavBar: some View {
        HStack(spacing: 8) {
            Button("‹") {
                cancelPendingSceneNaming()
                logModel.moveDay(by: -1)
            }
                .buttonStyle(PetPressableButtonStyle())
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(logModel.canMovePrevious ? .white.opacity(0.75) : .white.opacity(0.22))
                .disabled(!logModel.canMovePrevious)
            Text(logModel.dayLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .frame(minWidth: 72)
            Button("›") {
                cancelPendingSceneNaming()
                logModel.moveDay(by: 1)
            }
                .buttonStyle(PetPressableButtonStyle())
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(logModel.canMoveNext ? .white.opacity(0.75) : .white.opacity(0.22))
                .disabled(!logModel.canMoveNext)
            Button("今日") {
                cancelPendingSceneNaming()
                logModel.jumpToToday()
            }
                .buttonStyle(PetPressableButtonStyle())
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(logModel.isTodaySelected ? .white.opacity(0.3) : Color(red: 0.55, green: 0.78, blue: 1.0))
                .disabled(logModel.isTodaySelected)
            Spacer()
            Button("A-") {
                cancelPendingSceneNaming()
                logModel.adjustFontSize(by: -1)
            }
                .buttonStyle(PetPressableButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(logModel.fontSize <= petLogMinFontSize ? .white.opacity(0.25) : .white.opacity(0.75))
                .disabled(logModel.fontSize <= petLogMinFontSize)
            Button("A+") {
                cancelPendingSceneNaming()
                logModel.adjustFontSize(by: 1)
            }
                .buttonStyle(PetPressableButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(logModel.fontSize >= petLogMaxFontSize ? .white.opacity(0.25) : .white.opacity(0.75))
                .disabled(logModel.fontSize >= petLogMaxFontSize)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sceneChipBar: some View {
        Group {
            if logModel.scenes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        sceneChip(title: "全日", selected: logModel.selectedSceneIDs.isEmpty) {
                            cancelPendingSceneNaming()
                            logModel.selectAllScenes()
                        }
                        ForEach(logModel.scenes, id: \.id) { scene in
                            sceneChip(
                                title: model.logSceneNames[scene.id] ?? logModel.sceneNames[scene.id] ?? scene.timeLabel,
                                selected: logModel.selectedSceneIDs.contains(scene.id)
                            ) {
                                cancelPendingSceneNaming()
                                logModel.selectScene(scene.id, toggling: NSEvent.modifierFlags.contains(.command))
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
        .buttonStyle(PetPressableButtonStyle())
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
        AmbientTranscriptTextView(
            attributedTranscript: logModel.cachedTranscript,
            textRevision: logModel.transcriptRevision,
            scrollRevision: logModel.transcriptScrollRevision
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threadPane(totalWidth: CGFloat) -> some View {
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
                .buttonStyle(PetPressableButtonStyle())
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
                            if model.logAwaitingReply {
                                awaitingReplyBubble
                                    .id("log-awaiting-reply")
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.logReplies.count) { _ in
                        scrollThreadToBottom(proxy)
                    }
                    .onChange(of: model.logAwaitingReply) { _ in
                        scrollThreadToBottom(proxy)
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            scrollThreadToBottom(proxy)
                        }
                    }
                }
            }
        }
        .frame(width: threadPaneWidth(totalWidth: totalWidth))
    }

    private func threadPaneResizeHandle(totalWidth: CGFloat) -> some View {
        ThreadPaneResizeHandleChrome(
            onDrag: { translationX in
                updateThreadPaneFraction(translationX: translationX, totalWidth: totalWidth)
            },
            onEnd: {
                saveLogThreadPaneFraction(threadPaneFraction)
                threadPaneDragStartFraction = nil
            }
        )
    }

    private func threadPaneWidth(totalWidth: CGFloat) -> CGFloat {
        let desired = totalWidth * threadPaneFraction
        let maxPaneWidth = max(0, totalWidth - petLogThreadPaneLeftMinWidth - petLogThreadPaneHandleWidth)
        if maxPaneWidth < petLogThreadPaneMinPixelWidth {
            return maxPaneWidth
        }
        return min(max(desired, petLogThreadPaneMinPixelWidth), maxPaneWidth)
    }

    private func updateThreadPaneFraction(translationX: CGFloat, totalWidth: CGFloat) {
        guard totalWidth > 0 else { return }
        let startFraction = threadPaneDragStartFraction ?? threadPaneFraction
        threadPaneDragStartFraction = startFraction
        let startWidth = totalWidth * startFraction
        threadPaneFraction = clampedLogThreadPaneFraction((startWidth - translationX) / totalWidth)
    }

    private var awaitingReplyBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("ちーが考え中…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.72))
                ProgressView()
                    .scaleEffect(0.55)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
            )
            Spacer(minLength: 36)
        }
    }

    private func scrollThreadToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if model.logAwaitingReply {
                proxy.scrollTo("log-awaiting-reply", anchor: .bottom)
            } else if let last = model.logReplies.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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
            actionButton("質問まとめ", instruction: """
                この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
                相手の発言を中心に読み、主張の根拠が弱い点、矛盾している点、まだ答えていない点、曖昧なまま進んでいる前提を洗い出して、相手に投げるべき鋭い確認質問を作って。
                出力は優先度順に最大7件の箇条書き。各項目は「質問: ... / 狙い: ... / 根拠: 相手のどの発言からそう判断したか」の形にして。
                ご主人様が既に明確に答えている内容は質問にしないで。
                """)
            actionButton("要点", instruction: """
                この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
                単なる要約ではなく、会話の構造を分析して、(1) ご主人様が求めていること、(2) 相手が実際に答えたこと、(3) まだ噛み合っていない点、(4) 次に判断すべき論点、を分けて整理して。
                出力は3〜5個の箇条書き。各項目は短い見出し + 1文の説明にして、相手の発言に依存する要点は「相手曰く」と分かるように書いて。
                """)
            actionButton("TODO", instruction: """
                この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
                会話から実行すべきTODOを抽出し、担当を「ご主人様」「相手」「未確定」に分けて整理して。相手の発言に依存するTODOは、相手が本当に引き受けたのか、それともこちらが確認すべきなのかを区別して。
                出力は箇条書きで、各項目を「担当 / TODO / 期限・条件 / 確認すべき不明点」の形にして。期限や担当が読めない場合は推測せず「未確定」と書いて。
                """)
            actionButton("区切り", instruction: "私のカレンダーの予定に照らして、この会話ログをどの時点で区切るのが自然か提案して。予定はあなたが把握しているものを使って。")
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
            .buttonStyle(PetPressableButtonStyle())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor((instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.logAwaitingReply) ? .white.opacity(0.25) : Color(red: 0.55, green: 0.78, blue: 1.0))
            .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.logAwaitingReply)
            Button(editingCustomActions ? "✓" : "✎") {
                editingCustomActions.toggle()
            }
            .buttonStyle(PetPressableButtonStyle())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(editingCustomActions ? Color(red: 0.55, green: 0.78, blue: 1.0) : .white.opacity(0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        }
        .padding(12)
    }

    private func actionButton(_ title: String, instruction: String) -> some View {
        Button(title) {
            sendInstruction(instruction)
        }
        .buttonStyle(PetPressableButtonStyle())
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        .disabled(model.logAwaitingReply)
        .opacity(model.logAwaitingReply ? 0.45 : 1)
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
        .buttonStyle(PetPressableButtonStyle())
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
        .disabled(model.logAwaitingReply)
        .opacity(model.logAwaitingReply ? 0.45 : 1)
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

    private func scheduleSceneNamesIfNeeded() {
        cancelPendingSceneNaming()
        guard logModel.sceneNamingRequestPayloadIfNeeded() != nil else { return }
        let workItem = DispatchWorkItem {
            guard !model.isSummonBusy else { return }
            guard let payload = logModel.sceneNamingRequestPayloadIfNeeded(markRequested: true) else { return }
            model.requestSceneNaming(scenes: payload)
        }
        sceneNamingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func cancelPendingSceneNaming() {
        sceneNamingWorkItem?.cancel()
        sceneNamingWorkItem = nil
    }

    private func sendInstruction(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelPendingSceneNaming()
        model.sendLogInstruction(instruction: trimmed, transcript: logModel.transcriptText())
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
