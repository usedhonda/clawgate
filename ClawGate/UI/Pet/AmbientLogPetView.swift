import AppKit
import SwiftUI

private let petLogThreadPaneFractionKey = "PetLogThreadPaneFraction"
private let petLogThreadPaneDefaultFraction: CGFloat = 0.65
private let petLogThreadPaneMinFraction: CGFloat = 0.25
private let petLogThreadPaneMaxFraction: CGFloat = 0.7
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
    let attributedTranscript: NSAttributedString
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
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
            textView.textStorage?.setAttributedString(attributedTranscript)
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

    /// D17/D45 single source of truth for a scene selection. Both the display
    /// path and the query path resolve a (possibly stale) `selection` against
    /// the SAME current, uncapped `scenes`, so "visible on screen but 0 sent"
    /// is structurally impossible.
    ///
    /// A stale id (`Scene.id = String(Int(firstEpoch))` shifts when an older
    /// late/backfill segment joins the scene) is reconciled to the unique
    /// current scene whose `[startEpoch, endEpoch]` now contains that epoch;
    /// if it maps to no scene, an ambiguous set, or is non-numeric, the WHOLE
    /// selection is dropped (explicit clear) so display and query fall back to
    /// the SAME full-day scope — never a display-only widen.
    ///
    /// Returns the reconciled selection (migrated ids, or empty when cleared),
    /// the scope ids for `scopeOverride` (nil = full-day automatic), and the
    /// in-scope segments (`daySegments` when full-day; a non-empty scene union
    /// otherwise).
    static func resolveScope(selection: Set<String>,
                             scenes: [Scene],
                             daySegments: [TranscriptSegment])
        -> (selection: Set<String>, scopeIDs: [String]?, segments: [TranscriptSegment]) {
        guard !selection.isEmpty else { return ([], nil, daySegments) }
        var reconciled: Set<String> = []
        for id in selection {
            if scenes.contains(where: { $0.id == id }) {
                reconciled.insert(id)
                continue
            }
            guard let epoch = Double(id) else { return ([], nil, daySegments) }
            let containing = scenes.filter { $0.startEpoch <= epoch && epoch <= $0.endEpoch }
            guard containing.count == 1 else { return ([], nil, daySegments) }
            reconciled.insert(containing[0].id)
        }
        let inScope = scenes.filter { reconciled.contains($0.id) }
        return (reconciled, reconciled.sorted(), inScope.flatMap(\.segments))
    }
}

