import XCTest

// One test, one assertion: the app launches and actually shows its screen.
// Run once per environment (`make uitest`) before a paid sweep — the sweep's
// per-sim verification uses screenshots, which are much cheaper at high N.
final class SmokeUITest: XCTestCase {
    func testAppLaunchesAndRenders() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["SIM DENSITY"].waitForExistence(timeout: 15),
            "app launched but the main screen never appeared"
        )
    }
}
