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
    @State private var copied = false

    private var selected: MeetingRecord? {
        meetings.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if meetings.isEmpty {
                emptyState
            } else {
                meetingList
                Divider().opacity(0.15)
                detail
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.meetingsRevision) { _ in reload() }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("Meet の通話が終わると、ここに議事録が並びます")
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
                ScrollView(.vertical, showsIndicators: true) {
                    Text(showTranscript ? transcriptText(meeting) : bodyText(meeting))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                actionBar(meeting)
            }
        } else {
            Spacer()
        }
    }

    private func bodyText(_ meeting: MeetingRecord) -> String {
        if let minutes { return minutes.markdown(record: meeting) }
        switch meeting.minutesState {
        case "pending": return "議事録を作っています…"
        case "failed": return "作れませんでした: " + (meeting.minutesError ?? "理由不明")
        default: return "まだ議事録はありません。「作る」を押してください。"
        }
    }

    private func transcriptText(_ meeting: MeetingRecord) -> String {
        let zone = TimeZone(identifier: meeting.timeZone) ?? .current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = zone
        fmt.dateFormat = "HH:mm"
        let lines = model.meetingTranscript(for: meeting).map { seg -> String in
            let when = seg.capturedAt.map { fmt.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--"
            let who = seg.speakerName ?? (seg.stream == "system" ? "相手" : (seg.speaker == "self" ? "ご主人様" : "—"))
            return "[\(when)] \(who): \(seg.text)"
        }
        return lines.isEmpty ? "この会議の文字起こしは残っていません。" : lines.joined(separator: "\n")
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
        meetings = model.meetingList()
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
            selectedID = meetings.first?.id
        }
        minutes = selectedID.flatMap { model.minutes(for: $0) }
    }

    private func select(_ meeting: MeetingRecord) {
        selectedID = meeting.id
        showTranscript = false
        copied = false
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
