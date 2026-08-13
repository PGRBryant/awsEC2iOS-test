import SwiftUI

// Load profiles make density measurable under realistic app behavior, not just
// an idle screen. Selected via SD_PROFILE (sweep.sh forwards it through
// SIMCTL_CHILD_SD_PROFILE):
//   IDLE    — static screen; measures the platform floor
//   ANIMATE — continuous animation + timer work; keeps CPU/GPU busy
//   SCROLL  — auto-scrolling image-like list; churns memory + rendering
enum LoadProfile: String {
    case idle = "IDLE", animate = "ANIMATE", scroll = "SCROLL"

    static var current: LoadProfile {
        LoadProfile(rawValue: ProcessInfo.processInfo
            .environment["SD_PROFILE"] ?? "IDLE") ?? .idle
    }
}

struct ContentView: View {
    let profile = LoadProfile.current

    // A big, saturated, full-bleed fill makes "did it actually render?"
    // answerable from a screenshot's byte size, even at small scale.
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.56, blue: 0.53) // gauge teal
                .ignoresSafeArea()
            switch profile {
            case .idle: EmptyView()
            case .animate: AnimatePane()
            case .scroll: ScrollPane()
            }
            VStack(spacing: 12) {
                Text("SIM DENSITY")
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .foregroundStyle(.white)
                Text("booted \u{2713}")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(profile.rawValue)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("sd-profile")
            }
            .accessibilityIdentifier("sd-root")
        }
    }
}

// Continuous rotation/scale animation plus a timer doing real CPU work each
// tick — the "app with animations and background activity" shape.
struct AnimatePane: View {
    @State private var spin = false
    @State private var churn: [Int] = []

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.25), lineWidth: 3)
                    .frame(width: CGFloat(80 + i * 40), height: CGFloat(80 + i * 40))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: Double(4 + i))
                        .repeatForever(autoreverses: false), value: spin)
            }
        }
        .onAppear { spin = true }
        .onReceive(tick) { _ in
            // bounded busywork: hash churn that the optimizer can't drop
            var h = Hasher()
            for n in 0..<20_000 { h.combine(n &* churn.count) }
            churn.append(h.finalize())
            if churn.count > 256 { churn.removeFirst(128) }
        }
    }
}

// Auto-scrolling list of gradient rows — steady rendering + memory churn
// without bundling any assets.
struct ScrollPane: View {
    @State private var target = 0

    private let tick = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()
    private let rowCount = 400

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<rowCount, id: \.self) { i in
                        LinearGradient(
                            colors: [Color(hue: Double(i % 32) / 32.0,
                                           saturation: 0.55, brightness: 0.75),
                                     Color(hue: Double((i + 9) % 32) / 32.0,
                                           saturation: 0.65, brightness: 0.5)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                            .frame(height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(Text("row \(i)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7)))
                            .id(i)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onReceive(tick) { _ in
                target = (target + 6) % rowCount
                withAnimation(.easeInOut(duration: 0.6)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }
        .opacity(0.45) // keep the title readable above it
    }
}

#Preview {
    ContentView()
}
