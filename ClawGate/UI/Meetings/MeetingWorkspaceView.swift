import AppKit
import SwiftUI

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
        let status = MeetingWorkspaceStatus(meeting: meeting)
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
                if let safe = WorkspaceFormat.safeExternalURL(url.absoluteString) {
                    NSWorkspace.shared.open(safe); return .handled
                }
                return .discarded
            })
        }
        .foregroundColor(WorkspaceTheme.ink)
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
                if let shown {
                    Button(copied ? "コピーしました" : "コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shown.minutes.markdown(record: meeting), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
        .background(WorkspaceTheme.header)
        .overlay(Divider(), alignment: .bottom)
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
        if let snapshot = model.googleMaterial(for: meeting), !snapshot.notes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Google Meet のメモと予定の資料です。取りこぼしの確認に使うもので、議事録の発言の根拠には使いません。")
                    .font(.system(size: 13)).foregroundColor(WorkspaceTheme.secondary)
                ForEach(snapshot.notes) { note in
                    WorkspaceCard(title: nil) {
                        Text(note.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                        if let url = WorkspaceFormat.safeExternalURL(note.sourceURL) {
                            Button("出典を開く") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        } else {
            Text(materialStatus)
                .font(.system(size: 14)).foregroundColor(WorkspaceTheme.secondary)
        }
    }

    private var materialStatus: String {
        switch model.googleMaterial(for: meeting)?.status {
        case .checking?: return "資料を確認しています…"
        case .permissionDenied?: return "資料を読む権限がありません。"
        case .serviceUnavailable?: return "Google Docs API の有効化が必要です。資料がないとは判定していません。"
        case .failed?: return "資料を読み取れませんでした。"
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
        case .failed?: return "取得できず"
        case .ambiguous?: return "候補が複数"
        case .checking?: return "確認中"
        case .available?: return "文字起こしなし"
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
    @State private var confirmRegenerate = false

    var body: some View {
        let status = MeetingWorkspaceStatus(meeting: meeting)
        let total = job?.envelopes.count ?? 0
        let done = min(job?.completed.count ?? 0, total)
        if let title = bannerTitle(status: status, done: done, total: total) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .bold))
                    if let detail = bannerDetail {
                        Text(detail).font(.system(size: 13)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if total > 1 {
                        HStack(spacing: 4) {
                            ForEach(0..<total, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(index < done ? WorkspaceTheme.ready
                                          : (index == done && meeting.minutesState == "pending" ? WorkspaceTheme.accent : WorkspaceTheme.line))
                                    .frame(width: 26, height: 8)
                            }
                            Text("\(done) / \(total) パート").font(.system(size: 12)).padding(.leading, 6)
                        }
                    }
                }
                Spacer()
                actions(status: status, done: done, total: total)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .foregroundColor(status.isProblem ? WorkspaceTheme.warningText : WorkspaceTheme.chipText)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(status.isProblem ? WorkspaceTheme.warningFill : WorkspaceTheme.infoFill))
            .padding(.horizontal, 28).padding(.top, 14)
            .alert("最初から作り直しますか？", isPresented: $confirmRegenerate) {
                Button("作り直す") { model.regenerateMinutes(for: meeting) }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("完成済みのパートも作り直します。今読める議事録は、新しいものが完成するまで残ります。")
            }
        }
    }

    private func bannerTitle(status: MeetingWorkspaceStatus, done: Int, total: Int) -> String? {
        switch meeting.minutesState {
        case "pending":
            return total > 1 ? "議事録を作っています（\(total) パート中 \(done) パート完成）" : "議事録を作っています"
        case "failed":
            return total > 1 && done > 0 ? "途中で止まりました（\(total) パート中 \(done) パート完成）" : "議事録を作れませんでした"
        case "ready":
            return nil
        default:
            return model.meetingTranscript(for: meeting).isEmpty ? nil : "議事録はまだありません"
        }
    }

    private var bannerDetail: String? {
        if let error = meeting.minutesError, !error.isEmpty { return error }
        switch meeting.minutesState {
        case "pending": return "完成したパートは残したまま、順に作っています。"
        case "failed": return "完成した部分は残っています。続きから作り直せます。"
        default: return nil
        }
    }

    @ViewBuilder
    private func actions(status: MeetingWorkspaceStatus, done: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            switch meeting.minutesState {
            case "failed":
                if done > 0 && done < total {
                    Button("続きから作る") { model.resumeMinutes(for: meeting) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("最初から作り直す") { confirmRegenerate = true }.controlSize(.large)
                } else {
                    Button("もう一度作る") { model.regenerateMinutes(for: meeting) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            case "pending":
                EmptyView()
            default:
                Button("議事録を作る") { model.requestMinutes(for: meeting) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}

// MARK: - Pieces

struct MeetingWorkspaceStatus {
    let meeting: MeetingRecord

    var shortLabel: String {
        let job = MeetingMinutesJob.load(store: MeetingStore(), id: meeting.id)
        let total = job?.envelopes.count ?? 0
        let done = min(job?.completed.count ?? 0, total)
        let progress = total > 1 ? " \(done)/\(total)" : ""
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
        guard !ids.isEmpty, !text.contains("[seg-") else { return output }
        var link = AttributedString("  発言\(ids.count)件")
        link.link = URL(string: "clawgate-segment://" + ids.map { String($0.dropFirst(4)) }.joined(separator: ","))
        link.foregroundColor = WorkspaceTheme.accent
        link.font = .system(size: 12, weight: .semibold)
        output.append(link)
        return output
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
        // Word order differs between sources ("Yuzuru Honda" / "Honda Yuzuru"),
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
