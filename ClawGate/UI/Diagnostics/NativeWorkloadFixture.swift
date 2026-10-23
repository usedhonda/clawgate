#if DEBUG
import AppKit
import SwiftUI

/// Controlled local sources for native acceptance; no production store overrides.
final class NativeWorkloadFixture: ObservableObject {
    let model: PetModel
    let logModel = AmbientLogModel(zoneProvider: { TimeZone(secondsFromGMT: 0)! })
    let timelineModel = MainPanelModel()
    @Published var mode = "Log"
    @Published var preparationCompletions = 0
    @Published var candidateCompletions = 0
    @Published var displayCompletions = 0
    @Published var timelinePublications = 0
    private let completionLock = NSLock()
    private var completedBuildTimes: [TimeInterval] = []
    private var mainCompletionUpperBoundsMs: [Double] = []
    var beginAction: ((String) -> Int?)?
    var completeAction: ((Int?) -> Void)?
    private let sessions: URL
    private let store: MeetingStore
    private let timelineStore: OpsLogStore
    private var loader: MainPanelTimelineLoader?
    private var records: [MeetingRecord] = []
    private var segments: [TranscriptSegment] = []
    private var pendingDisplay: (id: Int?, day: Date, font: CGFloat, revision: Int)?
    private var pendingTimeline: Int?
    private var stopped = false

