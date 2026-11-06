import SwiftUI

/// Selection alone pins local evidence. Generation and publication stay explicit.
@MainActor
struct MeetingIntegrationPicker: View {
    let record: MeetingRecord
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MeetingRecord] = []
    @State private var selected = Set<String>()
    @State private var busy = true
    @State private var error: String?
    @State private var savedSelection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存した会議を統合").font(.title2.bold())
            Text("この会議と、選んだ会議の保存版を次の生成入力にします。元の発言・時刻・出典を残し、議事録だけの情報は「原音未確認」と区別します。録音の再認識や元データの削除は行いません。")
                .fixedSize(horizontal: false, vertical: true)
            Text(record.title ?? "現在の会議").font(.headline)
            List(candidates, id: \.id) { candidate in
                Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { value in
                    if value { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                })) {
                    VStack(alignment: .leading) {
                        Text(candidate.title ?? "会議")
                        Text(Date(timeIntervalSince1970: candidate.startedAt).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("integration-source-" + candidate.id)
            }.frame(minHeight: 250)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("保存後に「議事録を再生成」で統合します。統合先の配信確認前に、元の会議を一覧から消すことはありません。")
                .font(.caption).foregroundStyle(.secondary)
            if !savedSelection.isEmpty {
                Button("配信済みの統合結果へまとめる") { finishIntegration() }
                    .disabled(busy || selected != savedSelection)
                Text("統合生成と両配信先への保存が済んだ場合だけ、選んだ旧会議を一覧からまとめます。本文と元資料は削除しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("通常の入力に戻す") { save(ids: []) }.disabled(busy)
                Spacer()
                Button("キャンセル") { dismiss() }.disabled(busy)
                Button("選択を保存") { save(ids: selected.sorted()) }
                    .buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
            }
        }.padding(24).frame(width: 660)
        .task {
            let targetID = record.id
            do {
                let values = try await Task.detached(priority: .utility) {
                    let store = MeetingStore()
                    let existing = try MeetingMinutesIntegrationSelection.load(targetID: targetID, store: store)
                    let records = store.all().filter { item in
                        guard item.id != targetID, item.mergedIntoMeetingID == nil || item.mergedIntoMeetingID == targetID else { return false }
                        let directory = store.directory(for: item.id)
                        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("minutes-accepted.json").path)
                            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("minutes.json").path)
                    }.sorted { $0.startedAt > $1.startedAt }
                    return (records, Set((existing?.sources ?? []).map { $0.record.id }.filter { $0 != targetID }))
                }.value
                candidates = values.0; selected = values.1; savedSelection = values.1
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func finishIntegration() {
        busy = true; error = nil
        let targetID = record.id
        Task {
            do {
                try await MeetingMinutesIntegrationFinalization.finish(targetID: targetID,
                    store: MeetingStore(), primary: .shared, hub: .shared)
                onSaved(); dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }

    private func save(ids: [String]) {
        busy = true; error = nil
        let targetID = record.id
        Task {
            do {
                let sourceUUID = try await MeetingMinutesPublisher.shared.sourceUUID()
                try await Task.detached(priority: .utility) {
                    try MeetingMinutesIntegrationSelection.select(targetID: targetID, otherIDs: ids,
                        sourceUUID: sourceUUID, store: MeetingStore())
                }.value
                onSaved(); dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
