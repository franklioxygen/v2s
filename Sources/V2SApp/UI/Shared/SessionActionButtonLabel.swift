import SwiftUI

struct SessionActionButtonLabel: View {
    let title: String
    let showsActivity: Bool

    var body: some View {
        HStack(spacing: 6) {
            if showsActivity {
                SessionWaitIndicator()
                    .transition(.identity)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
            Text(title)
        }
    }
}

private struct SessionWaitIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .accessibilityHidden(true)
    }
}
