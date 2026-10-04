import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The minutes window: meetings by day on the left, the selected meeting on
/// the right. It reads the same records and minutes as the pet's Minutes tab;
/// the difference is room — a full window instead of a 360pt bubble — and a
/// status banner that says how far generation got and what happens next.
struct MeetingWorkspaceView: View {
    @ObservedObject var model: PetModel

    @State private var meetings: [MeetingRecord] = []
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var tab: Tab = .minutes
    @State private var scrollTarget: String?
    @State private var copied = false

    enum Tab: String, CaseIterable, Identifiable {
        case minutes = "議事録", transcript = "文字起こし", materials = "資料"
        var id: String { rawValue }
    }

    private var selected: MeetingRecord? { meetings.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
            Divider()
            if let meeting = selected {
                MeetingWorkspaceDetail(model: model, meeting: meeting, tab: $tab,
                                       scrollTarget: $scrollTarget, copied: $copied)
                    .id(meeting.id)
            } else {
                Text("左の一覧から会議を選んでください")
                    .font(.system(size: 15))
                    .foregroundColor(WorkspaceTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WorkspaceTheme.ground)
        .preferredColorScheme(.light)
        .onAppear { reload() }
        .onChange(of: model.meetingsRevision) { _ in reload() }
        .onChange(of: searchText) { _ in reload() }
        .onChange(of: selectedID) { _ in copied = false }
        .onChange(of: tab) { _ in copied = false }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in reload() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("議事録").font(.system(size: 20, weight: .bold))
                TextField("タイトル・参加者で検索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(days, id: \.label) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.label)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(WorkspaceTheme.muted)
                                .padding(.horizontal, 8)
                            ForEach(day.meetings, id: \.id) { meeting in
                                meetingRow(meeting)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 16)
            }
        }
        .background(WorkspaceTheme.sidebar)
    }

    private func meetingRow(_ meeting: MeetingRecord) -> some View {
        let status = MeetingWorkspaceStatus(meeting: meeting, held: model.minutesHoldReason(for: meeting) != nil)
        let active = meeting.id == selectedID
        return Button {
            selectedID = meeting.id
            tab = .minutes
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.title ?? "無題の会議")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Text(WorkspaceFormat.timeRange(meeting))
                        .font(.system(size: 12))
                        .foregroundColor(WorkspaceTheme.muted)
                }
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.shortLabel)
                        .font(.system(size: 12))
                        .foregroundColor(status.isProblem ? WorkspaceTheme.warningText : WorkspaceTheme.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.white : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? WorkspaceTheme.accent : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(WorkspaceTheme.ink)
    }

    private var days: [(label: String, meetings: [MeetingRecord])] {
        var order: [String] = []
        var grouped: [String: [MeetingRecord]] = [:]
        for meeting in meetings {
            let label = WorkspaceFormat.dayLabel(meeting)
            if grouped[label] == nil { order.append(label) }
            grouped[label, default: []].append(meeting)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func reload() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        meetings = model.meetingList()
            .filter { $0.mergedIntoMeetingID == nil }
            .filter { meeting in
                guard !query.isEmpty else { return true }
                let haystack = ([meeting.title ?? ""] + meeting.participants).joined(separator: " ").lowercased()
                return haystack.contains(query)
            }
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
            selectedID = meetings.first?.id
        }
    }
}

// MARK: - Detail

private struct MeetingWorkspaceDetail: View {
    @ObservedObject var model: PetModel
    let meeting: MeetingRecord
    @Binding var tab: MeetingWorkspaceView.Tab
    @Binding var scrollTarget: String?
    @Binding var copied: Bool
    @State private var highlighted: Set<String> = []
    @State private var highlightedMaterials: Set<String> = []
    @State private var supplemental: [MeetingSupplementalMaterial] = []
    @State private var materialText = ""
    @State private var materialName = ""
    @State private var materialNote = ""
    @State private var materialDropError: String?
    @State private var materialBusy = false
    @State private var confirmDeleteMaterial: MeetingSupplementalMaterial?
    @State private var editingNoteID: String?
    @State private var editingNote = ""
    @State private var confirmFullRegeneration = false

    private var accepted: MeetingAcceptedMinutes? { MeetingStore().loadAcceptedMinutes(id: meeting.id) }
    private var job: MeetingMinutesJob? { MeetingMinutesJob.load(store: MeetingStore(), id: meeting.id) }

