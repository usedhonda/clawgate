import SwiftUI

// MARK: - Dark Blue Color Palette

private enum PetColors {
    static let mainBg = Color(nsColor: NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 0.95))
    static let tabBarBg = Color(nsColor: NSColor(red: 0.13, green: 0.14, blue: 0.19, alpha: 1.0))
    static let userBubble = Color(nsColor: NSColor(red: 0.22, green: 0.35, blue: 0.65, alpha: 0.85))
    static let assistantBubble = Color(nsColor: NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 0.9))
    static let notificationBubble = Color(nsColor: NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 0.92))
    static let whisperBubble = Color(nsColor: NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 0.88))
}

// MARK: - Drag Handle for borderless window

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

class DragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Layer 2: Notification Bubble (auto-fade, click to open chat)

/// Brief notification bubble showing the latest assistant message
struct PetNotificationBubble: View {
    @ObservedObject var model: PetModel
    @State private var isVisible = true
    @State private var isHovered = false
    @State private var fadeTask: Task<Void, Never>?

    var body: some View {
        if isVisible, let lastMsg = model.notificationMessage {
            VStack(alignment: .leading, spacing: 2) {
                Text(lastMsg.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(lastMsg.text.count > 200 ? 15 : 8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: lastMsg.text.count > 100 ? 400 : 300)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(PetColors.notificationBubble)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    fadeTask?.cancel()
                } else {
                    startFadeTimer(for: lastMsg.text)
                }
            }
            .onTapGesture {
                model.toggleChat()
            }
            .onAppear {
                startFadeTimer(for: lastMsg.text)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func startFadeTimer(for text: String) {
        fadeTask?.cancel()
        let duration: UInt64 = text.count > 100 ? 12_000_000_000 : 6_000_000_000
        fadeTask = Task {
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) {
                    isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    model.dismissNotification()
                }
            }
        }
    }
}

// MARK: - Layer 3: Full Chat Panel

/// Full chat panel with message history and input
struct PetBubbleView: View {
    @ObservedObject var model: PetModel
    @FocusState private var isInputFocused: Bool
    @State private var userScrolledUp = false

    var body: some View {
        VStack(spacing: 0) {
            // Messages (header integrated into titlebar)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { msg in
                            ChatMessageView(message: msg)
                                .id(msg.id)
                        }
                        // Invisible anchor at bottom
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    // Immediate scroll (no animation) to avoid showing top content first
                    proxy.scrollTo("bottom", anchor: .bottom)
                    // Retry after layout settles (LazyVStack may not be fully rendered)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: model.messages.count) { _ in
                    if !userScrolledUp {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: model.streamingText) { _ in
                    if !userScrolledUp {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.1))

            // Input
            HStack(spacing: 8) {
                TextField("メッセージを入力...", text: $model.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .focused($isInputFocused)
                    .onSubmit { model.send() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.10))
                    .cornerRadius(18)

                Button(action: { model.send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(model.inputText.isEmpty ? .gray.opacity(0.5) : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(model.inputText.isEmpty || model.isStreaming)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 280, idealWidth: 360, minHeight: 300, idealHeight: 480)
        .background(PetColors.mainBg)
        .onAppear {
            isInputFocused = true
            model.loadHistory()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = model.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Chat Message View

struct ChatMessageView: View {
    let message: OpenClawChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                markdownText
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(message.role == .user ? 1.0 : 0.92))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.role == .user
                                  ? PetColors.userBubble
                                  : PetColors.assistantBubble)
                    )

                Text(timeString)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 4)

                if message.isStreaming {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.white.opacity(0.4))
                                .frame(width: 4, height: 4)
                        }
                    }
                    .padding(.leading, 8)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.timestamp)
    }

    @ViewBuilder
    private var markdownText: some View {
        if #available(macOS 13.0, *) {
            // Use AttributedString for basic markdown
            if let attributed = try? AttributedString(markdown: message.text,
                                                       options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(message.text)
            }
        } else {
            Text(message.text)
        }
    }
}

