import SwiftUI

/// Layer 1: Small whisper bubble for brief reactions ("了解っ", "ん？", etc.)
struct PetWhisperView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.75))
            )
            .transition(.asymmetric(
                insertion: .scale(scale: 0.5).combined(with: .opacity),
                removal: .opacity.combined(with: .move(edge: .top))
            ))
    }
}
