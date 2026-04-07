import SwiftUI

/// Chat bubble overlay for pet character
struct PetBubbleView: View {
    @ObservedObject var model: PetModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Messages (show last 5)
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
