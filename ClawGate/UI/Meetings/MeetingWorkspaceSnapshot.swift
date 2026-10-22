import Foundation
import SwiftUI
import os

struct MeetingWorkspaceContext {
    let record: MeetingRecord
    let store: MeetingStore
    let material: MeetingGoogleMaterials.Snapshot?
    let pilotLabel: String?
    let connected: Bool
    let activity: (label: String, elapsedSeconds: Int?)?
}

struct MeetingWorkspaceSnapshot {
    struct TranscriptRow { let id: String; let time: String; let speaker: String; let text: String }
    var record: MeetingRecord
    let accepted: MeetingAcceptedMinutes?
    let job: MeetingMinutesJob?
    let shown: (minutes: MeetingMinutes, partial: Bool)?
    let transcriptRows: [TranscriptRow]
    let citedText: [String: AttributedString]
    let questions: [String]
    let supplemental: [MeetingSupplementalMaterial]
    let material: MeetingGoogleMaterials.Snapshot?
    let inputsChanged: Bool
    let supplementalChanged: Bool
    var indexedProgress: MeetingMinutesExecutionProgress?
    var holdReason: String?
    var activity: (label: String, elapsedSeconds: Int?)?
    var capturedAt: Date
}

enum MeetingWorkspaceLoadError: Error { case changedDuringRead }

