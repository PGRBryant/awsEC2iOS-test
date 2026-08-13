import XCTest

// A deliberately even, small suite for the sharding experiment: 12 tests that
// each launch the app under a load profile and assert it genuinely rendered.
// harness/shard.sh splits these across N parallel simulators and measures
// suite wall-time vs N — the speedup curve is the number a phone team buys
// cloud simulators for. Test ids are listed in app/UITests/tests.txt; keep
// that manifest in sync when adding tests here.
final class ShardedUITests: XCTestCase {

    private func launchAndVerify(profile: String) {
        let app = XCUIApplication()
        app.launchEnvironment["SD_PROFILE"] = profile
        app.launch()
        XCTAssertTrue(app.staticTexts["SIM DENSITY"].waitForExistence(timeout: 20),
                      "app did not render under profile \(profile)")
        XCTAssertEqual(app.staticTexts["sd-profile"].label, profile)
        // hold briefly so the test represents real interaction time, not a blink
        Thread.sleep(forTimeInterval: 2)
    }

    func test01_idleLaunch()     { launchAndVerify(profile: "IDLE") }
    func test02_idleRelaunch()   { launchAndVerify(profile: "IDLE") }
    func test03_animateLaunch()  { launchAndVerify(profile: "ANIMATE") }
    func test04_animateSteady()  { launchAndVerify(profile: "ANIMATE") }
    func test05_scrollLaunch()   { launchAndVerify(profile: "SCROLL") }
    func test06_scrollSteady()   { launchAndVerify(profile: "SCROLL") }
    func test07_idleAgain()      { launchAndVerify(profile: "IDLE") }
    func test08_animateAgain()   { launchAndVerify(profile: "ANIMATE") }
    func test09_scrollAgain()    { launchAndVerify(profile: "SCROLL") }
    func test10_idleFinal()      { launchAndVerify(profile: "IDLE") }
    func test11_animateFinal()   { launchAndVerify(profile: "ANIMATE") }
    func test12_scrollFinal()    { launchAndVerify(profile: "SCROLL") }
}
