import AVFoundation
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

    private var selected: MeetingRecord? {
        meetings.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            archiveControls
            Divider().opacity(0.15)
            if meetings.isEmpty {
                emptyState
            } else {
                meetingList
                Divider().opacity(0.15)
                detail
            }
        }
        .onAppear { reload(); loadCandidates(); loadCoverage() }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            loadCandidates()
        }
        .onChange(of: archiveStart) { _ in loadCoverage() }
        .onChange(of: archiveEnd) { _ in loadCoverage() }
        .onChange(of: model.meetingsRevision) { _ in reload() }
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
            if !candidates.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates) { candidate in
                            Button {
                                selectedCandidate = candidate
                                showManualRange = false
                                archiveStart = candidate.proposedStart ?? candidate.start
                                archiveEnd = candidate.proposedEnd ?? candidate.end
                            } label: {
                                let coverage = candidate.microphoneSeconds > 0
                                    ? "\(candidate.microphoneSeconds / 60)分録音" : "録音なし"
                                Text("\(DateFormatter.localizedString(from: candidate.start, dateStyle: .short, timeStyle: .short)) · \(candidate.title) · \(coverage)\(candidate.matchStatus == "ambiguous" ? " · 要確認" : "")")
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
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
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try MeetingCandidateSource.candidates() }
            DispatchQueue.main.async {
                calendarBusy = false
                switch result {
                case .success(let found):
                    candidates = found
                    if let selectedCandidate,
                       !found.contains(where: { $0.id == selectedCandidate.id && $0.proposedStart != nil }) {
                        self.selectedCandidate = nil
                    }
                    calendarError = nil
                case .failure(let error):
                    if let failure = error as? MeetingCandidateSource.Failure {
                        switch failure {
                        case .clientUnavailable:
                            calendarError = "カレンダー連携ツールがありません。日時指定は使えます。"
                        case .calendarUnavailable(.service):
                            calendarError = "Google Calendarを読み取れません。認証状態を確認してください。"
                        case .calendarUnavailable(.unauthenticated):
                            calendarError = "Google Calendarの認証がありません。アカウント接続後に更新してください。"
                        case .incompleteCalendarResult:
                            calendarError = "予定が多く、候補を完全に取得できません。日時指定を使ってください。"
                        }
                    } else {
                        calendarError = "予定の取得に失敗しました。日時指定は使えます。"
                    }
                }
            }
        }
    }

    private func connectCalendar() {
        guard !calendarConnecting else { return }
        calendarConnecting = true
        DispatchQueue.global(qos: .utility).async {
            let paths = ["/opt/homebrew/bin/gog", "/usr/local/bin/gog"]
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
                if authorized { loadCandidates() }
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

    private var meetingList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(meetings, id: \.id) { meeting in
                    row(meeting)
                        .contentShape(Rectangle())
                        .onTapGesture { select(meeting) }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 150)
    }

    private func row(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor(meeting.minutesState))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title ?? "会議")
                    .font(.system(size: 12, weight: meeting.id == selectedID ? .semibold : .regular))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Text(subtitle(meeting))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(meeting.id == selectedID ? Color.white.opacity(0.08) : Color.clear)
    }

    private func subtitle(_ meeting: MeetingRecord) -> String {
        let zone = TimeZone(identifier: meeting.timeZone) ?? .current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "M/d HH:mm"
        let when = fmt.string(from: Date(timeIntervalSince1970: meeting.startedAt))
        let minutesLong = Int(meeting.duration(now: Date().timeIntervalSince1970) / 60)
        var parts = ["\(when) · \(minutesLong)分"]
        if !meeting.participants.isEmpty { parts.append(meeting.participants.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "ready": return .green.opacity(0.8)
        case "pending": return .yellow.opacity(0.8)
        case "failed": return .red.opacity(0.8)
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
                if !showTranscript && minutes != nil && meeting.minutesState != "ready" {
                    Text(meeting.minutesState == "failed"
                         ? "議事録の更新に失敗しました。以下は統合前の旧議事録で、追加分は未反映です。"
                         : "議事録を更新中です。以下は統合前の旧議事録で、追加分は未反映です。")
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
                            Text(citedBody(meeting))
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
            let body = minutes.markdown(record: meeting)
            guard meeting.minutesState != "ready" else { return body }
            return "【旧議事録・部分的】追加された録音・文字起こしは未反映です。\n\n" + body
        }
        switch meeting.minutesState {
        case "pending": return "議事録を作っています…"
        case "failed": return "作れませんでした: " + (meeting.minutesError ?? "理由不明")
        default: return "まだ議事録はありません。「作る」を押してください。"
        }
    }

    private func citedBody(_ meeting: MeetingRecord) -> AttributedString {
        let body = bodyText(meeting)
        let allowed = Set(minutes?.evidence?.flatMap(\.segmentIds) ?? [])
        let expression = try! NSRegularExpression(pattern: #"\[seg-([1-9][0-9]*)\]"#)
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
            linked.link = URL(string: "clawgate-segment://\(id.dropFirst(4))")
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

    private func transcriptRows(_ meeting: MeetingRecord) -> some View {
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
