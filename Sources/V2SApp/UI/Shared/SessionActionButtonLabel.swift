import SwiftUI

struct SessionActionButtonLabel: View {
    let title: String
    let showsActivity: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                SessionWaitIndicatorGlyph()
                Text("Start")
            }
            .hidden()

            HStack(spacing: 6) {
                if showsActivity {
                    SessionWaitIndicator()
                }

                Text(title)
            }
        }
    }
}

private struct SessionWaitIndicatorGlyph: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .accessibilityHidden(true)
    }
}

private struct SessionWaitIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        SessionWaitIndicatorGlyph()
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
            .onDisappear {
                isAnimating = false
            }
            .accessibilityHidden(true)
    }
}
