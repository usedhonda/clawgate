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

final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
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
        // Screenshot offer bubble
        if isVisible, let offer = model.pendingScreenshotOffer {
            screenshotOfferView(offer)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering { fadeTask?.cancel() }
                    else { startFadeTimer(duration: 15_000_000_000) }
                }
                .onAppear { startFadeTimer(duration: 15_000_000_000) }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        // Clipboard offer bubble (action buttons)
        else if isVisible, let offer = model.pendingClipboardOffer {
            clipboardOfferView(offer)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering { fadeTask?.cancel() }
                    else { startFadeTimer(duration: 8_000_000_000) }
                }
                .onAppear { startFadeTimer(duration: 8_000_000_000) }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        // Regular notification bubble
        else if isVisible, let lastMsg = model.notificationMessage {
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
                if hovering { fadeTask?.cancel() }
                else { startFadeTimer(for: lastMsg.text) }
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

    @ViewBuilder
    private func screenshotOfferView(_ offer: ScreenshotOffer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("SCREENSHOT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
                if let app = offer.sourceApp {
                    Text("from \(app)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Button(action: { dismissScreenshotOffer() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

            Text("Use \(offer.mentionText)?")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)

            Text(offer.tempPath)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)

            HStack(spacing: 8) {
                screenshotActionButton("Copy Mention") {
                    model.executeScreenshotAction(.copyMention)
                    dismissScreenshotOffer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(PetColors.notificationBubble)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        )
    }

    @ViewBuilder
    private func clipboardOfferView(_ offer: ClipboardOffer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: content type + source app
            HStack(spacing: 6) {
                Image(systemName: iconForContentType(offer.contentType))
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(offer.contentType.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
                if let app = offer.sourceApp {
                    Text("from \(app)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                // Dismiss button
                Button(action: { dismissOffer() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

            // Preview of copied text
            Text(offer.text.prefix(80) + (offer.text.count > 80 ? "..." : ""))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(2)

            // Action buttons
            HStack(spacing: 8) {
                ForEach(Array(offer.actions.prefix(3).enumerated()), id: \.offset) { _, action in
                    Button(action: {
                        model.executeClipboardAction(action)
                        dismissOffer()
                    }) {
                        Text(action.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(PetColors.notificationBubble)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        )
    }

    @ViewBuilder
    private func screenshotActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
    }

    private func dismissOffer() {
        model.pendingClipboardOffer = nil
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isVisible = true  // reset for next notification
        }
    }

    private func dismissScreenshotOffer() {
        model.dismissScreenshotOffer()
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isVisible = true
        }
    }

    private func iconForContentType(_ type: ClipboardContentType) -> String {
        switch type {
        case .json: return "curlybraces"
        case .url: return "link"
        case .error: return "exclamationmark.triangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .english, .japanese: return "textformat"
        case .longText: return "doc.text"
        case .base64: return "lock.open"
        case .jwt: return "key"
        case .terminalOutput: return "terminal"
        }
    }

    private func startFadeTimer(for text: String) {
        let duration: UInt64 = text.count > 100 ? 12_000_000_000 : 6_000_000_000
        startFadeTimer(duration: duration)
    }

    private func startFadeTimer(duration: UInt64) {
        fadeTask?.cancel()
        fadeTask = Task {
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.5)) {
                    isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    model.dismissNotification()
                    model.pendingClipboardOffer = nil
                    model.dismissScreenshotOffer()
                    isVisible = true
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

                Spacer(minLength: 12)
                    .background(DragHandle())
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .padding(.horizontal, 6)
            .background(PetColors.tabBarBg)

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
            .padding(.horizontal, 12)
            .padding(.top, 6)
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
                        ForEach(model.summonResults.reversed()) { entry in
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