    /// The accepted minutes, or — while a generation is under way and nothing
    /// was ever accepted — the parts written so far, so the owner can read what
    /// exists instead of an empty page.
    private var shown: (minutes: MeetingMinutes, partial: Bool)? {
        if let minutes = model.minutes(for: meeting.id) { return (minutes, false) }
        if let job, let partial = MeetingMinutes.combining(job.completed.compactMap { $0 }) {
            return (partial, true)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            workflowBar
            MeetingSourcesRow(model: model, meeting: meeting, accepted: accepted)
            MeetingStatusBanner(model: model, meeting: meeting, job: job,
                                hasReadableMinutes: shown != nil)
            tabBar
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            switch tab {
                            case .minutes: minutesTab(width: geometry.size.width - 56)
                            case .transcript: transcriptTab
                            case .materials: materialsTab
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .onChange(of: tab) { newTab in
                        if newTab == .materials, let target = highlightedMaterials.first {
                            DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                            return
                        }
                        guard newTab == .transcript, let target = scrollTarget else { return }
                        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "clawgate-segment", let host = url.host {
                    let ids = host.split(separator: ",").map { "seg-\($0)" }
                    highlighted = Set(ids)
                    scrollTarget = ids.first
                    tab = .transcript
                    return .handled
                }
                if url.scheme == "clawgate-material", let host = url.host, !host.isEmpty {
                    highlightedMaterials = [host]
                    tab = .materials
                    return .handled
                }
                if let safe = WorkspaceFormat.safeExternalURL(url.absoluteString) {
                    NSWorkspace.shared.open(safe); return .handled
                }
                return .discarded
            })
        }
        .foregroundColor(WorkspaceTheme.ink)
        .onAppear { reloadSupplemental() }
        .alert("全パートを作り直しますか？", isPresented: $confirmFullRegeneration) {
            Button("全パートを作り直す") { model.regenerateMinutes(for: meeting, forceFull: true) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("同じ入力の完成済みパートも再生成します。現在の議事録は、新版が完成するまで読めます。")
        }
        .onChange(of: meeting.id) { _ in
            materialText = ""; materialName = ""; materialNote = ""
            materialDropError = nil; editingNoteID = nil; editingNote = ""
            confirmDeleteMaterial = nil; highlightedMaterials = []; highlighted = []
            reloadSupplemental()
        }
        .alert("資料を削除しますか？", isPresented: Binding(get: { confirmDeleteMaterial != nil }, set: { if !$0 { confirmDeleteMaterial = nil } })) {
            Button("削除", role: .destructive) {
                if let item = confirmDeleteMaterial {
                    do { try MeetingSupplementalMaterials().remove(id: item.id, meetingID: meeting.id); materialDropError = nil }
                    catch { materialDropError = error.localizedDescription }
                }
                confirmDeleteMaterial = nil; reloadSupplemental()
            }
            Button("キャンセル", role: .cancel) { confirmDeleteMaterial = nil }
        }
    }

    /// A single, stable path from source material to the minutes output. The
    /// selected inputs are read only when the request starts; adding material
    /// never silently regenerates the accepted minutes.
    private var workflowBar: some View {
        let included = supplemental.filter { $0.included && $0.status != .failed && !$0.sections.isEmpty }
        let failed = supplemental.filter { $0.status == .failed }.count
        let changed = accepted != nil && model.minutesInputsChanged(for: meeting)
        let pending = meeting.minutesState == "pending"
        let disabled = pending || materialBusy || model.googleMaterialBusy(for: meeting)
            || model.minutesActivity(for: meeting) != nil
        let checkpoint = meeting.minutesState == "failed"
            && (job?.completed.count ?? 0) > 0
            && (job?.completed.count ?? 0) < (job?.envelopes.count ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                workflowStep("1", "資料をそろえる", active: tab == .materials) {
                    tab = .materials
                }
                Image(systemName: "chevron.right").foregroundColor(WorkspaceTheme.muted)
                Text("2  議事録を生成・更新").font(.system(size: 13, weight: pending ? .bold : .regular))
                Image(systemName: "chevron.right").foregroundColor(WorkspaceTheme.muted)
                workflowStep("3", "結果を確認", active: tab == .minutes) {
                    tab = .minutes
                }
            }
            HStack(spacing: 12) {
                    Button(accepted == nil ? "議事録を生成" : "議事録を再生成") {
                        model.regenerateMinutesWithSupplementalMaterials(for: meeting)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(disabled)
                    if checkpoint {
                        Button("失敗した続きから再開") { model.resumeMinutes(for: meeting) }
                            .controlSize(.small)
                            .disabled(disabled)
                    }
                    if accepted != nil || job != nil {
                        Button("全パートを作り直す…") { confirmFullRegeneration = true }
                            .disabled(disabled)
                    }
                    Spacer()
                    if pending {
                        Text(accepted == nil ? "議事録を生成中" : "新版を生成中・現在の議事録は引き続き読めます")
                            .font(.system(size: 12))
                    }
            }
            HStack(spacing: 12) {
                Text("使用する追加資料 \(included.count) 件")
                if failed > 0 {
                    Text("読み取り失敗 \(failed) 件（今回の入力には含まれません）").foregroundColor(WorkspaceTheme.warningText)
                }
                if changed {
                    Text("入力が変更されています。再生成すると最新の文字起こし・選択資料を使用します")
                        .foregroundColor(WorkspaceTheme.warningText)
                }
            }
            .font(.system(size: 12))
            Text("資料を追加・選択してから「議事録を再生成」。入力は開始時に固定し、変わらない完成済みパートは再利用します。")
                .font(.system(size: 12)).foregroundColor(WorkspaceTheme.muted)
            if pending, let reused = job?.reusedPartCount, reused > 0 {
                Text("完成済み \(reused) パートを再利用。変更部分と全体の仕上げを処理します。")
                    .font(.system(size: 12)).foregroundColor(WorkspaceTheme.secondary)
            }
            if let accepted {
                Text("表示中の議事録: \(accepted.createdAt.formatted(date: .abbreviated, time: .shortened)) に生成")
                    .font(.system(size: 11)).foregroundColor(WorkspaceTheme.muted)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(WorkspaceTheme.header)
        .overlay(Divider(), alignment: .bottom)
    }

    private func workflowStep(_ number: String, _ label: String, active: Bool, disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(number).font(.system(size: 11, weight: .bold))
                    .foregroundColor(active ? .white : WorkspaceTheme.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(active ? WorkspaceTheme.accent : WorkspaceTheme.line))
                Text(label).font(.system(size: 13, weight: active ? .bold : .regular))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(WorkspaceTheme.ink)
        .disabled(disabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown?.minutes.title ?? meeting.title ?? "無題の会議")
                        .font(.system(size: 24, weight: .bold))
                        .textSelection(.enabled)
                    HStack(spacing: 16) {
                        if let planned = WorkspaceFormat.plannedRange(meeting) { Text("予定 \(planned)") }
                        Text("録音 \(WorkspaceFormat.timeRange(meeting))")
                        attendees
                    }
                    .font(.system(size: 13))
                    .foregroundColor(WorkspaceTheme.secondary)
                }
                Spacer()
                if let copyText {
                    Button(copied ? "コピーしました" : copyLabel) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .disabled(copyText.isEmpty)
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
        .background(WorkspaceTheme.header)
        .overlay(Divider(), alignment: .bottom)
    }

    private var copyLabel: String {
        switch tab {
        case .minutes: return "議事録をコピー"
        case .transcript: return "文字起こしをコピー"
        case .materials: return "資料をコピー"
        }
    }

    private var copyText: String? {
        switch tab {
        case .minutes:
            guard let shown else { return "" }
            return (shown.partial ? "> 作成途中の議事録です。\n\n" : "") + shown.minutes.markdown(record: meeting)
        case .transcript:
            return transcriptRows.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        case .materials:
            let google = model.googleMaterial(for: meeting)?.notes.map { $0.text + "\n出典: " + $0.sourceURL } ?? []
            let supplemental = displayedSupplemental.flatMap { material in
                ["## \(material.name)\nメモ: \(material.note)\n状態: \(material.status.rawValue)"] + material.sections.map { "[\($0.locator)] \($0.text)" }
            }
            return (google + supplemental).joined(separator: "\n\n")
        }
    }

    /// Attendees sit on the time line and keep their full names; a long list
    /// scrolls sideways rather than truncating or spreading into a grid.
    @ViewBuilder
    private var attendees: some View {
        let present = WorkspaceFormat.ownerFirst(shown?.minutes.attendance?.present ?? meeting.participants)
        let invitedOnly = shown?.minutes.attendance?.absent ?? []
        if !present.isEmpty || !invitedOnly.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !present.isEmpty {
                        Text("参加").foregroundColor(WorkspaceTheme.muted)
                        ForEach(present, id: \.self) { name in chip(name, dashed: false) }
                    }
                    if !invitedOnly.isEmpty {
                        Text("招待のみ").foregroundColor(WorkspaceTheme.muted).padding(.leading, 6)
                        ForEach(invitedOnly, id: \.self) { name in chip(name, dashed: true) }
                    }
                }
            }
        }
    }

