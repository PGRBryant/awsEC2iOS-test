import SwiftUI

struct ContentView: View {
    // A big, saturated, full-bleed fill makes "did it actually render?"
    // answerable from a screenshot's byte size and color, even at small scale.
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.56, blue: 0.53) // gauge teal
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text("SIM DENSITY")
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .foregroundStyle(.white)
                Text("booted \u{2713}")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(ProcessInfo.processInfo.hostName)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityIdentifier("sd-root")
        }
    }
}

#Preview {
    ContentView()
}
