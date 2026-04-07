import SwiftUI

// MARK: - Layer 2: Notification Bubble (auto-fade, click to open chat)

/// Brief notification bubble showing the latest assistant message
struct PetNotificationBubble: View {
    @ObservedObject var model: PetModel
    @State private var isVisible = true
    @State private var isHovered = false
    @State private var fadeTask: Task<Void, Never>?

    var body: some View {
        if isVisible, let lastMsg = model.messages.last, lastMsg.role == .assistant {
            VStack(alignment: .leading, spacing: 2) {
                Text(lastMsg.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.8))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
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
                model.stateMachine.handle(.userDoubleClicked)
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
                    model.stateMachine.handle(.bubbleDismissed)
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
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: model.streamingText) { _ in
                    scrollToBottom(proxy: proxy)
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
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(16)

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
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 0.95)))
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
                        RoundedRectangle(cornerRadius: 12)
                            .fill(message.role == .user
                                  ? Color.blue.opacity(0.55)
                                  : Color.white.opacity(0.15))
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
