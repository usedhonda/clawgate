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
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: 220)
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
        VStack(alignment: .leading, spacing: 6) {
            // Messages (scrollable)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.messages.suffix(20)) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
                .frame(maxHeight: 200)
                .onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input field
            HStack(spacing: 4) {
                TextField("...", text: $model.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isInputFocused)
                    .onSubmit { model.send() }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)

                Button(action: { model.send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(model.inputText.isEmpty ? .gray : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(model.inputText.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .onAppear { isInputFocused = true }
    }
}

/// Individual message bubble
struct MessageBubble: View {
    let message: OpenClawChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            Text(message.text)
                .font(.system(size: 11))
                .foregroundColor(message.role == .user ? .white : .white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(message.role == .user
                              ? Color.blue.opacity(0.6)
                              : Color.white.opacity(0.1))
                )

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