actor MeetingWorkspaceLoader {
    static let shared = MeetingWorkspaceLoader()
    private let log = OSLog(subsystem: "ClawGate", category: "MinutesWorkspace")
    private struct Cached {
        let files: [String: String]
        let ambientRevision: String
        let source: MeetingGoogleMaterials.Snapshot?
        let snapshot: MeetingWorkspaceSnapshot
    }
    private var documents: [String: Cached] = [:]
    private var documentOrder: [String] = []
    private var sidebarLabels: [String: (stamp: [String: String], record: MeetingRecord, held: Bool, label: String)] = [:]
    private(set) var preparationCount = 0
    private let sessionsRoot: URL

    init(sessionsRoot: URL = AmbientStorage.sessionsRoot) { self.sessionsRoot = sessionsRoot }

    private static func inputRecord(_ record: MeetingRecord) -> MeetingRecord {
        var input = record
        input.minutesState = ""
        input.minutesError = nil
        return input
    }

    static func ambientRevision(record: MeetingRecord, files: [String: String], end: Double, sessionsRoot: URL) throws -> String {
        try MeetingMinutesSourceRevision.ambientRevision(record: record, files: files, end: end, sessionsRoot: sessionsRoot)
    }

    static func files(in directory: URL) throws -> [String: String] {
        try MeetingMinutesSourceRevision.files(in: directory)
    }

    private static func transcript(for record: MeetingRecord, store: MeetingStore, end: Double, sessionsRoot: URL) -> [TranscriptSegment] {
        if let backfill = store.loadBackfill(id: record.id) { return backfill }
        guard record.source != "calendar" else { return [] }
        return AmbientStorage.segmentsInRange(start: record.startedAt, end: end, sessionsRoot: sessionsRoot)
    }

    private static func held(record: MeetingRecord, store: MeetingStore, label: String?, files: [String: String]) -> String? {
        guard record.minutesState == "pending" || record.minutesState == "failed" else { return nil }
        let indexed = files.keys.contains { $0.hasPrefix("minutes-execution-") }
        let pilot = MeetingMinutesPilot.load().flatMap { pilot in
            MeetingMinutesJob.load(store: store, id: record.id).map { pilot.matches(store: store, id: record.id, job: $0) }
        } ?? false
        guard indexed || pilot else { return nil }
        return label ?? "専用の実行経路の対応待ちのため保留中です。この会議は再送しません。Chi 側の対応を確認してから再開します。"
    }

    func load(_ context: MeetingWorkspaceContext, now: () -> Double = { Date().timeIntervalSince1970 }, checkingCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> MeetingWorkspaceSnapshot {
        precondition(!Thread.isMainThread)
        let record = context.record, store = context.store
        let directory = store.directory(for: record.id)
        let cacheID = directory.path
        for _ in 0..<2 {
            try checkingCancellation()
            let cutoff = now()
            let end = AmbientController.trimmedEnd(of: record, against: store.all(), now: cutoff)
            let before = try Self.files(in: directory)
            if let stored = store.load(id: record.id), stored != record { throw MeetingWorkspaceLoadError.changedDuringRead }
            let ambientRevision = try Self.ambientRevision(record: record, files: before, end: end, sessionsRoot: sessionsRoot)
            let source = context.material ?? record.materialCandidateID.flatMap { MeetingGoogleMaterials.load(candidateID: $0) }
            let documentFiles = before.filter { !$0.key.hasPrefix("minutes-execution-") && $0.key != "meeting.json" }
            let cached = documents[cacheID]
            let reusable = cached.map {
                $0.files == documentFiles && $0.ambientRevision == ambientRevision && $0.source == source && Self.inputRecord($0.snapshot.record) == Self.inputRecord(record)
            } ?? false
            var snapshot: MeetingWorkspaceSnapshot
            if reusable, let cached {
                snapshot = cached.snapshot
                snapshot.record = record
            } else {
                preparationCount += 1
                let signpost = OSSignpostID(log: log)
                os_signpost(.begin, log: log, name: "PrepareDocument", signpostID: signpost)
                defer { os_signpost(.end, log: log, name: "PrepareDocument", signpostID: signpost) }
                let accepted = store.loadAcceptedMinutes(id: record.id)
                try checkingCancellation()
                let job = MeetingMinutesJob.load(store: store, id: record.id)
                let minutes = accepted?.minutes ?? store.loadMinutes(id: record.id)
                let shown = minutes.map { (minutes: $0, partial: false) } ?? job.flatMap {
                    MeetingMinutes.combining($0.completed.compactMap { $0 }).map { (minutes: $0, partial: true) }
                }
                let local = Self.transcript(for: record, store: store, end: end, sessionsRoot: sessionsRoot)
                try checkingCancellation()
                let envelope = try accepted.map { _ in try PetModel.minutesEnvelope(for: record, store: store, local: local, material: source, checkingCancellation: { try Task.checkCancellation() }) }
                try Task.checkCancellation()
                let inputsChanged = accepted.map { accepted in
                    envelope.map { MeetingMinutesJob.fingerprint($0) != accepted.fingerprint } ?? false
                } ?? false
                let supplemental = MeetingSupplementalMaterials(store: store).load(meetingID: record.id)
                let selected = supplemental.filter { $0.included && $0.status != .failed && !$0.sections.isEmpty }
                let previous = accepted?.supplementalInput ?? accepted?.supplementalMaterials ?? []
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: record.timeZone) ?? .current
                formatter.dateFormat = "HH:mm"
                let rows: [MeetingWorkspaceSnapshot.TranscriptRow]
                if let accepted {
                    rows = try accepted.segments.map { segment in
                        try Task.checkCancellation()
                        return .init(id: segment.id, time: segment.capturedAt.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--",
                            speaker: segment.speakerName ?? "話者未確認", text: segment.text)
                    }
                } else {
                    rows = try local.enumerated().map { index, segment in
                        try Task.checkCancellation()
                        return .init(id: "seg-\(index + 1)", time: segment.capturedAt.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--",
                            speaker: segment.speakerName ?? (segment.stream == "system" ? "PC音声" : "マイク"), text: segment.text)
                    }
                }
                var rendered: [String: AttributedString] = [:]
                let questions = try WorkspaceFormat.collapseNearDuplicates((shown?.minutes.openQuestions ?? []) + (accepted?.unresolvedNotes ?? []), checkingCancellation: { try Task.checkCancellation() })
                if let minutes = shown?.minutes {
                    let evidence = minutes.evidence ?? []
                    let allowed = Set(evidence.flatMap(\.segmentIds))
                    let index = try WorkspaceFormat.CitationIndex(evidence: evidence, checkingCancellation: { try Task.checkCancellation() })
                    let texts = [minutes.summary] + minutes.topics.flatMap(\.points) + minutes.decisions + minutes.actionItems.map(\.what) + questions
                    for text in Set(texts) {
                        try Task.checkCancellation()
                        rendered[text] = try WorkspaceFormat.cited(text, allowed: allowed, index: index, checkingCancellation: { try Task.checkCancellation() })
                    }
                }
                snapshot = MeetingWorkspaceSnapshot(record: record, accepted: accepted, job: job, shown: shown,
                    transcriptRows: rows, citedText: rendered, questions: questions, supplemental: supplemental,
                    material: source, inputsChanged: inputsChanged, supplementalChanged: selected != previous,
                    capturedAt: Date())
            }
            try Task.checkCancellation()
            let progress = Result { try snapshot.job.flatMap { try MeetingMinutesExecutionProgress.load(store: store, id: record.id, job: $0) } }
            snapshot.indexedProgress = try? progress.get()
            snapshot.holdReason = Self.held(record: record, store: store, label: context.pilotLabel, files: before)
            snapshot.activity = context.activity
            if record.minutesState == "pending", snapshot.job?.waitingForConnectivity == true {
                snapshot.activity = ("接続の回復待ち（完成済みパートは保持しています）", nil)
            }
            if record.minutesState == "pending", context.pilotLabel == nil, snapshot.job != nil {
                do {
                    if let indexed = try progress.get() {
                        snapshot.activity = (context.connected ? indexed.phaseLabel : "接続の回復待ち（保存済み実行の結果を確認します）", nil)
                    }
                } catch { snapshot.activity = ("実行記録を確認できません。安全のため再送していません", nil) }
            }
            snapshot.capturedAt = Date()
            try Task.checkCancellation()
            let latestEnd = AmbientController.trimmedEnd(of: record, against: store.all(), now: cutoff)
            guard before == (try Self.files(in: directory)),
                  ambientRevision == (try Self.ambientRevision(record: record, files: before, end: latestEnd, sessionsRoot: sessionsRoot)),
                  source == (context.material ?? record.materialCandidateID.flatMap { MeetingGoogleMaterials.load(candidateID: $0) }) else { continue }
            documents[cacheID] = Cached(files: documentFiles, ambientRevision: ambientRevision, source: source, snapshot: snapshot)
            documentOrder.removeAll { $0 == cacheID }
            documentOrder.append(cacheID)
            while documentOrder.count > 2 { documents.removeValue(forKey: documentOrder.removeFirst()) }
            return snapshot
        }
        throw MeetingWorkspaceLoadError.changedDuringRead
    }

    func sidebar(store: MeetingStore, labels: [String: String]) throws -> (meetings: [MeetingRecord], statuses: [String: MeetingWorkspaceStatus], labels: [String: String]) {
        precondition(!Thread.isMainThread)
        let meetings = store.all().filter { $0.mergedIntoMeetingID == nil }
        var statuses: [String: MeetingWorkspaceStatus] = [:], result: [String: String] = [:]
        for record in meetings {
            try Task.checkCancellation()
            let stamp = try Self.files(in: store.directory(for: record.id))
            let held = Self.held(record: record, store: store, label: labels[record.id], files: stamp) != nil
            let status = MeetingWorkspaceStatus(meeting: record, held: held)
            statuses[record.id] = status
            if let cached = sidebarLabels[record.id], cached.stamp == stamp, cached.record == record, cached.held == held {
                result[record.id] = cached.label
            } else {
                let label = status.shortLabel(store: store)
                result[record.id] = label
                sidebarLabels[record.id] = (stamp, record, held, label)
            }
        }
        sidebarLabels = sidebarLabels.filter { result[$0.key] != nil }
        return (meetings, statuses, result)
    }
}

