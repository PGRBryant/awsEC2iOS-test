import SwiftUI

// Deliberately trivial. The experiment measures the *platform's* simulator
// ceiling, not this app — so it must launch fast and render a distinctive,
// easy-to-verify screen.
@main
struct SimDensityApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
