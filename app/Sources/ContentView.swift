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
//   HOTDOG  — the "Not Hotdog" protocol: on-device image *classification*
//             with known ground truth. Renders a hotdog or decoy subject,
//             asks Vision's built-in ~1,300-label classifier what it sees,
//             and scores the binary verdict — so accuracy under load is
//             measured, not assumed. ops_per_sec counts only CORRECT verdicts.
enum LoadProfile: String {
    case idle = "IDLE", animate = "ANIMATE", scroll = "SCROLL", infer = "INFER",
         hotdog = "HOTDOG"

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
            case .hotdog: HotdogPane()
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

// The "Not Hotdog" protocol. Each iteration: draw a subject (hotdog emoji or
// a decoy — half of them adversarial foods), run Vision's built-in image
// classifier, and score the binary hotdog/not-hotdog verdict against the
// known ground truth. Two things OCR can't give us: a second, heavier model
// class, and per-iteration CORRECTNESS — the accuracy-under-load curve.
struct HotdogPane: View {
    @State private var rate = 0.0
    @State private var accuracy = 0.0
    @State private var subject = "🌭"
    @State private var verdict = "…"

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(subject).font(.system(size: 96))
            Text(verdict)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .accessibilityIdentifier("sd-hotdog-verdict")
            Text(String(format: "%.2f correct/s · acc %.0f%%", rate, accuracy * 100))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityIdentifier("sd-infer-rate")
                .padding(.bottom, 50)
        }
        .task { await classifyLoop() }
    }

    private func classifyLoop() async {
        // deterministic 50/50 hotdog/decoy split; decoys mix adversarial
        // foods (pizza, burger, taco) with easy negatives (car, cat, ball)
        let decoys = ["🍕", "🍔", "🌮", "🚗", "🐱", "⚽️"]
        let start = Date()
        var attempts = 0
        var correct = 0
        var lastLabels = ""
        while !Task.isCancelled {
            let isHotdog = attempts % 2 == 0
            let subj = isHotdog ? "🌭" : decoys[(attempts / 2) % decoys.count]
            let (says, labels) = Self.classify(Self.emojiImage(subj))
            attempts += 1
            if says == isHotdog { correct += 1 }
            // keep the classifier's actual words for the hotdog case — the
            // diagnostic that separates "label mismatch" from "clip-art gap"
            if isHotdog { lastLabels = labels }
            if attempts % 5 == 0 {
                let elapsed = Date().timeIntervalSince(start)
                let r = elapsed > 0 ? Double(correct) / elapsed : 0
                let acc = Double(correct) / Double(attempts)
                await MainActor.run {
                    rate = r; accuracy = acc; subject = subj
                    verdict = says ? "HOTDOG ✅" : "NOT HOTDOG ❌"
                }
                Self.writeMetrics(rate: r, correct: correct, attempts: attempts,
                                  labels: lastLabels)
            }
            await Task.yield()
        }
    }

    private static func emojiImage(_ emoji: String) -> UIImage {
        // Apple Color Emoji is a bitmap font: huge point sizes can silently
        // draw NOTHING (validated the hard way — a blank canvas classifies as
        // "night_sky/moon"). 150pt renders reliably; draw centered.
        let size = CGSize(width: 480, height: 480)
        let font = UIFont.systemFont(ofSize: 150)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let s = (emoji as NSString)
            let m = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (size.width - m.width) / 2,
                               y: (size.height - m.height) / 2),
                   withAttributes: attrs)
        }
    }

    // Returns the verdict plus the top labels the classifier actually said —
    // "hotdog-ish" accepts the taxonomy's synonyms (hot dog / frankfurter /
    // sausage family) so a naming mismatch can't masquerade as a model miss.
    private static func classify(_ image: UIImage) -> (Bool, String) {
        guard let cg = image.cgImage else { return (false, "") }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        guard (try? handler.perform([request])) != nil else { return (false, "") }
        let top = Array((request.results ?? []).prefix(8))
        let labels = top.map {
            "\($0.identifier):\(String(format: "%.2f", $0.confidence))"
        }.joined(separator: ",")
        let says = top.contains { obs in
            let id = obs.identifier.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            return (id.contains("hotdog") || id.contains("frankfurter")
                    || id.contains("sausage") || id.contains("chilidog"))
                && obs.confidence > 0.05
        }
        return (says, labels)
    }

    private static func writeMetrics(rate: Double, correct: Int, attempts: Int,
                                     labels: String) {
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return }
        let acc = attempts > 0 ? Double(correct) / Double(attempts) : 0
        let safe = labels.replacingOccurrences(of: "\"", with: "")
        let payload = #"{"ops_per_sec": \#(String(format: "%.3f", rate)), "total": \#(correct), "attempts": \#(attempts), "accuracy": \#(String(format: "%.3f", acc)), "hotdog_labels": "\#(safe)"}"#
        try? payload.write(to: dir.appendingPathComponent("metrics.json"),
                           atomically: true, encoding: .utf8)
    }
}

#Preview {
    ContentView()
}