@MainActor
final class MeetingWorkspaceDocument: ObservableObject {
    @Published private(set) var snapshot: MeetingWorkspaceSnapshot?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var worker: Task<MeetingWorkspaceSnapshot, Error>?
    private var generation = 0
    private var pending: MeetingWorkspaceContext?
    private var selection: MeetingRecord?
    private let loader: MeetingWorkspaceLoader

    init(loader: MeetingWorkspaceLoader = .shared) { self.loader = loader }

    func refresh(_ context: MeetingWorkspaceContext) {
        if task != nil, selection == context.record {
            pending = context
            return
        }
        cancel()
        selection = context.record
        if snapshot?.record.id != context.record.id { snapshot = nil }
        let request = generation
        let loader = self.loader
        let worker = Task.detached(priority: .userInitiated) { try await loader.load(context) }
        self.worker = worker
        task = Task { [weak self] in
            let result = await worker.result
            guard let self, self.generation == request, !Task.isCancelled else { return }
            self.task = nil
            self.worker = nil
            if let next = self.pending {
                self.pending = nil
                self.refresh(next)
                return
            }
            switch result {
            case .success(let snapshot): self.snapshot = snapshot; self.error = nil
            case .failure(let failure) where failure is CancellationError: break
            case .failure: self.error = "表示データの更新中です。保存済みの表示を保持し、次の更新で再取得します。"
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel(); worker?.cancel()
        task = nil; worker = nil; pending = nil
    }

    deinit { task?.cancel(); worker?.cancel() }
}