    init(root: URL, model: PetModel) throws {
        self.model = model
        sessions = root.appendingPathComponent("sessions")
        store = MeetingStore(root: root.appendingPathComponent("meetings"))
        timelineStore = OpsLogStore(logDirectory: root.appendingPathComponent("ops"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        model.setMeetingStoreForTesting(store)
        logModel.sessionsRootOverrideForTesting = sessions
        let today = logModel.selectedDay
        for day in 0..<3 {
            for index in 0..<120 {
                var segment = TranscriptSegment(startSeconds: Double(index), endSeconds: Double(index + 1),
                    text: "Synthetic day \(day). " + String(repeating: "Synthetic transcript context. ", count: 12))
                segment.capturedAt = today.timeIntervalSince1970 - Double(day * 86400) + 3600 + Double(index * 15)
                segments.append(segment)
            }
        }
        try writeSegments()
        for index in 0..<64 {
            let start = 1_700_000_000 + Double(index * 3600)
            let record = MeetingRecord(id: "mtg-fixture-\(index)", source: index < 4 ? "local" : "calendar",
                startedAt: start, endedAt: start + 1800, timeZone: "UTC", title: "Synthetic meeting \(index)",
                conferenceCode: nil, participants: [], minutesState: "none", minutesError: nil)
            records.append(record)
            store.save(record)
            try store.saveBackfill(Self.transcript(record), for: record)
        }
        model.meetingTranscriptProvider = Self.transcript
        model.minutesPreparationDidBuildForTesting = { [weak self] in
            guard let self else { return }
            self.completionLock.lock()
            self.completedBuildTimes.append(ProcessInfo.processInfo.systemUptime)
            self.completionLock.unlock()
        }
        model.minutesPreparationDidFinishForTesting = { [weak self] in
            guard let self else { return }
            self.completionLock.lock()
            let started = self.completedBuildTimes.isEmpty ? nil : self.completedBuildTimes.removeFirst()
            self.completionLock.unlock()
            if let started {
                self.mainCompletionUpperBoundsMs.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
            self.preparationCompletions += 1
        }
        model.missingMinutesScanDidFinishForTesting = { [weak self] in self?.candidateCompletions += 1 }
        logModel.displayLoadDidFinishForTesting = { [weak self] applied in
            guard let self, !self.stopped, applied else { return }
            self.displayCompletions += 1
            if let pending = self.pendingDisplay,
               self.logModel.selectedDay == pending.day, self.logModel.fontSize == pending.font,
               self.logModel.transcriptRevision > pending.revision {
                self.pendingDisplay = nil
                self.completeAction?(pending.id)
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let file = root.appendingPathComponent("ops/\(formatter.string(from: Date()))-ops.log")
        var data = Data()
        for index in 0..<1000 {
            let entry = OpsLogEntry(ts: "2026-01-01T00:00:00Z", level: "info", event: "fixture-\(index)",
                                    role: "fixture", host: "example-host", script: "fixture", message: "Synthetic event")
            data.append(try JSONEncoder().encode(entry)); data.append(10)
        }
        try data.write(to: file, options: .atomic)
        let source = timelineStore
        loader = MainPanelTimelineLoader {
            source.recentDisplayIfChanged(limit: 30).map(MenuBarAppDelegate.timelineLines)
        }
    }

    private static func transcript(_ record: MeetingRecord) -> [TranscriptSegment] {
        (0..<120).map { index in
            var segment = TranscriptSegment(startSeconds: Double(index), endSeconds: Double(index + 1),
                                            text: "Synthetic meeting sentence \(index).")
            segment.capturedAt = record.startedAt + Double(index)
            return segment
        }
    }

    func start() { logModel.start() }

    func changeDay(_ delta: Int) {
        let id = beginAction?("A-day-display")
        let revision = logModel.transcriptRevision
        logModel.moveDay(by: delta)
        pendingDisplay = (id, logModel.selectedDay, logModel.fontSize, revision)
    }

    func changeFont(_ delta: CGFloat) {
        let id = beginAction?("A-font-display-without-config-save")
        let revision = logModel.transcriptRevision
        logModel.setDisplayFontSizeForTesting(logModel.fontSize + delta)
        pendingDisplay = (id, logModel.selectedDay, logModel.fontSize, revision)
    }

    func appendTail() {
        let id = beginAction?("A-tail-display")
        let revision = logModel.transcriptRevision
        var segment = TranscriptSegment(startSeconds: 121, endSeconds: 122, text: "Synthetic appended tail.")
        segment.capturedAt = logModel.selectedDay.timeIntervalSince1970 + 7200
        segments.append(segment)
        do { try writeSegments() }
        catch { return }
        pendingDisplay = (id, logModel.selectedDay, logModel.fontSize, revision)
        logModel.pollTimerForTesting?.fire()
    }

    func timelineBurst() {
        pendingTimeline = beginAction?("B-timeline-burst-display")
        for _ in 0..<20 {
            loader?.refresh { [weak self] lines in
                guard let self, !self.stopped else { return }
                self.timelineModel.logs = lines
                self.timelinePublications += 1
                self.completeAction?(self.pendingTimeline)
                self.pendingTimeline = nil
            }
        }
    }

    func prepare() {
        guard let record = records.last else { return }
        let id = beginAction?("C1-preparing-display")
        model.requestMinutes(for: record)
        if model.preparingMinutesIDs.contains(record.id) { completeAction?(id) }
    }

    func scanCandidates() {
        let id = beginAction?("C2-scan-request-return")
        for _ in 0..<20 { model.requestMissingMinutes() }
        // Measures handler return only. Candidate completion counts are separate;
        // this is not a document, network-dispatch or full-scan latency claim.
        completeAction?(id)
    }

    func stop() {
        stopped = true
        logModel.stop()
        loader?.stop()
        // Never model.cleanup(): this unstarted instance owns no shared watchers.
    }

    func evidence() -> [String: Any] {
        ["ambientSegments": segments.count, "meetings": records.count, "backfillSegmentsPerMeeting": 120,
         "timelineSeedEntries": 1000, "timelineBurstRequests": 20,
         "displayCompletions": displayCompletions, "timelinePublications": timelinePublications,
         "preparationCompletions": preparationCompletions, "candidateCompletions": candidateCompletions,
         "connected": model.connectionState == .connected,
         "mainPreparationCompletionUpperBoundsMs": mainCompletionUpperBoundsMs,
         "completionMetric": "worker completion to main completion, includes queue wait and source metadata validation",
         "fontConfigPersistenceIncluded": false, "drainNetworkPathExercised": false]
    }

    private func writeSegments() throws {
        let directory = sessions.appendingPathComponent("ctx-fixture/transcripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        for segment in segments { data.append(try JSONEncoder().encode(segment)); data.append(10) }
        try data.write(to: directory.appendingPathComponent("raw.jsonl"), options: .atomic)
    }
}

struct NativeWorkloadFixtureView: View {
    @ObservedObject var fixture: NativeWorkloadFixture

    var body: some View {
        VStack {
            Picker("Workload", selection: $fixture.mode) {
                Text("Log").tag("Log")
                Text("Timeline").tag("Timeline")
                Text("Minutes").tag("Minutes")
            }.pickerStyle(.segmented)
            switch fixture.mode {
            case "Log": NativeAmbientWorkloadView(fixture: fixture, log: fixture.logModel)
            case "Timeline": NativeTimelineWorkloadView(fixture: fixture, model: fixture.timelineModel)
            default: NativeMinutesWorkloadView(fixture: fixture, model: fixture.model)
            }
        }.onAppear { fixture.start() }
    }
}

private struct NativeAmbientWorkloadView: View {
    @ObservedObject var fixture: NativeWorkloadFixture
    @ObservedObject var log: AmbientLogModel
    var body: some View {
        VStack {
            HStack {
                Button("Previous day") { fixture.changeDay(-1) }
                Button("Next day") { fixture.changeDay(1) }
                Button("Font +") { fixture.changeFont(1) }
                Button("Font -") { fixture.changeFont(-1) }
                Button("Append tail") { fixture.appendTail() }
            }
            Text("Selected day: \(log.selectedDay.timeIntervalSince1970), font: \(log.fontSize)")
            AmbientTranscriptTextView(attributedTranscript: log.cachedTranscript,
                                      textRevision: log.transcriptRevision, scrollRevision: log.transcriptScrollRevision)
        }
    }
}

private struct NativeTimelineWorkloadView: View {
    @ObservedObject var fixture: NativeWorkloadFixture
    @ObservedObject var model: MainPanelModel
    var body: some View {
        VStack {
            Button("Timeline burst") { fixture.timelineBurst() }
            ScrollView { VStack(alignment: .leading) {
                ForEach(model.logs) { line in Text(line.text).foregroundColor(Color(line.color)) }
            } }
        }
    }
}

private struct NativeMinutesWorkloadView: View {
    @ObservedObject var fixture: NativeWorkloadFixture
    @ObservedObject var model: PetModel
    var body: some View {
        VStack {
            HStack {
                Button("Prepare synthetic minutes") { fixture.prepare() }
                Button("Scan synthetic candidates") { fixture.scanCandidates() }
            }
            Text("Preparing: \(model.preparingMinutesIDs.count), preparation completions: \(fixture.preparationCompletions), scan completions: \(fixture.candidateCompletions)")
            MeetingWorkspaceView(model: model)
        }
    }
}
#endif
