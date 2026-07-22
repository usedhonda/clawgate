import SwiftUI

/// Broadcast-mode HUD: a compact, content-free status capsule shown in place of
/// the message bubble/whisper while streaming. It shows only connection health
/// (a colored dot + optional latency) and the ambient audio level — never any
/// message text, sender, or body.
struct PetStreamHUDView: View {
    @ObservedObject var model: PetModel

    private var healthColor: Color {
        switch model.connectionState {
        case .connected: return Color.green
        case .connecting: return Color.yellow
        case .disconnected, .error: return Color.red
        }
    }

    /// Ambient RMS is small; scale it into a readable 0…1 bar fill.
    private var meterFill: CGFloat {
        CGFloat(min(1, max(0, model.ambientLevel * 12)))
    }

    private var meterActive: Bool { model.ambientLevel > 0 }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)

            if let ms = model.healthLatencyMs {
                Text("\(ms)ms")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(meterActive
                              ? Color(nsColor: NSColor.systemTeal)
                              : Color.white.opacity(0.25))
                        .frame(width: max(2, geo.size.width * meterFill))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 180)
        .background(
            Capsule()
                .fill(Color(nsColor: NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 0.9)))
        )
    }
}
