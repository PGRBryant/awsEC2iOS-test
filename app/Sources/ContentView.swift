import SwiftUI
import UIKit
import Vision

// Load profiles make density measurable under realistic app behavior, not just
// an idle screen. Selected via SD_PROFILE (sweep.sh forwards it through
// SIMCTL_CHILD_SD_PROFILE):
//   IDLE    — static screen; measures the platform floor
//   ANIMATE — continuous animation + timer work; keeps CPU/GPU busy
//   SCROLL  — auto-scrolling image-like list; churns memory + rendering
//   INFER   — edge-AI loop: real on-device neural inference (Vision OCR on
//             generated images; models ship with the OS, nothing bundled).
//             Reports inferences/sec on screen and to Documents/metrics.json,
//             which the host reads via `simctl get_app_container`.
enum LoadProfile: String {
    case idle = "IDLE", animate = "ANIMATE", scroll = "SCROLL", infer = "INFER"

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
            case .infer: InferPane()
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

// Edge-AI load: continuous on-device neural inference using Vision's OCR
// model (ships with the OS — no bundled assets, no downloads). Each pass
// draws a fresh image with random text and runs VNRecognizeTextRequest on
// it. The running inferences/sec rate is shown on screen and appended to
// Documents/metrics.json for the harness to collect.
struct InferPane: View {
    @State private var rate = 0.0
    @State private var total = 0

    var body: some View {
        VStack {
            Spacer()
            Text(String(format: "%.2f inf/s · %d total", rate, total))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .accessibilityIdentifier("sd-infer-rate")
                .padding(.bottom, 60)
        }
        .task {
            await inferLoop()
        }
    }

    private func inferLoop() async {
        let start = Date()
        var count = 0
        while !Task.isCancelled {
            let img = Self.makeImage(seed: count)
            if Self.recognizeText(in: img) { count += 1 }
            if count % 5 == 0 {
                let elapsed = Date().timeIntervalSince(start)
                let r = elapsed > 0 ? Double(count) / elapsed : 0
                await MainActor.run { rate = r; total = count }
                Self.writeMetrics(rate: r, total: count)
            }
            await Task.yield()
        }
    }

    private static func makeImage(seed: Int) -> UIImage {
        let words = ["DENSITY", "SIMULATOR", "EDGE", "INFERENCE", "CLOUD",
                     "METAL", "VISION", "KERNEL"]
        let size = CGSize(width: 480, height: 240)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.96, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(words[seed % words.count]) \(seed)"
            (text as NSString).draw(
                at: CGPoint(x: 24, y: 90),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 42, weight: .bold),
                    .foregroundColor: UIColor.black,
                ])
        }
    }

    private static func recognizeText(in image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let handler = VNImageRequestHandler(cgImage: cg)
        do {
            try handler.perform([request])
            return !(request.results ?? []).isEmpty
        } catch {
            return false
        }
    }

    private static func writeMetrics(rate: Double, total: Int) {
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return }
        let payload = #"{"ops_per_sec": \#(String(format: "%.3f", rate)), "total": \#(total)}"#
        try? payload.write(to: dir.appendingPathComponent("metrics.json"),
                           atomically: true, encoding: .utf8)
    }
}

#Preview {
    ContentView()
}
