import SwiftUI

/// Candidate discovery never reads an unselected transcript body. The owner
/// chooses artifacts here; generation performs separate fresh, complete reads.
struct MeetingRecallPicker: View {
    @ObservedObject var model: PetModel
    let record: MeetingRecord
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MeetingRecallReadBridge.Kind = .original
    @State private var start: Date
    @State private var end: Date
    @State private var candidates: [MeetingRecallReadBridge.Candidate] = []
    @State private var nextCursor: String?
    @State private var selection: [MeetingRecallSelectionStore.Item] = []
    @State private var fingerprint: String?
    @State private var loadedSelection = false
    @State private var busy = false
    @State private var error: String?
    @State private var originalID: String?
    @State private var resolution: MeetingRecallReadBridge.Resolution?

    init(model: PetModel, record: MeetingRecord) {
        self.model = model; self.record = record
        _start = State(initialValue: Date(timeIntervalSince1970: record.startedAt - 86400))
        _end = State(initialValue: Date(timeIntervalSince1970: (record.endedAt ?? record.startedAt) + 86400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("議事録に使うRecallの発言").font(.title2)
            Text("候補は日時で探すだけで、自動では選びません。本文は選択を保存して生成するときに読み取ります。")
                .font(.callout)
            HStack {
                DatePicker("発生日時から", selection: $start)
                DatePicker("まで", selection: $end)
            }.disabled(busy)
            Text("この日時は登録された発生時刻です。実際の録音開始・終了時刻とは限りません。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Picker("種類", selection: $kind) {
                    ForEach(MeetingRecallReadBridge.Kind.allCases, id: \.self) { value in Text(value.label).tag(value) }
                }.disabled(busy)
                Button("候補を探す") { loadCandidates(more: false) }.disabled(busy || start >= end)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                    if nextCursor != nil {
                        Button("次の候補を表示") { loadCandidates(more: true) }.disabled(busy)
                        Text("まだ表示していない候補があります。").font(.caption)
                    }
                    if let resolution, let originalID {
                        Divider()
                        Text("選んだ音声に対応する文字起こし").font(.headline)
                        if !resolution.complete || resolution.relatedTruncated || resolution.unverifiedCount > 0 {
                            Text("確認できた候補だけを表示しています。一覧の欠落や未確認の関係があります。")
                                .foregroundColor(.orange)
                        }
                        if resolution.results.isEmpty {
                            Text("利用できる文字起こしを確認できませんでした。新しい文字起こし処理は開始していません。")
                        }
                        ForEach(resolution.results) { result in
                            resultRow(result, originalID: originalID)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundColor(.orange).font(.callout) }
            HStack {
                Text("選択 \(selection.count) 件").font(.callout)
                Spacer()
                Button("キャンセル") { dismiss() }.disabled(busy)
                Button("選択を解除") { save(generate: false, clear: true) }.disabled(busy || !loadedSelection)
                Button("選んだ発言から生成") { save(generate: true, clear: false) }
                    .buttonStyle(.borderedProminent).disabled(busy || !loadedSelection || selection.isEmpty)
            }
        }
        .padding(20).frame(width: 760, height: 620)
        .task {
            do {
                let snapshot = try await model.recallSelection(for: record)
                selection = snapshot.items; fingerprint = snapshot.fingerprint; loadedSelection = true
            } catch { self.error = "保存済みの選択を確認できません。元の選択は変更していません。" }
        }
        .onChange(of: kind) { _ in resetCandidates() }
        .onChange(of: start) { _ in resetCandidates() }
        .onChange(of: end) { _ in resetCandidates() }
    }

    private func resetCandidates() { candidates = []; nextCursor = nil; resolution = nil; originalID = nil }

    private func candidateRow(_ candidate: MeetingRecallReadBridge.Candidate) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(candidate.kind.label + " · " + candidate.occurred_at)
                Text("受領 " + candidate.received_at + " · " + String(candidate.id.prefix(8)))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if selection.contains(where: { $0.eventID == candidate.id }) {
                Button("選択を外す") { selection.removeAll { $0.eventID == candidate.id } }
            } else {
                Button(candidate.kind == .original ? "文字起こしを確認" : "この発言を選ぶ") { choose(candidate) }
            }
        }.disabled(busy)
    }

    private func resultRow(_ result: MeetingRecallReadBridge.ResolvedResult, originalID: String) -> some View {
        let version: String = result.binding.processingVersion ?? "既存文字起こし"
        let shortID: String = String(result.id.prefix(8))
        let label: String = "\(version) · \(shortID)"
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
            if result.multiOriginal {
                Text("他の音声の発言も含む文字起こしです。選ぶと、その発言も入力に含まれます。")
                    .font(.caption).foregroundColor(.orange)
            }
            Button("この文字起こしを使う") {
                selection.removeAll { $0.eventID == originalID }
                selection.append(.init(eventID: originalID, resultEventID: result.id,
                    kind: MeetingRecallReadBridge.Kind.original.rawValue))
                self.resolution = nil; self.originalID = nil
            }
            .disabled(busy || !result.parentVerified || result.binding.metadataOnly || result.binding.privacy == "sensitive")
        }
    }

    private func loadCandidates(more: Bool) {
        let requestedKind = kind, requestedStart = start, requestedEnd = end
        let cursor = more ? nextCursor : nil
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let page = try await model.recallCandidates(kind: requestedKind, start: requestedStart, end: requestedEnd, cursor: cursor)
                guard kind == requestedKind, start == requestedStart, end == requestedEnd else { return }
                if !more { candidates = [] }
                let seen = Set(candidates.map(\.id))
                candidates += page.items.filter { !seen.contains($0.id) }
                nextCursor = page.nextCursor
                if candidates.isEmpty { error = "この条件の候補はありません。日時や種類を変更して探せます。" }
            } catch { self.error = "Recallの候補を取得できません。読取機能の接続・許可を確認してください。選択は変更していません。" }
        }
    }

    private func choose(_ candidate: MeetingRecallReadBridge.Candidate) {
        guard candidate.kind == .original else {
            selection.append(.init(eventID: candidate.id, resultEventID: nil, kind: candidate.kind.rawValue)); return
        }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let value = try await model.resolveRecallOriginal(candidate.id)
                guard value.schemaVersion == 1, ["ok", "incomplete", "selection_required"].contains(value.status),
                      value.originalBinding?.eventId == candidate.id else { throw MeetingRecallReadBridge.Failure.denied }
                originalID = candidate.id; resolution = value
            } catch { self.error = "選んだ音声の文字起こしを確認できません。別の音声を自動選択することはありません。" }
        }
    }

    private func save(generate: Bool, clear: Bool) {
        let items = clear ? [] : selection
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.saveRecallSelection(items, for: record, expectedFingerprint: fingerprint)
                dismiss()
                if generate { model.regenerateMinutesWithSupplementalMaterials(for: record) }
            } catch { self.error = "会議または選択が変更されたため保存しませんでした。画面を開き直してください。" }
        }
    }
}
