import SwiftUI

/// The pet's Minutes tab. Minutes live in their own window now; this tab only
/// opens it, so there is one place to read, retry and create meetings.
struct MinutesOpenWindowView: View {
    @ObservedObject var model: PetModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("議事録は専用のウィンドウで開きます")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            Button("議事録ウィンドウを開く") { model.onOpenMinutesWindow?() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}