    private func chip(_ name: String, dashed: Bool) -> some View {
        let mine = WorkspaceFormat.isOwner(name)
        return Text(mine ? "あなた" : name)
            .font(.system(size: 13, weight: mine ? .semibold : .regular))
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(dashed ? Color.clear : WorkspaceTheme.chip))
            .overlay(Capsule().strokeBorder(dashed ? WorkspaceTheme.line : Color.clear,
                                            style: StrokeStyle(lineWidth: 1, dash: [3])))
            .foregroundColor(dashed ? WorkspaceTheme.secondary : WorkspaceTheme.chipText)
            .help(name)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MeetingWorkspaceView.Tab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 14, weight: tab == item ? .bold : .regular))
                        .padding(.horizontal, 14).frame(height: 38)
                        .overlay(Rectangle().fill(tab == item ? WorkspaceTheme.accent : .clear).frame(height: 3),
                                 alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 8)
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: Minutes tab

    @ViewBuilder
    private func minutesTab(width: CGFloat) -> some View {
        if let shown {
            let minutes = shown.minutes
            let evidence = minutes.evidence ?? []
            let citations = Set(evidence.flatMap(\.segmentIds))
            // Side by side when there is room; the side column drops below the
            // main one on a narrow window instead of crushing it.
            AdaptiveColumns(width: width, sideWidth: 300, minimumMainWidth: 460) {
                VStack(alignment: .leading, spacing: 18) {
                    WorkspaceCard(title: shown.partial ? "概要（完成したパートの範囲）" : "概要") {
                        Text(WorkspaceFormat.cited(minutes.summary, allowed: citations, evidence: evidence))
                            .font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !minutes.topics.isEmpty {
                        Text("議題ごとの詳細").font(.system(size: 13, weight: .bold)).foregroundColor(WorkspaceTheme.muted)
                        ForEach(Array(minutes.topics.enumerated()), id: \.offset) { _, topic in
                            WorkspaceCard(title: nil) {
                                Text(topic.heading).font(.system(size: 17, weight: .bold))
                                ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundColor(WorkspaceTheme.muted)
                                        Text(WorkspaceFormat.cited(point, allowed: citations, evidence: evidence))
                                            .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } side: {
                VStack(alignment: .leading, spacing: 18) {
                    listCard("決まったこと", minutes.decisions, citations, empty: "記録なし", evidence: evidence)
                    WorkspaceCard(title: "宿題") {
                        if minutes.actionItems.isEmpty {
                            Text("記録なし").font(.system(size: 14)).foregroundColor(WorkspaceTheme.muted)
                        }
                        ForEach(Array(sortedActions(minutes).enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.mine == true ? "あなた" : (item.owner ?? "担当未定"))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(item.mine == true ? WorkspaceTheme.chipText : WorkspaceTheme.secondary)
                                Text(WorkspaceFormat.cited(item.what, allowed: citations, evidence: evidence))
                                    .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                                Text(item.due.map { "期限 \($0)" } ?? "期限なし")
                                    .font(.system(size: 12)).foregroundColor(WorkspaceTheme.muted)
                            }
                            .padding(.bottom, 6)
                        }
                    }
                    listCard("未解決・要確認", minutes.openQuestions + (accepted?.unresolvedNotes ?? []),
                             citations, empty: "なし", evidence: evidence)
                }
            }
        } else {
            Text(emptyMinutesText)
                .font(.system(size: 15)).lineSpacing(5)
                .foregroundColor(WorkspaceTheme.secondary)
                .frame(maxWidth: .infinity)
                .padding(40)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(WorkspaceTheme.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
    }

    private func listCard(_ title: String, _ items: [String], _ citations: Set<String>, empty: String,
                          evidence: [MeetingEvidence] = []) -> some View {
        WorkspaceCard(title: title) {
            if items.isEmpty {
                Text(empty).font(.system(size: 14)).foregroundColor(WorkspaceTheme.muted)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(WorkspaceFormat.cited(item, allowed: citations, evidence: evidence))
                    .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The owner's own items first, as in the Markdown export.
    private func sortedActions(_ minutes: MeetingMinutes) -> [MeetingActionItem] {
        minutes.actionItems.filter { $0.mine == true } + minutes.actionItems.filter { $0.mine != true }
    }

    private var emptyMinutesText: String {
        switch meeting.minutesState {
        case "pending": return "議事録を作っています。完成したパートから、ここに表示します。"
        case "failed": return "議事録はまだできていません。上の帯から続きを作れます。"
        default:
            return model.meetingTranscript(for: meeting).isEmpty
                ? "この会議には文字起こしがありません。"
                : "まだ議事録はありません。上の「議事録を作る」を押してください。"
        }
    }

    // MARK: Transcript tab

    @ViewBuilder
    private var transcriptTab: some View {
        let rows = transcriptRows
        if rows.isEmpty {
            Text("この会議の文字起こしは残っていません。").foregroundColor(WorkspaceTheme.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let evidence = meeting.boundaryEvidence, !evidence.isEmpty {
                    Text("録音区間について: \(evidence)")
                        .font(.system(size: 13)).foregroundColor(WorkspaceTheme.warningText)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(WorkspaceTheme.warningFill))
                        .padding(.bottom, 10)
                }
                ForEach(rows, id: \.id) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.time).font(.system(size: 12)).foregroundColor(WorkspaceTheme.muted)
                            .frame(width: 46, alignment: .leading)
                        Text(row.speaker).font(.system(size: 13, weight: .bold))
                            .frame(width: 130, alignment: .leading)
                        Text(row.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(highlighted.contains(row.id) ? WorkspaceTheme.chip : Color.clear))
                    .id(row.id)
                }
            }
        }
    }

    private struct TranscriptRow { let id: String; let time: String; let speaker: String; let text: String }

    /// The generation-time source when minutes exist, so a citation always
    /// lands on the line it was written from; the live transcript otherwise.
    private var transcriptRows: [TranscriptRow] {
        let zone = TimeZone(identifier: meeting.timeZone) ?? .current
        if let accepted {
            return accepted.segments.map {
                TranscriptRow(id: $0.id, time: WorkspaceFormat.clock($0.capturedAt, zone: zone),
                              speaker: $0.speakerName ?? "話者未確認", text: $0.text)
            }
        }
        return model.meetingTranscript(for: meeting).enumerated().map { index, seg in
            TranscriptRow(id: "seg-\(index + 1)", time: WorkspaceFormat.clock(seg.capturedAt, zone: zone),
                          speaker: seg.speakerName ?? (seg.stream == "system" ? "PC音声" : "マイク"),
                          text: seg.text)
        }
    }

    // MARK: Materials tab

    @ViewBuilder
    private var materialsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            googleMaterialsSection
            supplementalMaterialsSection
        }
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            importDropped(providers); return true
        }
    }

    @ViewBuilder private var googleMaterialsSection: some View {
        let snapshot = model.googleMaterial(for: meeting)
        WorkspaceCard(title: "Google Meet") {
            HStack {
                Text("Meet の資料・メモは参考情報です。議事録の発言根拠には使いません。").font(.system(size: 13)).foregroundColor(WorkspaceTheme.secondary)
                Spacer()
                Button(model.googleMaterialBusy(for: meeting) ? "取得中…" : "再取得") { model.refreshGoogleMaterial(for: meeting) }
                    .disabled(model.googleMaterialBusy(for: meeting))
            }
            if let snapshot, !snapshot.notes.isEmpty {
                ForEach(snapshot.notes) { note in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                        if let url = WorkspaceFormat.safeExternalURL(note.sourceURL) { Button("出典を開く") { NSWorkspace.shared.open(url) } }
                    }
                }
            } else { Text(materialStatus).font(.system(size: 14)).foregroundColor(WorkspaceTheme.secondary) }
            if let snapshot { Text("最終取得: \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundColor(WorkspaceTheme.muted) }
        }
    }

    @ViewBuilder private var supplementalMaterialsSection: some View {
        WorkspaceCard(title: "追加資料（手動）") {
            HStack {
                Button("ファイルを追加…") { chooseFiles() }
                Button("テキストを追加…") { materialName = "メモ"; materialText = "" }
                Spacer()
                if model.supplementalMaterialsChanged(for: meeting) { Text("議事録が古い資料を参照しています").foregroundColor(WorkspaceTheme.warningText).font(.system(size: 12, weight: .semibold)) }
            }
            if !materialText.isEmpty || materialName == "メモ" {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("資料名", text: $materialName)
                    TextField("メモ（任意）", text: $materialNote)
                    TextEditor(text: $materialText).frame(minHeight: 100).overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkspaceTheme.line))
                    HStack { Button("保存") { addTextMaterial() }; Button("キャンセル") { materialText = ""; materialName = "" } }
                }
            }
            if supplemental.isEmpty { Text("追加資料はありません。ファイルをここへドロップできます。").foregroundColor(WorkspaceTheme.muted) }
            if let materialDropError { Text(materialDropError).font(.system(size: 12)).foregroundColor(WorkspaceTheme.warningText) }
            ForEach(displayedSupplemental) { material in supplementalRow(material, readOnly: !supplemental.contains(material)) }
        }
    }

    private var displayedSupplemental: [MeetingSupplementalMaterial] {
        let acceptedMaterials = accepted?.supplementalMaterials ?? []
        var result = supplemental
        for item in acceptedMaterials where highlightedMaterials.contains(where: { id in item.sections.contains { $0.id == id } }) {
            result.removeAll { $0.id == item.id }; result.append(item)
        }
        for item in acceptedMaterials where !result.contains(where: { $0.id == item.id }) { result.append(item) }
        return result
    }

    private func supplementalRow(_ material: MeetingSupplementalMaterial, readOnly: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(material.name).font(.system(size: 14, weight: .semibold))
                Text(material.status == .ready ? "読取済み" : material.status == .partial ? "一部読取" : "読取失敗").font(.system(size: 11)).foregroundColor(material.status == .failed ? WorkspaceTheme.warningText : WorkspaceTheme.muted)
                Spacer()
                Toggle("議事録に含める", isOn: Binding(get: { material.included }, set: { value in var updated = material; updated.included = value; saveMaterial(updated) })).toggleStyle(.checkbox).disabled(readOnly)
                if !readOnly { Button("削除") { confirmDeleteMaterial = material }.buttonStyle(.borderless) }
            }
            if let error = material.error, !error.isEmpty { Text(error).font(.system(size: 12)).foregroundColor(WorkspaceTheme.warningText) }
            if !readOnly && editingNoteID == material.id {
                TextField("メモ（任意）", text: $editingNote)
                HStack { Button("保存") { var updated = material; updated.note = editingNote; if saveMaterial(updated) { editingNoteID = nil } }; Button("キャンセル") { editingNoteID = nil } }
            } else if !material.note.isEmpty {
                Text(material.note).font(.system(size: 12)).foregroundColor(WorkspaceTheme.secondary)
                if !readOnly { Button("メモを編集") { editingNoteID = material.id; editingNote = material.note }.buttonStyle(.borderless) }
            } else if !readOnly {
                Button("メモを追加") { editingNoteID = material.id; editingNote = "" }.buttonStyle(.borderless)
            }
            ForEach(material.sections) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.locator.isEmpty ? "資料" : section.locator).font(.system(size: 11, weight: .semibold)).foregroundColor(WorkspaceTheme.muted)
                    DisclosureGroup("本文を表示") {
                        Text(section.text).font(.system(size: 13)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.leading, 10)
                .id(section.id)
                .background(highlightedMaterials.contains(section.id) ? WorkspaceTheme.chip : Color.clear)
            }
            if let url = MeetingSupplementalMaterials().originalURL(for: material, meetingID: meeting.id) { Button("元ファイルを開く") { NSWorkspace.shared.open(url) } }
        }
        .padding(.vertical, 6)
    }

    @discardableResult
    private func saveMaterial(_ material: MeetingSupplementalMaterial) -> Bool {
        do {
            try MeetingSupplementalMaterials().update(material, meetingID: meeting.id)
            materialDropError = nil
            reloadSupplemental()
            return true
        } catch {
            materialDropError = error.localizedDescription
            return false
        }
    }

    private func reloadSupplemental() {
        supplemental = MeetingSupplementalMaterials().load(meetingID: meeting.id)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    private func importDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                guard let url else { return }
                DispatchQueue.main.async { importFiles([url]) }
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        materialBusy = true
        let store = MeetingSupplementalMaterials()
        Task.detached {
            var failures: [String] = []
            for url in urls { do { try store.importFile(url, meetingID: meeting.id) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") } }
            await MainActor.run { materialBusy = false; materialDropError = failures.isEmpty ? nil : failures.joined(separator: "\n"); reloadSupplemental() }
        }
    }

    private func addTextMaterial() {
        let text = materialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try MeetingSupplementalMaterials().addText(text, name: materialName.isEmpty ? "メモ" : materialName,
                                                      note: materialNote, meetingID: meeting.id)
            materialText = ""; materialName = ""; materialNote = ""; reloadSupplemental()
        } catch { materialDropError = error.localizedDescription }
    }

    private var materialStatus: String {
        switch model.googleMaterial(for: meeting)?.status {
        case .checking?: return "資料を確認しています…"
        case .permissionDenied?: return "資料を読む権限がありません。"
        case .serviceUnavailable?: return "Google Docs API の有効化が必要です。資料がないとは判定していません。"
        case .failed?:
            return "資料を読み取れませんでした。Drive で確認できた範囲では、この文書は今のアカウントから見えない状態です（共有されていない、または削除済みの可能性があります）。通信の一時的な失敗ではありません。共有の依頼や権限の変更はこの画面からは行いません。"
        case .ambiguous?: return "この会議の資料の候補が複数あり、決められませんでした。"
        default: return "この会議に紐づく資料はありません。"
        }
    }
}

