import SwiftUI

struct AvatarSettingsView: View {
    @ObservedObject var petModel: PetModel

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.sectionSpacing) {
            // Avatar section
            PanelSectionHeader(title: "Avatar")

            VStack(alignment: .leading, spacing: 8) {
                toggleRow("Enabled", isOn: $petModel.isVisible)

                toggleRow("Follow Active Window", isOn: $petModel.isTrackingEnabled)

                sliderRow("Size", value: Binding(get: { Double(petModel.characterSize) }, set: { petModel.characterSize = CGFloat($0) }), range: 32...128, format: "%.0f pt")
                sliderRow("Opacity", value: $petModel.opacity, range: 0.25...1.0, format: "%.0f%%", multiplier: 100)
            }
            .padding(PanelTheme.cardPadding)
            .background(PanelTheme.backgroundCard)
            .cornerRadius(PanelTheme.cornerRadius)

            // Notifications section
            PanelSectionHeader(title: "Notifications")

            VStack(alignment: .leading, spacing: 8) {
                toggleRow("Notifications", isOn: $petModel.isBubbleEnabled)
            }
            .padding(PanelTheme.cardPadding)
            .background(PanelTheme.backgroundCard)
            .cornerRadius(PanelTheme.cornerRadius)

            // Connection section
            PanelSectionHeader(title: "Connection")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gateway")
                        .font(PanelTheme.bodyFont)
                        .foregroundStyle(PanelTheme.textPrimary)
                    Spacer()
                    connectionBadge
                }

                if case .error(let msg) = petModel.connectionState {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(PanelTheme.textSecondary)
                        .lineLimit(1)
                }

                Button(action: {
                    petModel.disconnect()
                    petModel.connect()
                }) {
                    Text("Reconnect")
                        .font(PanelTheme.bodyFont)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(petModel.connectionState == .connecting)
            }
            .padding(PanelTheme.cardPadding)
            .background(PanelTheme.backgroundCard)
            .cornerRadius(PanelTheme.cornerRadius)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Components

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, multiplier: Double = 1) -> some View {
        HStack {
            Text(title)
                .font(PanelTheme.bodyFont)
                .foregroundStyle(PanelTheme.textPrimary)
            Slider(value: value, in: range)
                .frame(width: 100)
            Text(String(format: format, value.wrappedValue * multiplier))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(PanelTheme.textSecondary)
                .frame(width: 45, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch petModel.connectionState {
        case .connected:
            PanelPill(text: "Connected", tint: PanelTheme.accentGreen)
        case .connecting:
            PanelPill(text: "Connecting...", tint: PanelTheme.accentCyan)
        case .disconnected:
            PanelPill(text: "Disconnected", tint: PanelTheme.textSecondary)
        case .error:
            PanelPill(text: "Error", tint: .red)
        }
    }
}
