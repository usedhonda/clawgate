import AVFoundation
import AppKit
import Combine
import SwiftUI

/// The Minutes tab: every recorded meeting, and the minutes written for the one
/// selected. Reading is cheap (a handful of small JSON files), so the list is
/// reloaded whenever the model says a record changed rather than cached.
struct MeetingMinutesPetView: View {
    @ObservedObject var model: PetModel

    @State private var meetings: [MeetingRecord] = []
    @State private var selectedID: String?
    @State private var minutes: MeetingMinutes?
    @State private var showTranscript = false
    @State private var evidenceSegment: Int?
    @State private var copied = false
    @State private var archiveStart = Date().addingTimeInterval(-3600)
    @State private var archiveEnd = Date()
    @State private var archiveBusy = false
    @State private var archiveError: String?
    @State private var archiveCoverage: (mic: Double, system: Double)?
    @State private var coverageRequest = UUID()
    @State private var candidates: [MeetingCandidate] = []
    @State private var selectedCandidate: MeetingCandidate?
    @State private var showManualRange = false
    @State private var calendarError: String?
    @State private var calendarBusy = false
    @State private var calendarConnecting = false
    @State private var speakerSegment: TranscriptSegment?
    @State private var speakerLabel = ""
    @State private var audioPlayer: AVAudioPlayer?
    @State private var searchText = ""
    @State private var filterHasMinutes = false
    @State private var showExcluded = false
    @State private var collapsedDays: Set<Date> = []
    @State private var showOlderStored = false
    @State private var listHeight: CGFloat = 230

    private struct MeetingCard: Identifiable {
        let id: String
        let date: Date
        let meeting: MeetingRecord?
        let candidate: MeetingCandidate?
        var hasMinutes: Bool { meeting?.minutesState == "ready" }
    }

    private var selected: MeetingRecord? {
        meetings.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            archiveControls
            Divider().opacity(0.15)
            if cards.isEmpty {
                emptyState
            } else {
                meetingList
                Divider().opacity(0.15)
                detail
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { candidates = model.meetingCandidates; reload(); loadCandidates(); loadCoverage() }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            model.refreshMeetingSources()
        }
        .onChange(of: archiveStart) { _ in loadCoverage() }
        .onChange(of: archiveEnd) { _ in loadCoverage() }
        .onChange(of: model.meetingsRevision) { _ in reload() }
        .onChange(of: model.meetingCandidates) { found in candidates = found }
        .onChange(of: model.meetingSourcesBusy) { busy in
            calendarBusy = busy
            if !busy { calendarError = model.meetingSourcesError }
        }
        .onChange(of: searchText) { _ in reload() }
    }