// internal (not private): test seam for AmbientLogModelThreadTranscriptTests.
final class AmbientLogModel: ObservableObject {
    @Published var blocks: [AmbientLogGrouping.Block] = []
    @Published private(set) var cachedTranscript: NSAttributedString
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var transcriptScrollRevision = 0
    @Published private(set) var threadTranscript: NSAttributedString
    @Published private(set) var threadTranscriptRevision = 0
    @Published private(set) var threadScrollRevision = 0
    @Published private(set) var fontSize: CGFloat
    @Published var scenes: [AmbientLogGrouping.Scene] = []
    @Published var selectedSceneIDs: Set<String> = []
    @Published var selectedDay: Date
    var sceneNames: [String: String] = [:]
    private var requestedNamingDay: Date?
    private let timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
    // D21: computed (not a lazy var) so the background query build never races a
    // first-access lazy initialization — `Calendar`/`TimeZone` are value types,
    // so a fresh local copy per access is thread-safe with no shared mutation.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
    // Past days cache uncapped scenes + raw segments so scene identity stays
    // the SAME single source as the query path (D17). Blocks are re-derived
    // from these per load (a display cap is applied then, not to identity).
    // D38: the cache is keyed alongside the day's on-disk fingerprint so a late
    // write to a past day invalidates it instead of being hidden.
    private var cachedScenesByDay: [Date: [AmbientLogGrouping.Scene]] = [:]
    private var cachedRawSegmentsByDay: [Date: [TranscriptSegment]] = [:]
    private var cachedDayFingerprintByDay: [Date: String] = [:]
    private var lastPublishedDay: Date?
    private var cachedTranscriptFontSize: CGFloat
    private var cachedThreadSignature = ""
    private var timer: Timer?
    // D21: heavy load work (storage scan, scene/block rebuild, transcript
    // render) runs on this serial background queue; only the publish returns to
    // main. `lastLoadedFingerprint` lets an unchanged poll skip the rebuild.
    private let loadQueue = DispatchQueue(label: "com.clawgate.ambientlog.load", qos: .userInitiated)
    private var lastLoadedFingerprint: String?
    // D21: the owner generation bumps whenever the selection or day changes. A
    // backgrounded query snapshots it at preparation; the main-thread commit
    // dispatches only if it still matches, so a chip change mid-preparation
    // cancels the stale query instead of dispatching an outdated scope.
    private(set) var queryGeneration = 0
    // D21: the per-action-click owner. Each `startLogQuery` bumps it, so a rapid
    // second click supersedes the first (latest-only commit) — distinct from
    // `queryGeneration` (the scope/day owner that drives rebuild-on-mismatch). A
    // superseded query is DROPPED (never rebuilt); a scope change rebuilds.
    private(set) var actionEpoch = 0
    // D21: distinct from the generation — a stop() (view gone) flips this off so
    // an in-flight query's commit-mismatch path drops instead of rebuilding. The
    // generation bump alone invalidates the stale dispatch; this prevents a
    // rebuild-and-dispatch after the view is gone.
    private var queryLifecycleActive = true
    // D21: an action-click sets this immediately so the UI can show a "preparing"
    // status while the envelope is built off-main; the commit clears it.
    @Published private(set) var isPreparingLogQuery = false

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        selectedDay = cal.startOfDay(for: Date())
        let size = min(max(ConfigStore().load().ambientLogFontSize, petLogMinFontSize), petLogMaxFontSize)
        fontSize = size
        cachedTranscriptFontSize = size
        cachedTranscript = AmbientLogPetView.nsAttributedTranscript([], fontSize: size)
        threadTranscript = AmbientLogPetView.nsAttributedThreadTranscript([], fontSize: size)
    }

    func start() {
        queryLifecycleActive = true
        // D92/D152: idempotent — a second start() (e.g. a duplicate onAppear)
        // must not arm a second 3-second Timer that stop() can't reach, AND must
        // not re-enqueue a heavy load(). The guard runs BEFORE load(), so a
        // duplicate start() while already polling returns without scanning
        // storage; the first start() (or a start() after stop()) loads once.
        guard timer == nil else { return }
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // D21: invalidate any in-flight query. The generation bump makes its
        // commit fail; `queryLifecycleActive = false` stops the mismatch path
        // from rebuilding — no dispatch happens after the view is gone.
        queryLifecycleActive = false
        queryGeneration += 1
        isPreparingLogQuery = false
    }

    deinit {
        timer?.invalidate()
    }

    #if DEBUG
    /// Test seam: the current poll timer (private), so a test can assert start()
    /// is idempotent (repeated start keeps the SAME single timer, D92).
    var pollTimerForTesting: Timer? { timer }
    /// Test seam: how many times `load()` was invoked, so a test can assert a
    /// duplicate start() does NOT re-enqueue a heavy load (D152).
    private(set) var loadCallCountForTesting = 0
    #endif

    func moveDay(by days: Int) {
        guard let day = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        selectedSceneIDs = []
        selectedDay = clampedDay(day)
        queryGeneration += 1
        load()
    }

    func jumpToToday() {
        selectedSceneIDs = []
        selectedDay = today
        queryGeneration += 1
        load()
    }

    func selectAllScenes() {
        selectedSceneIDs = []
        queryGeneration += 1
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
        queryGeneration += 1
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

    /// Builds the query-time context envelope for a Log action (preset,
    /// custom slot, or free text). Unlike `blocks`/`cachedTranscript`, this
    /// reads the full raw history for `selectedDay` straight from
    /// `AmbientStorage` — no 2000-segment or fixed-character display cut.
    /// Anchor is "now" for today, or that day's own coverage tail for a past
    /// day, so a past-day query never leaks content beyond that day and a
    /// same-day query never leaks content at/after the moment it was sent.
    /// An explicit scene selection is a hard scope override: only that
    /// scene's segments are included, anchor-filtered the same way.
    /// D21: this is a PURE resolver — it takes `day`/`selection` as snapshotted
    /// inputs (defaulting to the current published state for direct callers) and
    /// does NOT mutate any published state. The reconciled selection travels back
    /// in the envelope's `scopeOverride`; publishing it (and dispatching) is the
    /// caller's job on the main thread, guarded by the owner generation so a
    /// chip change mid-preparation cancels the stale query.
    func buildQueryEnvelope(actionId: String, instruction: String, now: Date = Date(),
                            day: Date? = nil, selection: Set<String>? = nil,
                            sessionsRoot: URL = AmbientStorage.sessionsRoot) -> PetLogQueryEnvelope {
        let day = day ?? selectedDay
        let selection = selection ?? selectedSceneIDs
        let daySegments = AmbientStorage.segments(forDay: day, timeZone: timeZone, sessionsRoot: sessionsRoot)

        let anchor: Date
        if day == today {
            anchor = now
        } else if let lastEpoch = daySegments.last?.capturedAt {
            anchor = Date(timeIntervalSince1970: lastEpoch).addingTimeInterval(1)
        } else if let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) {
            anchor = dayEnd
        } else {
            anchor = now
        }
        let anchorEpoch = anchor.timeIntervalSince1970

        // D17/D45: display and query share one scope resolution. A stale
        // selection is reconciled to the current scene it belongs to, or — if
        // irreconcilable — explicitly cleared so BOTH the chip/UI and this
        // envelope fall back to the same full-day scope. This replaces the old
        // "hard scope, segments empty, scopeOverride still set" stopgap, which
        // was the "visible full day / send 0" divergence D45 targets.
        let daysScenes = AmbientLogGrouping.scenes(from: daySegments, timeZone: timeZone)
        let resolved = AmbientLogGrouping.resolveScope(
            selection: selection, scenes: daysScenes, daySegments: daySegments)
        let candidateSegments: [TranscriptSegment]
        let scopeOverride: [String]?
        // D20/D153: automatic retrieval never stops at a gap; it supplies the
        // cross-day window ending at the anchor and reports whether older history
        // exists beyond it (`truncatedBeforeCoverage`). Unlike the old fail-closed
        // signal this does NOT refuse — the flag travels to the model (v3), which
        // answers only with a high-confidence boundary. Explicit scope is always
        // non-truncated (day-scoped exact-all).
        let retrievalTruncatedBeforeCoverage: Bool
        // D159/D163: source-completeness issue found by the backward scan.
        let sourceReadIncomplete: Bool
        // D156: an explicit selection that reconciled to nothing.
        var staleScopeCleared = false
        if let ids = resolved.scopeIDs {
            candidateSegments = resolved.segments
            scopeOverride = ids
            retrievalTruncatedBeforeCoverage = false
            sourceReadIncomplete = false
        } else if !selection.isEmpty {
            // D156: the user's explicit scene selection is irreconcilable (its
            // scene id no longer exists / is ambiguous). Do NOT silently widen it
            // to the full automatic scope within this same click — clear it and
            // cancel the action (staleScopeRefused). The NEXT click, now with no
            // selection, uses automatic scope. This replaces the old D45
            // clear-and-auto-expand-in-one-click behavior.
            candidateSegments = []
            scopeOverride = nil
            retrievalTruncatedBeforeCoverage = false
            sourceReadIncomplete = false
            staleScopeCleared = true
        } else if day != today && daySegments.isEmpty {
            // D155: a non-today automatic query needs a coverage-tail anchor from
            // the SELECTED day itself. An empty past day has none — do NOT fall
            // back to the day-end anchor and fetch the previous 48h (that would
            // silently send another day's history for a visibly empty day).
            // Produce an empty scope so admission refuses it (D3 empty-scope).
            candidateSegments = []
            scopeOverride = nil
            retrievalTruncatedBeforeCoverage = false
            sourceReadIncomplete = false
        } else {
            let scan = AmbientStorage.scanBackward(
                anchor: anchor, timeZone: timeZone, sessionsRoot: sessionsRoot)
            candidateSegments = scan.window
            scopeOverride = nil
            retrievalTruncatedBeforeCoverage = scan.truncatedBeforeCoverage
            sourceReadIncomplete = scan.hasSourceIssue
        }

        // Every segment here is expected to already carry a capturedAt
        // (AmbientStorage.segments only returns timestamped segments). If
        // one somehow doesn't, we can't verify it's before the anchor, so it
        // is excluded rather than optimistically included — and the query
        // is marked incomplete rather than silently guaranteeing a coverage
        // cutoff it didn't actually enforce for every segment.
        var completeBeforeAnchor = true
        let anchorFiltered = candidateSegments.filter { seg in
            guard let at = seg.capturedAt else {
                completeBeforeAnchor = false
                return false
            }
            return at < anchorEpoch
        }
        // D16(a): remove noise/exact-adjacent (reduce) then overlap re-emits
        // (dedupOverlap). Both are deterministic and independent of the budget.
        let reduced = PetLogSegmentReducer.dedupOverlap(PetLogSegmentReducer.reduce(anchorFiltered))
        // D16(a)/D41 safety: two segments must never share an id — the parser
        // rejects duplicate allowed ids, so an envelope carrying a dup would fail
        // its own parse. Deterministic keep-first id dedup guards that.
        var seenIDs = Set<String>()
        let rawSegments = reduced.compactMap { seg -> PetLogRawSegment? in
            let id = PetLogSegmentID.make(for: seg)
            guard seenIDs.insert(id).inserted else { return nil }
            return PetLogRawSegment(
                id: id,
                capturedAt: seg.capturedAt,
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                speaker: seg.speaker,
                text: seg.text
            )
        }
        let coverageEpochs = rawSegments.compactMap(\.capturedAt)
        let coverageStart = coverageEpochs.min().map { Date(timeIntervalSince1970: $0) }
        let coverageEnd = coverageEpochs.max().map { Date(timeIntervalSince1970: $0) }

        return PetLogQueryEnvelope(
            requestId: UUID().uuidString,
            actionId: actionId,
            instruction: instruction,
            queryTimestamp: now,
            anchorTimestamp: anchor,
            scopeOverride: scopeOverride,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            completeBeforeAnchor: completeBeforeAnchor,
            segments: rawSegments,
            retrievalTruncatedBeforeCoverage: retrievalTruncatedBeforeCoverage,
            sourceReadIncomplete: sourceReadIncomplete,
            staleScopeCleared: staleScopeCleared
        )
    }

    /// A query built off the main thread, tagged with the owner generation and
    /// day it was prepared under (D21).
    struct PreparedLogQuery {
        let envelope: PetLogQueryEnvelope
        let generation: Int
        let day: Date
        // D21: the action-click owner this query was prepared under.
        var actionEpoch: Int = 0
    }

    /// D21 production path: prepare the query envelope on the background queue
    /// (storage read + scope resolution, snapshot inputs only, no shared-state
    /// access) and dispatch on the main thread — but only if the owner generation
    /// still matches (no chip/day change since preparation). If the selection or
    /// day changed mid-preparation, the stale envelope is dropped and the query
    /// is rebuilt from the latest snapshot so the action still resolves with the
    /// corrected scope — UNLESS the model was stopped (view gone), in which case
    /// it is dropped with no dispatch. Shows an immediate "preparing" status.
    func startLogQuery(actionId: String, instruction: String, now: Date = Date(),
                       sessionsRoot: URL = AmbientStorage.sessionsRoot,
                       dispatch: @escaping (PetLogQueryEnvelope, Date) -> Void) {
        // D21: a fresh action-click owns the query from here on — a rapid second
        // click supersedes an in-flight first one (latest-only).
        actionEpoch += 1
        isPreparingLogQuery = true
        enqueueLogQueryBuild(actionId: actionId, instruction: instruction, now: now,
                             epoch: actionEpoch, sessionsRoot: sessionsRoot, dispatch: dispatch)
    }

    /// One prepare→commit cycle: snapshot the owner generation/day/selection,
    /// build off-main from those snapshots only, and commit on main. A newer
    /// action click supersedes this one (drop, no rebuild); a scope/day change
    /// under the SAME action rebuilds (if still active); a stop() drops it.
    private func enqueueLogQueryBuild(actionId: String, instruction: String, now: Date, epoch: Int,
                                      sessionsRoot: URL,
                                      dispatch: @escaping (PetLogQueryEnvelope, Date) -> Void) {
        let generation = queryGeneration
        let day = selectedDay
        let selection = selectedSceneIDs
        loadQueue.async { [weak self] in
            guard let self else { return }
            let envelope = self.buildQueryEnvelope(
                actionId: actionId, instruction: instruction, now: now,
                day: day, selection: selection, sessionsRoot: sessionsRoot)
            DispatchQueue.main.async {
                let prepared = PreparedLogQuery(envelope: envelope, generation: generation,
                                                day: day, actionEpoch: epoch)
                if self.commitPreparedLogQuery(prepared, dispatch: dispatch) {
                    self.isPreparingLogQuery = false
                    return
                }
                // The commit was refused. If a NEWER action click superseded this
                // one, drop it silently — the newer query owns the preparing state
                // and will dispatch. Otherwise the scope/day changed under the
                // SAME action: rebuild from the latest snapshot while active.
                guard epoch == self.actionEpoch else { return }
                guard self.queryLifecycleActive else {
                    self.isPreparingLogQuery = false
                    return
                }
                self.enqueueLogQueryBuild(actionId: actionId, instruction: instruction, now: now,
                                          epoch: epoch, sessionsRoot: sessionsRoot, dispatch: dispatch)
            }
        }
    }

    /// Prepares a query synchronously against the current snapshot (test seam and
    /// the building block for `startLogQuery`). Pure: it does not publish.
    func prepareLogQuery(actionId: String, instruction: String, now: Date = Date(),
                         sessionsRoot: URL = AmbientStorage.sessionsRoot) -> PreparedLogQuery {
        let envelope = buildQueryEnvelope(
            actionId: actionId, instruction: instruction, now: now,
            day: selectedDay, selection: selectedSceneIDs, sessionsRoot: sessionsRoot)
        return PreparedLogQuery(envelope: envelope, generation: queryGeneration,
                                day: selectedDay, actionEpoch: actionEpoch)
    }

    /// Main-thread commit: dispatch only if the query is still current (owner
    /// generation unchanged since preparation). Publishes the reconciled
    /// selection (derived from the envelope's scope) so the chip and the query
    /// agree, then dispatches. Returns whether it dispatched.
    @discardableResult
    func commitPreparedLogQuery(_ prepared: PreparedLogQuery,
                                dispatch: (PetLogQueryEnvelope, Date) -> Void) -> Bool {
        // D21 latest-only: a newer action click supersedes this query.
        guard prepared.actionEpoch == actionEpoch else { return false }
        // D21 owner generation: a scope/day change invalidates this query.
        guard prepared.generation == queryGeneration else { return false }
        let resolved: Set<String> = prepared.envelope.scopeOverride.map { Set($0) } ?? []
        if resolved != selectedSceneIDs { selectedSceneIDs = resolved }
        dispatch(prepared.envelope, prepared.day)
        return true
    }

    func updateThreadTranscript(entries: [NotificationEntry]) {
        let signature = entries.map { "\($0.id):\(Int($0.timestamp.timeIntervalSince1970))" }.joined(separator: "|") + "|\(fontSize)"
        guard signature != cachedThreadSignature else { return }
        cachedThreadSignature = signature
        threadTranscript = AmbientLogPetView.nsAttributedThreadTranscript(entries, fontSize: fontSize)
        threadTranscriptRevision += 1
        threadScrollRevision += 1
    }

    /// D21: the 3-second poll (and any triggered reload) must not scan storage,
    /// rebuild scenes/blocks, or render the transcript on the main thread. The
    /// main thread only snapshots the inputs and enqueues; the heavy work runs
    /// on a serial background queue; only the final publish returns to main. A
    /// fingerprint of the inputs skips the rebuild entirely when nothing changed.
    private func load() {
        #if DEBUG
        loadCallCountForTesting += 1
        #endif
        let day = clampedDay(selectedDay)
        if day != selectedDay { selectedDay = day }
        // Snapshot the main-thread inputs (selection, font, per-day cache) so the
        // background closure never touches published/instance state directly.
        let selectionSnapshot = selectedSceneIDs
        let font = fontSize
        let isToday = (day == today)
        let cachedScenes = isToday ? nil : cachedScenesByDay[day]
        let cachedRaw = isToday ? nil : cachedRawSegmentsByDay[day]
        let cachedDayFingerprint = isToday ? nil : cachedDayFingerprintByDay[day]
        let previousFingerprint = lastLoadedFingerprint
        let previousDay = lastPublishedDay
        let tz = timeZone

        loadQueue.async { [weak self] in
            guard let self else { return }
            // D17: scene identity is generated from the UNCAPPED day segments —
            // the same source the query path reads — off the main thread.
            let daySegments: [TranscriptSegment]
            let newScenes: [AmbientLogGrouping.Scene]
            var dayFingerprintToStore: String?
            // D38: the day's on-disk fingerprint (full sub-second mtime + size)
            // is folded into the input fingerprint below for past days, so a late
            // same-count rewrite still forces a republish. "today" for the live
            // day (no per-day cache; live capture changes count/first/last).
            let dayDiskFingerprint: String
            if !isToday {
                // D38: only trust the past-day cache while the day's on-disk
                // fingerprint is unchanged; a late write invalidates it.
                let preFingerprint = AmbientStorage.dayFingerprint(forDay: day, timeZone: tz)
                if let cachedScenes, let cachedRaw, cachedDayFingerprint == preFingerprint {
                    daySegments = cachedRaw
                    newScenes = cachedScenes
                    dayDiskFingerprint = preFingerprint
                } else {
                    daySegments = AmbientStorage.segments(forDay: day, timeZone: tz)
                    newScenes = AmbientLogGrouping.scenes(from: daySegments, timeZone: tz)
                    // D38 two-phase: re-read the fingerprint AFTER the decode (still
                    // off-main). The just-decoded content is published under the
                    // post-decode fingerprint; the cache is only trusted (stored)
                    // when the on-disk state was stable across the read, so a write
                    // that raced the decode is not cached as authoritative and the
                    // next poll re-reads it.
                    let postFingerprint = AmbientStorage.dayFingerprint(forDay: day, timeZone: tz)
                    dayDiskFingerprint = postFingerprint
                    dayFingerprintToStore = (postFingerprint == preFingerprint) ? postFingerprint : nil
                }
            } else {
                dayDiskFingerprint = "today"
                daySegments = AmbientStorage.segments(forDay: day, timeZone: tz)
                newScenes = AmbientLogGrouping.scenes(from: daySegments, timeZone: tz)
            }
            // D45: reconcile a stale selection against the current scenes so the
            // display and query paths agree (migrate or clear).
            let resolved = AmbientLogGrouping.resolveScope(
                selection: selectionSnapshot, scenes: newScenes, daySegments: daySegments)
            // Cheap input fingerprint — ambient segments are append/backfill only,
            // so count + first/last capturedAt + selection + font identifies the
            // output; the day disk fingerprint (D38) closes the same-count rewrite
            // hole. Unchanged fingerprint => skip the rebuild and publish.
            let firstAt = daySegments.first?.capturedAt ?? 0
            let lastAt = daySegments.last?.capturedAt ?? 0
            let fingerprint = "\(Int(day.timeIntervalSince1970))|\(daySegments.count)|\(firstAt)|\(lastAt)|\(dayDiskFingerprint)|\(resolved.selection.sorted().joined(separator: ","))|\(font)"
            if fingerprint == previousFingerprint {
                return
            }
            // Display cap: render at most the newest 2000 in-scope segments. This
            // never affects scene identity (generated uncapped above).
            let scopeSegments = resolved.segments
            let displaySegments = scopeSegments.count > 2000 ? Array(scopeSegments.suffix(2000)) : scopeSegments
            let newBlocks = AmbientLogGrouping.blocks(from: displaySegments, timeZone: tz)
            let attributed = AmbientLogPetView.nsAttributedTranscript(newBlocks, fontSize: font)

            DispatchQueue.main.async {
                // Discard if the day changed while this build was in flight — a
                // newer load() for the current day will publish the right result.
                guard self.clampedDay(self.selectedDay) == day else { return }
                if !isToday {
                    self.cachedRawSegmentsByDay[day] = daySegments
                    self.cachedScenesByDay[day] = newScenes
                    if let dayFingerprintToStore {
                        self.cachedDayFingerprintByDay[day] = dayFingerprintToStore
                    }
                }
                self.lastLoadedFingerprint = fingerprint
                if resolved.selection != self.selectedSceneIDs { self.selectedSceneIDs = resolved.selection }
                if newScenes != self.scenes { self.scenes = newScenes }
                let blocksChanged = newBlocks != self.blocks
                let fontSizeChanged = self.cachedTranscriptFontSize != font
                // D38: only auto-scroll to bottom for today (follow live capture)
                // or when the day just changed (navigation). A past-day content
                // update (late append while reading) refreshes without yanking
                // the scroll position.
                let dayChanged = (previousDay != day)
                self.lastPublishedDay = day
                if blocksChanged {
                    self.blocks = newBlocks
                    if isToday || dayChanged {
                        self.transcriptScrollRevision += 1
                    }
                }
                if blocksChanged || fontSizeChanged {
                    self.cachedTranscript = attributed
                    self.cachedTranscriptFontSize = font
                    self.transcriptRevision += 1
                }
            }
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
    private static let key = "PetLogCustomActionsV2"
    private static let legacyKey = "pet.logCustomActions"
    private static let legacyAlternateKey = "PetLogCustomActions"
    private static let slotCount = 8
    private static let defaultActions: [LogCustomAction?] = [
        LogCustomAction(label: "質問まとめ", prompt: """
            この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
            相手の発言を中心に読み、主張の根拠が弱い点、矛盾している点、まだ答えていない点、曖昧なまま進んでいる前提を洗い出して、相手に投げるべき鋭い確認質問を作って。
            出力は優先度順に最大7件の箇条書き。各項目は「質問: ... / 狙い: ... / 根拠: 相手のどの発言からそう判断したか」の形にして。
            ご主人様が既に明確に答えている内容は質問にしないで。
            """),
        LogCustomAction(label: "要点", prompt: """
            この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
            単なる要約ではなく、会話の構造を分析して、(1) ご主人様が求めていること、(2) 相手が実際に答えたこと、(3) まだ噛み合っていない点、(4) 次に判断すべき論点、を分けて整理して。
            出力は3〜5個の箇条書き。各項目は短い見出し + 1文の説明にして、相手の発言に依存する要点は「相手曰く」と分かるように書いて。
            """),
        LogCustomAction(label: "TODO", prompt: """
            この会話ログでは、話者ラベル「ご主人様」はこちら側、「相手」は会話の相手方として扱って。
            会話から実行すべきTODOを抽出し、担当を「ご主人様」「相手」「未確定」に分けて整理して。相手の発言に依存するTODOは、相手が本当に引き受けたのか、それともこちらが確認すべきなのかを区別して。
            出力は箇条書きで、各項目を「担当 / TODO / 期限・条件 / 確認すべき不明点」の形にして。期限や担当が読めない場合は推測せず「未確定」と書いて。
            """),
        LogCustomAction(label: "区切り", prompt: "私のカレンダーの予定に照らして、この会話ログをどの時点で区切るのが自然か提案して。予定はあなたが把握しているものを使って。"),
        nil,
        nil,
        nil,
        nil,
    ]

    static func load() -> [LogCustomAction?] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LogCustomAction?].self, from: data) {
            return normalized(decoded)
        }
        if let legacy = loadLegacyActions() {
            var migrated = defaultActions
            for (offset, action) in legacy.prefix(4).enumerated() {
                migrated[offset + 4] = action
            }
            save(migrated)
            return migrated
        }
        return defaultActions
    }

    static func save(_ actions: [LogCustomAction?]) {
        let clamped = normalized(actions)
        guard let data = try? JSONEncoder().encode(clamped) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func normalized(_ actions: [LogCustomAction?]) -> [LogCustomAction?] {
        Array(actions.prefix(slotCount)) + Array(repeating: nil, count: max(0, slotCount - actions.count))
    }

    private static func loadLegacyActions() -> [LogCustomAction?]? {
        for legacyKey in [legacyKey, legacyAlternateKey] {
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let decoded = try? JSONDecoder().decode([LogCustomAction?].self, from: data) {
                return Array(decoded.prefix(4)) + Array(repeating: nil, count: max(0, 4 - decoded.count))
            }
        }
        return nil
    }
}

