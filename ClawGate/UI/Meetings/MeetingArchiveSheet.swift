import AppKit
import SwiftUI

/// Creates a meeting after the fact — from a calendar candidate or an exact
/// date range — out of the retained audio. This is the pet Minutes tab's
/// "会議候補" section moved into the minutes window, with the same rules.
struct MeetingArchiveSheet: View {
    @ObservedObject var model: PetModel
    let onCreated: (MeetingRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [MeetingCandidate] = []
    @State private var selected: MeetingCandidate?
    @State private var showManualRange = false
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()
    @State private var coverage: (mic: Double, system: Double)?
    @State private var coverageRequest = UUID()
    @State private var busy = false
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("過去の会議を作る").font(.system(size: 18, weight: .bold))
                Spacer()
                Button(model.meetingSourcesBusy ? "読込中…" : "予定を更新") { reloadCandidates() }
                    .disabled(model.meetingSourcesBusy)
                Button(connecting ? "接続中…" : "Google を接続") { connectGoogle() }
                    .disabled(connecting)
            }
            Text("保存してある音声から文字起こしと議事録を作ります。音声は直近 \(Int(MeetingAudioArchive.retentionSeconds / 86_400)) 日分だけ残っています。")
                .font(.system(size: 13)).foregroundColor(WorkspaceTheme.secondary)
            if let message = model.meetingSourcesError ?? error {
                Text(message).font(.system(size: 13)).foregroundColor(WorkspaceTheme.warningText)
            }
            candidateList
            if let candidate = selected { candidateDetail(candidate) }
            DisclosureGroup("日時を手動で指定", isExpanded: $showManualRange) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("開始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("終了", selection: $end, displayedComponents: [.date, .hourAndMinute])
                }
                .padding(.top, 6)
            }
            .font(.system(size: 13))
            coverageLine
            HStack {
                Button("閉じる") { dismiss() }
                Spacer()
                Button(busy ? "音声を処理中…" : createLabel) { create() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canCreate)
            }
        }
        .padding(24)
        .frame(width: 640, height: 640)
        .foregroundColor(WorkspaceTheme.ink)
        .background(WorkspaceTheme.ground)
        .preferredColorScheme(.light)
        .onAppear { candidates = sortedCandidates(); loadCoverage() }
        .onChange(of: model.meetingCandidates) { _ in candidates = sortedCandidates() }
        .onChange(of: start) { _ in loadCoverage() }
        .onChange(of: end) { _ in loadCoverage() }
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if candidates.isEmpty {
                    Text("過去7日の会議候補はありません。予定は自動で更新します。")
                        .font(.system(size: 13)).foregroundColor(WorkspaceTheme.muted).padding(8)
                }
                ForEach(candidates, id: \.id) { candidate in
                    Button {
                        selected = candidate
                        start = candidate.proposedStart ?? candidate.start
                        end = candidate.proposedEnd ?? candidate.end
                        showManualRange = false
                    } label: {
                        HStack {
                            Text(candidate.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(range(candidate.start, candidate.end)).font(.system(size: 12))
                                .foregroundColor(WorkspaceTheme.muted)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selected?.id == candidate.id ? Color.white : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selected?.id == candidate.id ? WorkspaceTheme.accent : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 10).fill(WorkspaceTheme.sidebar))
    }

    private func candidateDetail(_ candidate: MeetingCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("予定 \(range(candidate.start, candidate.end))").font(.system(size: 13))
            if let a = candidate.proposedStart, let b = candidate.proposedEnd {
                Text("録音からの提案 \(range(a, b))").font(.system(size: 13))
            } else {
                Text("録音から会話の区間を特定できませんでした").font(.system(size: 13))
                    .foregroundColor(WorkspaceTheme.warningText)
            }
            Text("区間の根拠: \(candidate.boundaryEvidence)").font(.system(size: 12))
                .foregroundColor(WorkspaceTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if candidate.matchStatus == "ambiguous" {
                Text("複数の予定が該当します。この予定を選んでも、会議との一致は未確定です。")
                    .font(.system(size: 12)).foregroundColor(WorkspaceTheme.warningText)
            }
            Button("予定の選択を外して、日時だけで作る") { selected = nil; showManualRange = true }
                .buttonStyle(.link).font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var coverageLine: some View {
        if (selected != nil || showManualRange), let coverage, start < end {
            let duration = end.timeIntervalSince(start)
            Text("保存済みの音声: マイク \(Int(100 * coverage.mic / duration))% / PC音声 \(Int(100 * coverage.system / duration))%（欠けた部分は無音という意味ではありません）")
                .font(.system(size: 12))
                .foregroundColor(coverage.mic < duration * 0.9 ? WorkspaceTheme.warningText : WorkspaceTheme.secondary)
        }
    }

    private var createLabel: String {
        selected != nil && !showManualRange ? "この会議を文字起こし" : "この範囲を文字起こし"
    }

    private var canCreate: Bool {
        guard !busy, selected != nil || showManualRange, start < end,
              start >= Date().addingTimeInterval(-MeetingAudioArchive.retentionSeconds) else { return false }
        if !showManualRange, let candidate = selected {
            return candidate.matchStatus != "noConversation" && candidate.proposedStart != nil && candidate.proposedEnd != nil
        }
        return true
    }

    private func create() {
        busy = true
        error = nil
        let candidate = selected
        model.createArchivedMeeting(start: start, end: end, title: candidate?.title, candidate: candidate) { result in
            busy = false
            switch result {
            case .success(let record):
                model.requestMinutes(for: record)
                onCreated(record)
                dismiss()
            case .failure(let failure):
                error = "文字起こしできませんでした: \(failure)"
            }
        }
    }

    private func sortedCandidates() -> [MeetingCandidate] {
        model.meetingCandidates.sorted { $0.start > $1.start }
    }

    private func reloadCandidates() {
        model.refreshMeetingSources(force: true)
        candidates = sortedCandidates()
    }

    private func range(_ a: Date, _ b: Date) -> String {
        "\(DateFormatter.localizedString(from: a, dateStyle: .short, timeStyle: .short))–\(DateFormatter.localizedString(from: b, dateStyle: .none, timeStyle: .short))"
    }

    private func loadCoverage() {
        let request = UUID()
        coverageRequest = request
        coverage = nil
        let s = start.timeIntervalSince1970, e = end.timeIntervalSince1970
        guard s < e else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            let archive = MeetingAudioArchive()
            let mic = archive.coveredSeconds(start: s, end: e, source: "mic")
            let system = archive.coveredSeconds(start: s, end: e, source: "system")
            DispatchQueue.main.async {
                guard coverageRequest == request else { return }
                coverage = (mic, system)
            }
        }
    }

    /// The same authorization flow the pet tab used, through the bundled gog.
    private func connectGoogle() {
        guard !connecting else { return }
        connecting = true
        DispatchQueue.global(qos: .utility).async {
            let paths = [Bundle.main.resourceURL?.appendingPathComponent("gog").path, "/opt/homebrew/bin/gog", "/usr/local/bin/gog"].compactMap { $0 }
            guard let binary = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                DispatchQueue.main.async { connecting = false; error = "カレンダー連携ツールがありません。" }
                return
            }
            let status = Process()
            status.executableURL = URL(fileURLWithPath: binary)
            status.arguments = ["auth", "status", "--json", "--no-input"]
            let output = Pipe()
            status.standardOutput = output
            status.standardError = FileHandle.nullDevice
            let started = (try? status.run()) != nil
            let data = started ? output.fileHandleForReading.readDataToEndOfFile() : Data()
            if started { status.waitUntilExit() }
            var authorized = false
            if started, status.terminationStatus == 0,
               let arguments = try? MeetingCandidateSource.calendarAuthorizationArguments(status: data) {
                let auth = Process()
                auth.executableURL = URL(fileURLWithPath: binary)
                auth.arguments = arguments
                auth.standardOutput = FileHandle.nullDevice
                auth.standardError = FileHandle.nullDevice
                if (try? auth.run()) != nil { auth.waitUntilExit(); authorized = auth.terminationStatus == 0 }
            }
            DispatchQueue.main.async {
                connecting = false
                if authorized { model.refreshMeetingSources(force: true) }
                else { error = "Google の接続を完了できませんでした。" }
            }
        }
    }
}