    private var archiveControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("会議候補")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(calendarBusy ? "読込中…" : "予定を更新") { loadCandidates() }
                    .disabled(calendarBusy)
                Button(calendarConnecting ? "接続中…" : "Googleを接続") { connectCalendar() }
                    .disabled(calendarConnecting)
            }
            if let calendarError {
                Text(calendarError).foregroundColor(.yellow.opacity(0.8))
            } else if candidates.isEmpty && !calendarBusy {
                Text("過去7日の会議候補はありません。予定は自動更新します。")
                    .foregroundColor(.white.opacity(0.55))
            }
            if let candidate = selectedCandidate {
                Text("予定: \(formattedRange(candidate.start, candidate.end))")
                if let proposedStart = candidate.proposedStart, let proposedEnd = candidate.proposedEnd {
                    Text("録音からの提案: \(formattedRange(proposedStart, proposedEnd))")
                } else {
                    Text("録音から会話区間を特定できませんでした")
                        .foregroundColor(.yellow)
                }
                Text("区間の根拠: \(candidate.boundaryEvidence)")
                    .fixedSize(horizontal: false, vertical: true)
                if candidate.matchStatus == "ambiguous" {
                    Text("複数の予定が該当します。この予定を選択しても会議との一致は未確定です。")
                        .foregroundColor(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("予定選択を解除して日時だけで作成") { selectedCandidate = nil }

            }
            DisclosureGroup("日時を手動で指定", isExpanded: $showManualRange) {
                DatePicker("開始", selection: $archiveStart, displayedComponents: [.date, .hourAndMinute])
                DatePicker("終了", selection: $archiveEnd, displayedComponents: [.date, .hourAndMinute])
            }
            if (selectedCandidate != nil || showManualRange),
               let coverage = archiveCoverage, archiveStart < archiveEnd {
                let duration = archiveEnd.timeIntervalSince(archiveStart)
                Text("保存済み区間: マイク \(Int(100 * coverage.mic / duration))% / PC音声 \(Int(100 * coverage.system / duration))%（欠落は無音を意味しません）")
                    .foregroundColor(coverage.mic < duration * 0.9 ? .yellow : .white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if selectedCandidate != nil || showManualRange {
                HStack {
                    Button(archiveBusy ? "音声を処理中…" : selectedCandidate != nil && !showManualRange ? "この会議を文字起こし" : "この範囲を文字起こし") {
                        archiveBusy = true
                        archiveError = nil
                        let candidate = selectedCandidate
                        let title = candidate?.title
                        model.createArchivedMeeting(start: archiveStart, end: archiveEnd, title: title, candidate: candidate) { result in
                            archiveBusy = false
                            switch result {
                            case .success(let record):
                                reload()
                                select(record)
                                model.requestMinutes(for: record)
                            case .failure(let error):
                                archiveError = "文字起こしできませんでした: \(error)"
                            }
                        }
                    }
                    .disabled(archiveBusy || archiveStart >= archiveEnd ||
                              archiveStart < Date().addingTimeInterval(-MeetingAudioArchive.retentionSeconds) ||
                              (!showManualRange && selectedCandidate.map {
                                  $0.matchStatus == "noConversation" || $0.proposedStart == nil || $0.proposedEnd == nil
                              } == true))
                    Spacer()
                }
            }
            if let archiveError {
                Text(archiveError).foregroundColor(.red.opacity(0.8))
            }
        }
        .font(.system(size: 10))
        .foregroundColor(.white.opacity(0.75))
        .datePickerStyle(.compact)
        .buttonStyle(.borderless)
        .padding(9)
    }

    private func formattedRange(_ start: Date, _ end: Date) -> String {
        "\(DateFormatter.localizedString(from: start, dateStyle: .short, timeStyle: .short))–\(DateFormatter.localizedString(from: end, dateStyle: .short, timeStyle: .short))"
    }

    private func loadCandidates() {
        guard !calendarBusy else { return }
        calendarBusy = true
        model.refreshMeetingSources(force: true)
        candidates = model.meetingCandidates
    }

    private func connectCalendar() {
        guard !calendarConnecting else { return }
        calendarConnecting = true
        DispatchQueue.global(qos: .utility).async {
            let paths = [Bundle.main.resourceURL?.appendingPathComponent("gog").path, "/opt/homebrew/bin/gog", "/usr/local/bin/gog"].compactMap { $0 }
            guard let binary = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                DispatchQueue.main.async {
                    calendarConnecting = false
                    calendarError = "カレンダー連携ツールがありません。"
                }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["auth", "status", "--json", "--no-input"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let statusStarted = (try? process.run()) != nil
            let status = statusStarted ? output.fileHandleForReading.readDataToEndOfFile() : Data()
            if statusStarted { process.waitUntilExit() }
            let arguments = (try? MeetingCandidateSource.calendarAuthorizationArguments(status: status))
            let authorized: Bool
            if statusStarted && process.terminationStatus == 0, let arguments {
                let auth = Process()
                auth.executableURL = URL(fileURLWithPath: binary)
                auth.arguments = arguments
                auth.standardOutput = FileHandle.nullDevice
                auth.standardError = FileHandle.nullDevice
                let started = (try? auth.run()) != nil
                if started { auth.waitUntilExit() }
                authorized = started && auth.terminationStatus == 0
            } else {
                authorized = false
            }
            DispatchQueue.main.async {
                calendarConnecting = false
                if authorized { model.refreshMeetingSources(force: true) }
                else { calendarError = "Googleの接続を完了できませんでした。" }
            }
        }
    }

    private func loadCoverage() {
        let request = UUID()
        coverageRequest = request
        archiveCoverage = nil
        let start = archiveStart.timeIntervalSince1970
        let end = archiveEnd.timeIntervalSince1970
        guard start < end else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            let archive = MeetingAudioArchive()
            let mic = archive.coveredSeconds(start: start, end: end, source: "mic")
            let system = archive.coveredSeconds(start: start, end: end, source: "system")
            DispatchQueue.main.async {
                guard coverageRequest == request else { return }
                archiveCoverage = (mic, system)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("録音した会議を選ぶと、ここに文字起こしと議事録が並びます")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var cards: [MeetingCard] {
        let candidateCards = candidates.compactMap { candidate -> MeetingCard? in
            let meeting = MeetingWorkspace.associatedRecord(candidate: candidate, records: meetings)
            let haystack = ([candidate.title] + candidate.attendeeNames).joined(separator: " ").lowercased()
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || haystack.contains(searchText.lowercased()) else { return nil }
            guard !filterHasMinutes || hasReadableMaterial(meeting: meeting, candidate: candidate) else { return nil }
            // A confirmed one-person calendar appointment with no minutes is not a meeting card.
            let checked = model.googleMaterial(for: candidate)?.status == .none || model.googleMaterial(for: candidate)?.status == .available
            if !showExcluded, checked, candidate.humanAttendeeCount == 1,
               (meeting?.participants.count ?? 0) <= 1,
               !hasReadableMaterial(meeting: meeting, candidate: candidate) { return nil }
            return MeetingCard(id: "candidate:\(candidate.id)", date: candidate.start, meeting: meeting, candidate: candidate)
        }
        let associatedMeetingIDs = Set(candidates.compactMap { MeetingWorkspace.associatedRecord(candidate: $0, records: meetings)?.id })
        let allStoredCards = meetings.compactMap { meeting -> MeetingCard? in
            guard !associatedMeetingIDs.contains(meeting.id) else { return nil }
            let haystack = ([meeting.title ?? ""] + meeting.participants).joined(separator: " ").lowercased()
            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || haystack.contains(searchText.lowercased()) else { return nil }
            guard !filterHasMinutes || hasReadableMaterial(meeting: meeting, candidate: nil) else { return nil }
            return MeetingCard(id: "stored:\(meeting.id)", date: Date(timeIntervalSince1970: meeting.startedAt), meeting: meeting, candidate: nil)
        }
        let storedCards = showOlderStored ? allStoredCards : allStoredCards.filter {
            $0.date >= Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        }
        return (candidateCards + storedCards).sorted { $0.date > $1.date }
    }

    private var groupedCards: [(Date, [MeetingCard])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: cards) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day, default: []].sorted { $0.date < $1.date })
        }
    }

    private var meetingList: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                TextField("タイトル・参加者を検索", text: $searchText)
                Toggle("議事録あり", isOn: $filterHasMinutes).toggleStyle(.checkbox)
                Spacer()
                Toggle("除外した予定", isOn: $showExcluded).toggleStyle(.checkbox)
                Slider(value: $listHeight, in: 140...340).frame(width: 50).help("一覧の高さ")
            }
            .font(.system(size: 10))
            .padding(.horizontal, 10)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(groupedCards, id: \.0) { day, dayCards in
                        let open = !collapsedDays.contains(day)
                        Button {
                            if open { collapsedDays.insert(day) } else { collapsedDays.remove(day) }
                        } label: {
                            Label("\(dayLabel(day)) · \(dayCards.count)", systemImage: open ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                        }.buttonStyle(.plain)
                        if open {
                            ForEach(dayCards) { card in
                                cardRow(card)
                            }
                        }
                    }
                    if !showOlderStored && meetings.contains(where: {
                        $0.startedAt < (Calendar.current.date(byAdding: .day, value: -7, to: Date())?.timeIntervalSince1970 ?? 0)
                    }) {
                        Button("古い保存済み会議を表示") { showOlderStored = true }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .frame(height: listHeight)
        }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今日" }
        if Calendar.current.isDateInYesterday(day) { return "昨日" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年M月d日 (EEE)"
        return f.string(from: day)
    }

    private func cardRow(_ card: MeetingCard) -> some View {
        let meeting = card.meeting
        let candidate = card.candidate
        let selected = meeting?.id == selectedID
        return VStack(alignment: .leading, spacing: 3) {
            Button { choose(card) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(stateColor(cardState(card))).frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting?.title ?? candidate?.title ?? "会議")
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundColor(.white.opacity(0.9)).lineLimit(1)
                        Text(cardTimeRange(card) + " · " + displayNames(card)).help(displayNames(card))
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.52)).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(cardStateLabel(cardState(card))).font(.system(size: 9)).foregroundColor(.white.opacity(0.58))
                        Text(provenance(card)).font(.system(size: 8)).foregroundColor(.white.opacity(0.42))
                    }
                }
            }.buttonStyle(.plain)
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5))
            if !hasReadableMaterial(meeting: meeting, candidate: candidate), let candidate {
                HStack {
                    Text("選択でカレンダーを開く").foregroundColor(.secondary)
                    Spacer()
                    Button("文字起こしを準備…") { prepareCreate(candidate) }
                }.font(.system(size: 10)).buttonStyle(.borderless)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
    }

    private func cardTime(_ date: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date) }
    private func cardState(_ card: MeetingCard) -> String {
        if let meeting = card.meeting, model.minutes(for: meeting.id) != nil {
            return meeting.minutesState == "pending" ? "updating" : meeting.minutesState == "failed" ? "stale" : "has-minutes"
        }
        if let material = material(for: card), !material.notes.isEmpty { return "available" }
        guard let meeting = card.meeting else {
            if let material = material(for: card) {
                switch material.status { case .checking: return "checking"; case .serviceUnavailable: return "service"; case .permissionDenied: return "permission"; case .failed: return "unavailable"; case .ambiguous: return "ambiguous"; default: break }
            }
            return material(for: card) == nil ? "checking" : "none"
        }
        switch meeting.minutesState { case "pending": return "generating"; case "ready": return "unavailable"; case "failed": return "unavailable"; default: return "none" }
    }
    private func cardStateLabel(_ state: String) -> String { ["updating":"議事録あり・更新中", "stale":"議事録あり・更新失敗", "service":"Docs API設定が必要", "permission":"権限確認が必要", "ambiguous":"資料の対応を確認中", "available":"Meetメモあり", "generating":"生成中", "none":"議事録なし", "checking":"確認中", "unavailable":"利用不可", "has-minutes":"議事録あり"][state] ?? state }

    private func material(for card: MeetingCard) -> MeetingGoogleMaterials.Snapshot? {
        if let candidate = card.candidate { return model.googleMaterial(for: candidate) }
        if let meeting = card.meeting { return model.googleMaterial(for: meeting) }
        return nil
    }

    private func hasReadableMaterial(meeting: MeetingRecord?, candidate: MeetingCandidate?) -> Bool {
        if let meeting, model.minutes(for: meeting.id) != nil { return true }
        let card = MeetingCard(id: "material-check", date: Date(), meeting: meeting, candidate: candidate)
        guard let snapshot = material(for: card) else { return false }
        return !snapshot.notes.isEmpty
    }
    private func provenance(_ card: MeetingCard) -> String {
        let local = card.meeting.map { model.minutes(for: $0.id) != nil } ?? false
        let meet = material(for: card).map { !$0.segments.isEmpty || !$0.notes.isEmpty } ?? false
        if local && meet { return "Meet + ClawGate" }
        if meet { return "Meet" }
        if local { return "ClawGate" }
        return card.candidate == nil ? "" : "Calendar"
    }

    private func choose(_ card: MeetingCard) {
        if let meeting = card.meeting, hasReadableMaterial(meeting: meeting, candidate: card.candidate) { select(meeting); return }
        guard let candidate = card.candidate else {
            if let meeting = card.meeting { select(meeting) }
            return
        }
        if let url = candidate.calendarURL, let parsed = safeExternalURL(url) { NSWorkspace.shared.open(parsed) }
    }

    private func prepareCreate(_ candidate: MeetingCandidate) {
        selectedCandidate = candidate; showManualRange = false
        archiveStart = candidate.proposedStart ?? candidate.start; archiveEnd = candidate.proposedEnd ?? candidate.end
    }

    private func displayNames(_ card: MeetingCard) -> String {
        let confirmed = card.meeting?.participants ?? []
        let invited = card.candidate?.attendeeNames ?? []
        let names = Array(Set(confirmed)).sorted()
        let invitedOnly = invited.filter { !names.contains($0) }
        if names.isEmpty && invitedOnly.isEmpty { return "参加者未確認" }
        var parts: [String] = []
        if !names.isEmpty { parts.append("確認: " + names.joined(separator: ", ")) }
        if !invitedOnly.isEmpty { parts.append("招待: " + invitedOnly.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func cardTimeRange(_ card: MeetingCard) -> String {
        let end = card.meeting?.endedAt.map(Date.init(timeIntervalSince1970:)) ?? card.candidate?.end
        guard let end else { return cardTime(card.date) }
        return "\(cardTime(card.date))–\(cardTime(end))"
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "available", "has-minutes": return .green.opacity(0.8)
        case "generating", "checking", "updating", "stale": return .yellow.opacity(0.8)
        case "unavailable": return .red.opacity(0.8)
        case "permission", "ambiguous", "service": return .orange.opacity(0.8)
        default: return .white.opacity(0.25)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let meeting = selected {
            VStack(alignment: .leading, spacing: 0) {
                if let evidence = meeting.boundaryEvidence, !evidence.isEmpty {
                    Text("録音区間: \(evidence)")
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                if let accepted = MeetingStore().loadAcceptedMinutes(id: meeting.id), !accepted.unresolvedNotes.isEmpty {
                    Text(accepted.unresolvedNotes.joined(separator: "\n"))
                        .font(.system(size: 11)).foregroundColor(.yellow)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                if !showTranscript && minutes != nil && meeting.minutesState != "ready" {
                    Text(meeting.minutesState == "failed"
                         ? "議事録の更新に失敗しました。前回の議事録を表示しています。"
                         : "議事録を更新中です。完了するまで前回の議事録を表示しています。")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        if showTranscript {
                            transcriptRows(meeting)
                        } else {
                            if minutes == nil { materialSection(meeting) }
                            minutesDocument(meeting)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .onChange(of: showTranscript) { showing in
                        guard showing, let segment = evidenceSegment else { return }
                        DispatchQueue.main.async { proxy.scrollTo(segment, anchor: .top) }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if let safe = safeExternalURL(url.absoluteString) {
                            NSWorkspace.shared.open(safe); return .handled
                        }
                        guard url.scheme == "clawgate-segment",
                              let number = Int(url.host ?? ""), number > 0 else { return .discarded }
                        evidenceSegment = number
                        showTranscript = true
                        return .handled
                    })
                }
                if showTranscript, speakerSegment != nil {
                    HStack {
                        TextField("話者名", text: $speakerLabel)
                        Button("この発話に付ける") { saveSpeakerLabel(meeting) }
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                }
                actionBar(meeting)
            }
        } else {
            Spacer()
        }
    }

    private func bodyText(_ meeting: MeetingRecord) -> String {
        if let minutes {
            return minutes.markdown(record: meeting)
        }
        switch meeting.minutesState {
        case "pending": return "議事録を作っています…"
        case "failed": return "作れませんでした: " + (meeting.minutesError ?? "理由不明")
        default: return "まだ議事録はありません。「作る」を押してください。"
        }
    }

    private func minutesDocument(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(bodyText(meeting).components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("# ") {
                    Text(String(line.dropFirst(2))).font(.system(size: 18, weight: .semibold)).padding(.bottom, 4)
                } else if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3))).font(.system(size: 14, weight: .semibold)).padding(.top, 12)
                } else if line.hasPrefix("### ") {
                    Text(String(line.dropFirst(4))).font(.system(size: 13, weight: .semibold)).padding(.top, 7)
                } else if !line.isEmpty {
                    Text(citedBody(meeting, body: line)).font(.system(size: 12)).lineSpacing(4)
                }
            }
        }
    }

    private func citedBody(_ meeting: MeetingRecord, body: String) -> AttributedString {
        let allowed = Set(minutes?.evidence?.flatMap(\.segmentIds) ?? [])
        let expression = try! NSRegularExpression(pattern: #"\[((?:seg-[1-9][0-9]*|meet-[^\]\n]+))\]"#)
        let manifest = MeetingStore().loadAcceptedMinutes(id: meeting.id)
        let nsBody = body as NSString
        let matches = expression.matches(in: body, range: NSRange(location: 0, length: nsBody.length))
        var output = AttributedString()
        var offset = 0
        for match in matches {
            let token = nsBody.substring(with: match.range)
            let id = String(token.dropFirst().dropLast())
            guard allowed.contains(id) else { continue }
            output.append(AttributedString(nsBody.substring(with: NSRange(location: offset,
                                                                          length: match.range.location - offset))))
            var linked = AttributedString(token)
            if id.hasPrefix("seg-") {
                linked.link = URL(string: "clawgate-segment://\(id.dropFirst(4))")
            } else if let original = manifest?.segments.first(where: { $0.id == id }),
                      let url = original.sourceURL.flatMap(safeExternalURL) {
                linked = AttributedString("[Meet原文]"); linked.link = url
            }
            linked.foregroundColor = .cyan
            output.append(linked)
            offset = match.range.location + match.range.length
        }
        output.append(AttributedString(nsBody.substring(from: offset)))
        return output
    }

    private func transcriptText(_ meeting: MeetingRecord) -> String {
        let zone = TimeZone(identifier: meeting.timeZone) ?? .current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "HH:mm"
        let lines = model.meetingTranscript(for: meeting).map { seg -> String in
            let when = seg.capturedAt.map { fmt.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--"
            let who = seg.speakerName ?? (seg.stream == "system" ? "PC音声・話者未確認" : "マイク・話者未確認")
            return "[\(when)] \(who): \(seg.text)"
        }
        return lines.isEmpty ? "この会議の文字起こしは残っていません。" : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func materialSection(_ meeting: MeetingRecord) -> some View {
        if let snapshot = model.googleMaterial(for: meeting), !snapshot.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Google Meetの生成メモ（発言原文とは別資料）")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.cyan)
                ForEach(snapshot.notes) { note in
                    materialText(note.text, sourceURL: note.sourceURL)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        } else if let snapshot = model.googleMaterial(for: meeting), snapshot.status != .none {
            Text(materialStatusLabel(snapshot.status))
                .font(.system(size: 10)).foregroundColor(.yellow.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    private func materialText(_ text: String, sourceURL: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).textSelection(.enabled)
            if let url = safeExternalURL(sourceURL) {
                Button("出典を開く") { NSWorkspace.shared.open(url) }.font(.system(size: 9))
            }
        }
    }

    private func materialStatusLabel(_ status: MeetingGoogleMaterials.MaterialStatus) -> String {
        switch status {
        case .checking: return "Meetメモを確認中…"
        case .permissionDenied: return "Meetメモの権限がありません"
        case .serviceUnavailable: return "Google Docs APIの有効化が必要です。資料なしとは判定していません。"
        case .failed: return "Meetメモを読み取れませんでした"
        case .ambiguous: return "Meetメモの候補が複数あります"
        case .available: return "Meetメモは空です"
        case .none: return ""
        }
    }

    private func safeExternalURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "calendar.google.com" || host == "www.google.com" || host == "docs.google.com" else { return nil }
        return url
    }

    @ViewBuilder
    private func transcriptRows(_ meeting: MeetingRecord) -> some View {
        if let accepted = MeetingStore().loadAcceptedMinutes(id: meeting.id) {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("この議事録を生成した時点の原文").foregroundColor(.secondary)
                ForEach(accepted.segments, id: \.id) { segment in
                    Text("[\(segment.id)] \(segment.speakerName ?? "話者未確認"): \(segment.text)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(Int(segment.id.dropFirst(4)) ?? -1)
                }
            }.font(.system(size: 11)).padding(12).textSelection(.enabled)
            DisclosureGroup("最新の文字起こし・話者名の修正") { currentTranscriptRows(meeting) }
                .padding(.horizontal, 12)
        } else { currentTranscriptRows(meeting) }
    }

    private func currentTranscriptRows(_ meeting: MeetingRecord) -> some View {
        let lines = model.meetingTranscript(for: meeting)
        let canCorrect = MeetingStore().loadBackfill(id: meeting.id) != nil
        return LazyVStack(alignment: .leading, spacing: 5) {
            if lines.isEmpty { Text("この会議の文字起こしは残っていません。") }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, segment in
                HStack(alignment: .top) {
                    Button {
                        guard canCorrect else { return }
                        speakerSegment = segment
                        speakerLabel = segment.speakerName ?? ""
                    } label: {
                        let who = segment.speakerName ?? (segment.stream == "system" ? "PC音声・話者未確認" : "マイク・話者未確認")
                        Text("[seg-\(index + 1)] \(who): \(segment.text)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .disabled(!canCorrect)
                    if let clip = MeetingStore().audioClip(id: meeting.id, segment: segment) {
                        Button("再生") { play(clip) }
                    }
                }
                .buttonStyle(.plain)
                .id(index + 1)
                .background(evidenceSegment == index + 1 ? Color.yellow.opacity(0.12) : Color.clear)
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.85))
        .padding(12)
    }

    private func play(_ clip: (url: URL, offset: TimeInterval)) {
        do {
            audioPlayer?.stop()
            let player = try AVAudioPlayer(contentsOf: clip.url)
            player.currentTime = min(max(0, clip.offset), player.duration)
            audioPlayer = player
            player.play()
        } catch {
            archiveError = "音声を再生できませんでした: \(error)"
        }
    }

    private func saveSpeakerLabel(_ meeting: MeetingRecord) {
        guard let segment = speakerSegment else { return }
        do {
            try MeetingStore().labelSpeaker(id: meeting.id, segment: segment, name: speakerLabel)
            speakerSegment = nil
            reload()
        } catch {
            archiveError = "話者名を保存できませんでした: \(error)"
        }
    }

    private func actionBar(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: 8) {
            Button(copied ? "コピーしました" : "コピー") { copy(meeting) }
            Button(meeting.minutesState == "ready" ? "作り直す" : "作る") {
                model.regenerateMinutes(for: meeting)
            }
            .disabled(meeting.minutesState == "pending")
            Button(showTranscript ? "議事録に戻る" : "文字起こし") { showTranscript.toggle() }
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundColor(.white.opacity(0.7))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
    }

    // MARK: - Actions

    private func reload() {
        meetings = model.meetingList().filter { $0.mergedIntoMeetingID == nil }
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
            selectedID = meetings.first?.id
        }
        minutes = selectedID.flatMap { model.minutes(for: $0) }
    }

    private func select(_ meeting: MeetingRecord) {
        selectedID = meeting.id
        showTranscript = false
        evidenceSegment = nil
        copied = false
        speakerSegment = nil
        minutes = model.minutes(for: meeting.id)
    }

    private func copy(_ meeting: MeetingRecord) {
        let text = showTranscript ? transcriptText(meeting) : bodyText(meeting)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