/// "Log" tab in the pet chat panel: the ambient transcript of the surrounding
/// conversation (most recent session), grouped into time-stamped paragraphs.
/// Machine transcript — context, not quote-safe record.
struct AmbientLogPetView: View {
    @ObservedObject var model: PetModel
    @StateObject private var logModel = AmbientLogModel()
    @State private var instructionText = ""
    @State private var customActions: [LogCustomAction?] = Array(repeating: nil, count: 8)
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
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            var headText = block.timeLabel ?? ""
            if let name = speakerName(block.speaker) {
                headText += headText.isEmpty ? name : " " + name
            }
            if !headText.isEmpty {
                out += AttributedString(headText + "\n")
            }
            out += AttributedString(block.text)
        }
        return out
    }

    static func nsAttributedTranscript(_ blocks: [AmbientLogGrouping.Block], fontSize: CGFloat = 16) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headerSize = fontSize * 0.75
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n\n")) }
            var headText = block.timeLabel ?? ""
            if let name = speakerName(block.speaker) {
                headText += headText.isEmpty ? name : " " + name
            }
            if !headText.isEmpty {
                out.append(NSAttributedString(string: headText + "\n", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: headerSize, weight: .bold),
                    .foregroundColor: speakerNSColor(block.speaker),
                    .paragraphStyle: paragraph,
                ]))
            }
            out.append(NSAttributedString(string: block.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph,
            ]))
        }
        return out
    }

    static func speakerNSColor(_ speaker: String?) -> NSColor {
        speaker == "self"
            ? NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)
            : NSColor.white.withAlphaComponent(0.6)
    }

    static func nsAttributedThreadTranscript(_ entries: [NotificationEntry], fontSize: CGFloat = 16) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headerSize = fontSize * 0.75
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 10
        for (i, entry) in entries.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let header = "\(threadTimeString(entry.timestamp))  \(threadSpeakerName(entry.source))\n"
            out.append(NSAttributedString(string: header, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: headerSize, weight: .bold),
                .foregroundColor: threadSpeakerNSColor(entry.source),
                .paragraphStyle: paragraph,
            ]))
            out.append(NSAttributedString(string: entry.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.white.withAlphaComponent(0.86),
                .paragraphStyle: paragraph,
            ]))
            if entry.logMetadata?.isUncertain == true {
                let noticeSize = fontSize * 0.8
                let noticeFont = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: noticeSize), toHaveTrait: .italicFontMask)
                out.append(NSAttributedString(string: "\n⚠ 文脈の判定に確信が持てません", attributes: [
                    .font: noticeFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                    .paragraphStyle: paragraph,
                ]))
            }
            if entry.logMetadata?.dispatch?.degraded == true {
                let noticeSize = fontSize * 0.8
                let noticeFont = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: noticeSize), toHaveTrait: .italicFontMask)
                out.append(NSAttributedString(string: "\n⚠ Solを利用できずTerraで処理しました", attributes: [
                    .font: noticeFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                    .paragraphStyle: paragraph,
                ]))
            }
        }
        return out
    }

    static func threadSpeakerName(_ source: String) -> String {
        source == "log_user" ? "ご主人様" : "ちー"
    }

    static func threadTimeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    static func threadSpeakerNSColor(_ source: String) -> NSColor {
        source == "log_user"
            ? NSColor(calibratedRed: 0.55, green: 0.78, blue: 1.0, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.46, alpha: 1)
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
            syncThreadTranscript()
            scheduleSceneNamesIfNeeded()
        }
        .onReceive(model.$logReplies) { entries in
            logModel.updateThreadTranscript(entries: entries)
        }
        .onChange(of: logModel.fontSize) { _ in
            syncThreadTranscript()
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
                Button("全文コピー") {
                    copyThreadTranscript()
                }
                .buttonStyle(PetPressableButtonStyle())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(model.logReplies.isEmpty ? .white.opacity(0.25) : Color(red: 0.55, green: 0.78, blue: 1.0))
                .disabled(model.logReplies.isEmpty)
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
                AmbientTranscriptTextView(
                    attributedTranscript: logModel.threadTranscript,
                    textRevision: logModel.threadTranscriptRevision,
                    scrollRevision: logModel.threadScrollRevision
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.logAwaitingReply {
                awaitingReplyStatus
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

    private var awaitingReplyStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.55)
            Text("ちーが考え中…")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.72))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    private func syncThreadTranscript() {
        logModel.updateThreadTranscript(entries: model.logReplies)
    }

    private func copyThreadTranscript() {
        let text = logModel.threadTranscript.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var customActionBar: some View {
        VStack(spacing: 6) {
            customActionRow(0..<4)
            customActionRow(4..<8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// D3 minimal visible status: a fixed one-line note near the input bar for a
    /// typed dispatch status (e.g. "ログ不足"). Cleared owner-scoped by the next
    /// accepted request / answer (in PetModel). The full status banner/retry UI
    /// is a later Wave.
    private func dispatchStatusText(_ status: PetLogDispatchStatus) -> String {
        switch status {
        case .insufficientEvidence: return "根拠となるログが不足しています"
        case .emptyScopeRefused: return "対象のログがありません"
        case .historyIncompleteRefused:
            return "対象の履歴が大きすぎる/古すぎるため送信できません。シーン選択や対象範囲を狭めてください"
        case .sourceReadIncompleteRefused:
            return "ログの一部を読み取れなかったため送信できません（破損・タイムスタンプ欠落）"
        case .staleScopeRefused:
            return "選択したシーンが見つからないため選択を解除しました。もう一度押すと全日を対象にします"
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // D21: immediate feedback while the envelope is built off-main. The
            // preparing state supersedes a prior dispatch status until the commit
            // resolves (accepted clears it, refused replaces it with a status).
            if logModel.isPreparingLogQuery {
                Text("準備中…")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            } else if let status = model.logDispatchStatus {
                Text(dispatchStatusText(status))
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.4))
            }
        HStack(spacing: 8) {
            TextField("ちーに聞く", text: $instructionText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            Button("送信") {
                sendInstruction(instructionText, actionId: "free") { instructionText = "" }
            }
            .buttonStyle(PetPressableButtonStyle())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor((instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.logAwaitingReply || logModel.isPreparingLogQuery) ? .white.opacity(0.25) : Color(red: 0.55, green: 0.78, blue: 1.0))
            .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.logAwaitingReply || logModel.isPreparingLogQuery)
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
        }
        .padding(12)
    }

    private func customActionButton(_ index: Int) -> some View {
        let action = customActions.indices.contains(index) ? customActions[index] : nil
        let isEditingExisting = editingCustomActions && action != nil
        let activeColor = isEditingExisting ? Color(red: 1.0, green: 0.72, blue: 0.32) : Color(red: 0.55, green: 0.78, blue: 1.0)
        return Button {
            if editingCustomActions || action == nil {
                beginEditingCustomAction(index)
            } else if let action {
                sendInstruction(action.prompt, actionId: "slot-\(index)")
            }
        } label: {
            HStack(spacing: 4) {
                if isEditingExisting {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(action?.label ?? "＋")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PetPressableButtonStyle())
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(action == nil ? .white.opacity(0.45) : activeColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEditingExisting ? activeColor.opacity(0.14) : Color.white.opacity(action == nil ? 0.04 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((action == nil ? Color(red: 0.55, green: 0.78, blue: 1.0) : activeColor).opacity(action == nil ? 0.16 : 0.55), lineWidth: 1)
        )
        .disabled(model.logAwaitingReply || logModel.isPreparingLogQuery)
        .opacity((model.logAwaitingReply || logModel.isPreparingLogQuery) ? 0.45 : 1)
    }

    private func customActionRow(_ range: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(range), id: \.self) { index in
                customActionButton(index)
                    .popover(isPresented: Binding(
                        get: { editingActionIndex == index },
                        set: { if !$0 { editingActionIndex = nil } }
                    )) {
                        customActionEditor(index)
                    }
            }
        }
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

    private func sendInstruction(_ instruction: String, actionId: String, onAccepted: (() -> Void)? = nil) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelPendingSceneNaming()
        // D21: build the envelope off the main thread; dispatch only if the
        // selection/day hasn't changed since preparation (owner generation).
        // D16/D60: the draft is cleared only when the send is actually accepted —
        // an incomplete/over-budget/busy/offline refusal keeps it for retry.
        logModel.startLogQuery(actionId: actionId, instruction: trimmed) { [model] envelope, day in
            if model.sendLogInstruction(envelope: envelope, selectedDay: day) {
                onAccepted?()
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