// MARK: - Tab Container (Chat + Notifications)

struct PetChatContainerView: View {
    @ObservedObject var model: PetModel
    @State private var selectedTab = "chat"

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar (also serves as drag handle for borderless window)
            HStack(spacing: 0) {
                tabButton("Chat", tab: "chat")
                tabButton("Summon", tab: "summon")
                tabButton("Notifs", tab: "notifications")
                Spacer()
            }
            .padding(.horizontal, 6)
            .background(PetColors.tabBarBg)
            .overlay(DragHandle())  // Enable window drag from tab bar

            Divider().opacity(0.15)

            // Content
            switch selectedTab {
            case "chat":
                PetBubbleView(model: model)
            case "summon":
                SummonResultsView(model: model)
            default:
                NotificationListView(model: model)
            }
        }
        .frame(minWidth: 280, idealWidth: 360, minHeight: 300, idealHeight: 480)
        .background(PetColors.mainBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: model.showSummonTab) { show in
            if show {
                selectedTab = "summon"
                model.showSummonTab = false
            }
        }
    }

    private func tabButton(_ title: String, tab: String) -> some View {
        Button(action: { selectedTab = tab }) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.45))
                Rectangle()
                    .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summon Results View

struct SummonResultsView: View {
    @ObservedObject var model: PetModel

    var body: some View {
        if model.summonResults.isEmpty {
            VStack {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.2))
                Text("Right-click → Omakase or Ask")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.summonResults) { entry in
                            SummonEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.summonResults.count) { _ in
                    if let last = model.summonResults.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

struct SummonEntryView: View {
    let entry: NotificationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: iconForSource(entry.source))
                    .font(.system(size: 11))
                    .foregroundColor(colorForSource(entry.source))
                Text(entry.source.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colorForSource(entry.source))
                Spacer()
                Text(timeString(entry.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }

            if #available(macOS 13.0, *) {
                if let attributed = try? AttributedString(markdown: entry.text,
                                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                        .textSelection(.enabled)
                } else {
                    Text(entry.text)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.9))
                        .textSelection(.enabled)
                }
            } else {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func iconForSource(_ source: String) -> String {
        switch source {
        case "omakase": return "sparkles"
        case "omakase_draft": return "pencil.and.outline"
        case "ask": return "questionmark.circle"
        case "draft_pr": return "doc.text"
        default: return "circle"
        }
    }

    private func colorForSource(_ source: String) -> Color {
        switch source {
        case "omakase": return .yellow
        case "omakase_draft": return .mint
        case "ask": return .cyan
        case "draft_pr": return .green
        default: return .white.opacity(0.5)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Notification List View

struct NotificationListView: View {
    @ObservedObject var model: PetModel

    var body: some View {
        if model.notificationHistory.isEmpty {
            VStack {
                Spacer()
                Text("No notifications yet")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.notificationHistory.reversed()) { entry in
                        NotificationEntryView(entry: entry)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

struct NotificationEntryView: View {
    let entry: NotificationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: iconForSource(entry.source))
                    .font(.system(size: 10))
                    .foregroundColor(colorForSource(entry.source))
                Text(entry.source.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(colorForSource(entry.source))
                Spacer()
                Text(timeString(entry.timestamp))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            Text(entry.text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(6)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func iconForSource(_ source: String) -> String {
        switch source {
        case "omakase": return "sparkles"
        case "omakase_draft": return "pencil.and.outline"
        case "ask": return "questionmark.circle"
        case "draft_pr": return "doc.text"
        case "proactive": return "bell"
        case "gateway": return "message"
        case "bridge": return "network"
        default: return "circle"
        }
    }

    private func colorForSource(_ source: String) -> Color {
        switch source {
        case "omakase": return .yellow
        case "omakase_draft": return .mint
        case "ask": return .cyan
        case "draft_pr": return .green
        case "proactive": return .orange
        default: return .white.opacity(0.5)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