// MARK: - Sources

/// Which sources the minutes were written from, with counts, and — on
/// request — how they are combined. Without this the owner cannot tell a
/// ClawGate-only generation from one cross-checked against Meet.
private struct MeetingSourcesRow: View {
    @ObservedObject var model: PetModel
    let meeting: MeetingRecord
    let accepted: MeetingAcceptedMinutes?
    @State private var explain = false

    var body: some View {
        let sources = accepted?.segments.map(\.source)
        let local = sources?.filter { $0 == "local" }.count ?? model.meetingTranscript(for: meeting).count
        let recheck = sources?.filter { $0 == "audio-recheck" }.count ?? 0
        let external = sources?.filter { $0 != "local" && $0 != "audio-recheck" }.count ?? 0
        let material = model.googleMaterial(for: meeting)
        let notes = material?.notes.count ?? 0
        let unresolved = accepted?.unresolvedNotes.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("情報源").font(.system(size: 12, weight: .bold)).foregroundColor(WorkspaceTheme.muted)
                item("ClawGate 文字起こし", "\(local) 発言", ok: local > 0)
                item("Meet 文字起こし", external > 0 ? "\(external) 発言" : meetStatus(material), ok: external > 0)
                item("聞き直し", "\(recheck) 件", ok: true)
                item("要確認", "\(unresolved) 件", ok: unresolved == 0)
                if notes > 0 { item("Meet メモ", "\(notes) 件（参考のみ）", ok: true) }
                Spacer()
                Button(explain ? "閉じる" : "どう使っているか") { explain.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            if explain {
                Text("""
                ClawGate の文字起こしと Meet の文字起こしは、時刻順に並べてどちらも残します。同じ発言は重複としてまとめ、どちらを根拠にしても辿れます。
                似た発言なのに数字や否定（〜しない）が食い違う箇所は「要確認」にし、その区間の録音を最大3回・各30秒まで聞き直して別の根拠として添えます。元の文字起こしは書き換えません。
                Meet の自動メモは取りこぼしの確認にだけ使い、議事録の発言の根拠にはしません。
                """)
                .font(.system(size: 12)).lineSpacing(3)
                .foregroundColor(WorkspaceTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(WorkspaceTheme.header)
        .overlay(Divider(), alignment: .bottom)
    }

    private func item(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? WorkspaceTheme.ready : WorkspaceTheme.warning).frame(width: 6, height: 6)
            Text(label).foregroundColor(WorkspaceTheme.secondary)
            Text(value).fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .fixedSize()
    }

    private func meetStatus(_ material: MeetingGoogleMaterials.Snapshot?) -> String {
        switch material?.status {
        case .serviceUnavailable?: return "取得できず（Docs API 未有効）"
        case .permissionDenied?: return "取得できず（権限なし）"
        case .failed?: return "取得できず（文書が見えない）"
        case .ambiguous?: return "候補が複数"
        case .checking?: return "確認中"
        case .available?:
            if material?.segments.contains(where: { $0.isTranscript }) == true { return "取得済み（未使用）" }
            return "文字起こしなし"
        default: return meeting.calendarEventID == nil ? "予定と未紐付け" : "なし"
        }
    }
}

// MARK: - Status banner

/// One place that says what state the minutes are in, how many parts are
/// written, why it stopped, and what the owner can do about it.
private struct MeetingStatusBanner: View {
    @ObservedObject var model: PetModel
    let meeting: MeetingRecord
    let job: MeetingMinutesJob?
    let hasReadableMinutes: Bool

    var body: some View {
        let status = MeetingWorkspaceStatus(meeting: meeting)
        let total = job?.envelopes.count ?? 0
        let indexed = model.minutesIndexedProgress(for: meeting, job: job)
        let done = indexed?.completedIndices.count ?? min(job?.completed.count ?? 0, total)
        if let title = bannerTitle(status: status, done: done, total: total) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    if model.minutesActivity(for: meeting) != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let activity = model.minutesActivity(for: meeting, now: context.date) {
                                let elapsed = activity.elapsedSeconds.map { "（\($0 / 60)分\($0 % 60)秒経過）" } ?? ""
                                Text(activity.label + elapsed).font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                    if let detail = bannerDetail(done: done, total: total) {
                        Text(detail.summary).font(.system(size: 13)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let technicalDetails = detail.technicalDetails {
                            DisclosureGroup("技術的な詳細") {
                                Text(technicalDetails)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    if total > 1 {
                        HStack(spacing: 4) {
                            ForEach(0..<total, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill((indexed?.completedIndices.contains(index) ?? (index < done)) ? WorkspaceTheme.ready
                                          : ((indexed?.activeIndices.contains(index) ?? (index == done && meeting.minutesState == "pending")) ? WorkspaceTheme.accent : WorkspaceTheme.line))
                                    .frame(width: 26, height: 8)
                            }
                            Text("\(done) / \(total) パート").font(.system(size: 12)).padding(.leading, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .foregroundColor(status.isProblem ? WorkspaceTheme.warningText : WorkspaceTheme.chipText)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(status.isProblem ? WorkspaceTheme.warningFill : WorkspaceTheme.infoFill))
            .padding(.horizontal, 28).padding(.top, 14)
        }
    }

    private func bannerTitle(status: MeetingWorkspaceStatus, done: Int, total: Int) -> String? {
        if model.minutesHoldReason(for: meeting) != nil {
            return total > 1 ? "保留中です（\(total) パート中 \(done) パート完成）" : "保留中です"
        }
        switch meeting.minutesState {
        case "pending":
            return total > 1 ? "議事録を作っています（\(total) パート中 \(done) パート完成）" : "議事録を作っています"
        case "failed":
            return total > 1 && done > 0 ? "途中で止まりました（\(total) パート中 \(done) パート完成）" : "議事録を作れませんでした"
        case "ready":
            return model.minutesActivity(for: meeting) == nil ? nil : "議事録の概要を仕上げています"
        default:
            return model.meetingTranscript(for: meeting).isEmpty ? nil : "議事録はまだありません"
        }
    }

    private func bannerDetail(done: Int, total: Int) -> MeetingMinutesFailurePresentation? {
        if let hold = model.minutesHoldReason(for: meeting) {
            return MeetingMinutesFailurePresentation(summary: hold, technicalDetails: nil)
        }
        return MeetingMinutesFailurePresentation.make(error: meeting.minutesError,
                                                state: meeting.minutesState,
                                                completedParts: done,
                                                totalParts: total)
    }

}

/// User-facing wording for a failed generation. The stored error remains
/// available on demand, but the primary banner never exposes model JSON or a
/// Swift error's associated-value dump.
struct MeetingMinutesFailurePresentation: Equatable {
    let summary: String
    let technicalDetails: String?

    static func make(error: String?, state: String, completedParts: Int, totalParts: Int) -> Self? {
        let raw = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard state == "failed" || state == "pending" else { return nil }
        if raw == MeetingMinutesExecutionProgress.admissionRejectedMessage {
            return Self(summary: raw, technicalDetails: nil)
        }

        let progress: String
        if totalParts > 1 && completedParts > 0 {
            progress = "完成済みの \(completedParts) パートは残っています。"
        } else {
            progress = ""
        }

        if state == "pending" {
            return Self(summary: progress.isEmpty ? "完成したパートは保存し、残りを順番に進めます。" : progress,
                        technicalDetails: raw.isEmpty ? nil : raw)
        }

        let reason: String
        let lower = raw.lowercased()
        if raw.contains("invalidEvidence") {
            reason = "引用の確認に失敗しました。議事録の根拠を確認できませんでした。"
        } else if raw.contains("notJSON") {
            reason = "モデルの返答を議事録として読み取れませんでした。"
        } else if raw.contains("policyVersionMismatch") {
            reason = "議事録の形式が現在の仕様と一致しませんでした。"
        } else if lower.contains("timeout") || lower.contains("timed out") || raw.contains("時間切れ") || raw.contains("秒以内に返") || raw.contains("返事が返ってきません") {
            reason = "生成が時間内に完了しませんでした。"
        } else if lower.contains("sendfailed") || lower.contains("send failed") || raw.contains("送信に失敗") {
            reason = "議事録の生成依頼を送信できませんでした。"
        } else {
            reason = "議事録の生成に失敗しました。"
        }

        let next: String
        if progress.isEmpty {
            next = "自動再試行は行いません。必要なら「議事録を再生成」を選んでください。"
        } else if completedParts < totalParts {
            next = "\(progress) 失敗した残りのパートだけ続きから作れます。"
        } else {
            next = "自動再試行は行いません。必要なら「全パートを作り直す…」を選んでください。"
        }
        return Self(summary: "\(reason) \(next)", technicalDetails: raw.isEmpty ? nil : raw)
    }
}

// MARK: - Pieces

struct MeetingWorkspaceStatus {
    let meeting: MeetingRecord
    var held = false

    var shortLabel: String {
        let job = MeetingMinutesJob.load(store: MeetingStore(), id: meeting.id)
        let total = job?.envelopes.count ?? 0
        let indexed = job.flatMap { try? MeetingMinutesExecutionProgress.load(store: MeetingStore(), id: meeting.id, job: $0) }
        let done = indexed?.completedIndices.count ?? min(job?.completed.count ?? 0, total)
        let progress = total > 1 ? " \(done)/\(total)" : ""
        if held { return "保留中\(progress)" }
        switch meeting.minutesState {
        case "ready": return "議事録あり"
        case "pending":
            if let error = meeting.minutesError, error.contains("再試行") { return "作成中\(progress)・再試行待ち" }
            return "作成中\(progress)"
        case "failed": return done > 0 ? "途中で止まりました\(progress)" : "作れませんでした"
        default: return "議事録なし"
        }
    }

    var color: Color {
        switch meeting.minutesState {
        case "ready": return WorkspaceTheme.ready
        case "pending": return WorkspaceTheme.accent
        case "failed": return WorkspaceTheme.warning
        default: return WorkspaceTheme.line
        }
    }

    var isProblem: Bool { meeting.minutesState == "failed" }
}

private struct WorkspaceCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(WorkspaceTheme.muted)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkspaceTheme.line, lineWidth: 1))
    }
}

/// Two columns when the width allows both, otherwise one above the other.
/// The width comes from outside the scroll view so the first layout is
/// already the final one.
private struct AdaptiveColumns<Main: View, Side: View>: View {
    let width: CGFloat
    let sideWidth: CGFloat
    let minimumMainWidth: CGFloat
    @ViewBuilder let main: Main
    @ViewBuilder let side: Side

    var body: some View {
        if width >= sideWidth + minimumMainWidth + 20 {
            HStack(alignment: .top, spacing: 20) {
                main.frame(maxWidth: .infinity, alignment: .topLeading)
                side.frame(width: sideWidth)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                main
                side
            }
        }
    }
}

enum WorkspaceTheme {
    static let ground = Color(red: 0.957, green: 0.953, blue: 0.937)
    static let sidebar = Color(red: 0.925, green: 0.922, blue: 0.898)
    static let header = Color(red: 0.980, green: 0.976, blue: 0.965)
    static let ink = Color(red: 0.106, green: 0.110, blue: 0.118)
    static let secondary = Color(red: 0.271, green: 0.278, blue: 0.247)
    static let muted = Color(red: 0.333, green: 0.341, blue: 0.310)
    static let line = Color(red: 0.788, green: 0.780, blue: 0.741)
    static let accent = Color(red: 0.094, green: 0.373, blue: 0.471)
    static let ready = Color(red: 0.184, green: 0.478, blue: 0.310)
    static let warning = Color(red: 0.698, green: 0.369, blue: 0.0)
    static let warningText = Color(red: 0.420, green: 0.227, blue: 0.0)
    static let warningFill = Color(red: 0.984, green: 0.945, blue: 0.890)
    static let infoFill = Color(red: 0.902, green: 0.941, blue: 0.953)
    static let chip = Color(red: 0.859, green: 0.914, blue: 0.933)
    static let chipText = Color(red: 0.063, green: 0.275, blue: 0.353)
}

enum WorkspaceFormat {
    static func zone(_ meeting: MeetingRecord) -> TimeZone { TimeZone(identifier: meeting.timeZone) ?? .current }

    static func clock(_ epoch: Double?, zone: TimeZone) -> String {
        guard let epoch else { return "--:--" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func timeRange(_ meeting: MeetingRecord) -> String {
        let z = zone(meeting)
        return "\(clock(meeting.startedAt, zone: z))–\(clock(meeting.endedAt, zone: z))"
    }

    static func plannedRange(_ meeting: MeetingRecord) -> String? {
        guard let start = meeting.calendarEventStart else { return nil }
        let z = zone(meeting)
        return "\(clock(start, zone: z))–\(clock(meeting.calendarEventEnd, zone: z))"
    }

    static func dayLabel(_ meeting: MeetingRecord) -> String {
        let z = zone(meeting)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = z
        let date = Date(timeIntervalSince1970: meeting.startedAt)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ja_JP")
        fmt.timeZone = z
        fmt.dateFormat = "M月d日（E）"
        let label = fmt.string(from: date)
        if calendar.isDateInToday(date) { return "今日 " + label }
        if calendar.isDateInYesterday(date) { return "昨日 " + label }
        return label
    }

    /// `[seg-N]` citations become small links to the transcript line; a
    /// token the parser did not accept as evidence stays plain text.
    static func cited(_ text: String, allowed: Set<String>, evidence: [MeetingEvidence] = []) -> AttributedString {
        var output = inlineCited(text, allowed: allowed)
        // The parser keeps grounding beside the text, claim by claim. A line
        // links to every segment whose claim it states (or is part of).
        let ids = evidenceIDs(for: text, evidence: evidence)
        if !ids.isEmpty && !text.contains("[seg-") {
            var link = AttributedString("  発言\(ids.count)件")
            link.link = URL(string: "clawgate-segment://" + ids.map { String($0.dropFirst(4)) }.joined(separator: ","))
            link.foregroundColor = WorkspaceTheme.accent
            link.font = .system(size: 12, weight: .semibold)
            output.append(link)
        }
        let materials = materialEvidenceIDs(for: text, evidence: evidence)
        for (index, id) in materials.enumerated() {
            var link = AttributedString("  資料\(index + 1)")
            link.link = URL(string: "clawgate-material://" + id)
            link.foregroundColor = WorkspaceTheme.accent
            link.font = .system(size: 12, weight: .semibold)
            output.append(link)
        }
        return output
    }

    static func materialEvidenceIDs(for text: String, evidence: [MeetingEvidence]) -> [String] {
        let squash = { (value: String) in value.filter { !$0.isWhitespace && !"。、，．.,".contains($0) } }
        let line = squash(text)
        guard !line.isEmpty else { return [] }
        var seen = Set<String>()
        return evidence.filter { item in
            let claim = squash(item.claim)
            return !claim.isEmpty && (line.contains(claim) || claim.contains(line))
        }.flatMap { $0.materialIds ?? [] }.filter { seen.insert($0).inserted }
    }

    static func evidenceIDs(for text: String, evidence: [MeetingEvidence]) -> [String] {
        let squash = { (value: String) in value.filter { !$0.isWhitespace && !"。、，．.,".contains($0) } }
        let line = squash(text)
        guard line.count >= 8 else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for item in evidence {
            let claim = squash(item.claim)
            guard claim.count >= 8, line.contains(claim) || claim.contains(line) else { continue }
            for id in item.segmentIds where id.hasPrefix("seg-") && seen.insert(id).inserted { ids.append(id) }
        }
        return ids.sorted { (Int($0.dropFirst(4)) ?? 0) < (Int($1.dropFirst(4)) ?? 0) }
    }

    private static func inlineCited(_ text: String, allowed: Set<String>) -> AttributedString {
        let expression = try! NSRegularExpression(pattern: #"\s*\[(seg-[1-9][0-9]*)\]"#)
        let ns = text as NSString
        var output = AttributedString()
        var offset = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            output.append(AttributedString(ns.substring(with: NSRange(location: offset, length: match.range.location - offset))))
            if allowed.contains(id) {
                var link = AttributedString(" 発言#\(id.dropFirst(4))")
                link.link = URL(string: "clawgate-segment://\(id.dropFirst(4))")
                link.foregroundColor = WorkspaceTheme.accent
                link.font = .system(size: 12)
                output.append(link)
            }
            offset = match.range.location + match.range.length
        }
        output.append(AttributedString(ns.substring(from: offset)))
        return output
    }

    /// The Mac's own user is the meeting owner; their name reads as "あなた".
    static func isOwner(_ name: String) -> Bool {
        // Word order differs between sources ("Given Family" / "Family Given"),
        // so compare the set of name parts rather than the string.
        let parts = { (value: String) in
            Set(value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
        }
        let full = parts(NSFullUserName())
        let candidate = parts(name)
        guard full.count >= 2, !candidate.isEmpty else { return false }
        return candidate == full
    }

    static func ownerFirst(_ names: [String]) -> [String] {
        names.filter(isOwner) + names.filter { !isOwner($0) }
    }

    static func safeExternalURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "calendar.google.com" || host == "www.google.com" || host == "docs.google.com" else { return nil }
        return url
    }
}
