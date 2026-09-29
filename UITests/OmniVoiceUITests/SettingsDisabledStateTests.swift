import XCTest

/// Priority item 3 — `SettingsView`'s engine/model pickers and memory
/// console buttons, disabled/enabled as a function of `isSessionActive` /
/// `isPreloadingModel` / `isModelLoaded` / `isBusy` (`isSessionActive ||
/// isPreloadingModel`).
///
/// SCOPED DOWN — see this task's final report for the full reasoning. In
/// summary: `isSessionActive` requires an actually-running recording, which
/// needs microphone TCC permission this harness cannot grant non-
/// interactively (no way to click the system consent dialog's "Allow" from
/// an unhosted UI test without that permission already existing); driving
/// `isPreloadingModel == true` or `isModelLoaded == true` for real needs a
/// downloaded R2T2/T3PO model (multi-GB, out of scope for a UI-test run).
/// `preloadModel()`'s fallback-to-system path (see
/// `RecordingSessionSettingsTests` in `OmniVoiceCoreTests`) resolves near-
/// instantly with nothing downloaded, so `isPreloadingModel` can't reliably
/// be caught `true` from outside the process either.
///
/// What IS deterministically reachable, and covered below: the idle-state
/// baseline (`isBusy == false`) for the engine `Picker` and, once an
/// on-device engine is selected, the memory console's `isModelLoaded ==
/// false` half of its own disabled matrix (preload enabled, release
/// disabled).
final class SettingsDisabledStateTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = OmniVoiceUITestApp.launchFreshOnboarding()
        let skipButton = app.buttons["跳过向导"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 10))
        skipButton.click()
        app.activate()
        app.typeKey(",", modifierFlags: .command)
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        app.terminate()
    }

    /// At rest (`isBusy == false`), the ASR/translation engine pickers must
    /// be enabled — a regression here (an always-`.disabled` picker, say)
    /// would permanently lock the user out of switching engines.
    func testEnginePickersAreEnabledWhenIdle() {
        let enginePickers = app.popUpButtons.matching(identifier: "引擎")
        XCTAssertTrue(enginePickers.firstMatch.waitForExistence(timeout: 10))
        for index in 0..<enginePickers.count {
            XCTAssertTrue(enginePickers.element(boundBy: index).isEnabled, "engine picker \(index) should be enabled while idle")
        }
    }

    /// Once an on-device engine is selected but nothing is downloaded/loaded
    /// yet (`isModelLoaded == false`, `isBusy == false`): "⚡ 预加载到显存" must
    /// be enabled (there's something to preload) and "🧹 释放显存占用" must be
    /// disabled (`!isModelLoaded` — nothing loaded yet to release).
    func testMemoryConsolePreloadEnabledReleaseDisabledWhenNothingIsLoaded() {
        let enginePicker = app.popUpButtons["引擎"].firstMatch
        XCTAssertTrue(enginePicker.waitForExistence(timeout: 10))
        enginePicker.click()
        app.menuItems["R2T2 离线大模型（未下载 · 点击配置）"].click()

        let preloadButton = app.buttons["⚡ 预加载到显存"]
        let releaseButton = app.buttons["🧹 释放显存占用"]
        XCTAssertTrue(preloadButton.waitForExistence(timeout: 5))
        XCTAssertTrue(releaseButton.waitForExistence(timeout: 5))
        XCTAssertTrue(preloadButton.isEnabled, "preload should be enabled — nothing loaded yet, and nothing else busy")
        XCTAssertFalse(releaseButton.isEnabled, "release should stay disabled until something is actually loaded")
    }
}
