import XCTest

/// Priority item 5 — the model preload/unload control appears independently
/// in two places (`SettingsView.memoryConsole` and
/// `FloatingTranscriptView.modelStatusControl`), both driven off the exact
/// same `RecordingSession` instance (`usesOnDeviceModelEngine`/
/// `isModelLoaded`/`isPreloadingModel`). Neither view owns its own copy of
/// that state, so this asserts they never desync: whatever one shows, the
/// other must show at the same time.
///
/// Scoped to what's reachable without a real (multi-GB) model download:
/// selecting an undownloaded `.model`-kind engine already flips
/// `usesOnDeviceModelEngine` to `true` (that's a static catalog property,
/// independent of download state — see `EngineDescriptor.kind`), which is
/// enough to make both consoles appear/disappear together. Actually loading
/// real R2T2/T3PO weights (to exercise `isModelLoaded == true` on both
/// surfaces) is out of scope here — see this task's final report for why.
final class CrossSurfaceModelStateSyncTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = OmniVoiceUITestApp.launchFreshOnboarding()
        let skipButton = app.buttons["跳过向导"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 10))
        skipButton.click()
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        app.terminate()
    }

    private func openSettings() {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
    }

    /// Selecting an on-device ASR engine (R2T2, undownloaded on a fresh
    /// install) must surface the preload affordance on BOTH surfaces at
    /// once — Settings' "语音与引擎" memory console section and the floating
    /// panel's status-bar control — never just one of them.
    func testSelectingAnOnDeviceEngineShowsThePreloadControlOnBothSurfaces() {
        openSettings()

        let enginePicker = app.popUpButtons["引擎"].firstMatch
        XCTAssertTrue(enginePicker.waitForExistence(timeout: 10))
        enginePicker.click()
        let r2t2MenuItem = app.menuItems["R2T2 离线大模型（未下载 · 点击配置）"]
        XCTAssertTrue(r2t2MenuItem.waitForExistence(timeout: 5))
        r2t2MenuItem.click()

        // Settings' own console.
        let settingsPreloadButton = app.buttons["⚡ 预加载到内存"]
        XCTAssertTrue(settingsPreloadButton.waitForExistence(timeout: 5), "Settings memory console should appear once an on-device engine is selected")

        // The floating panel's equivalent, found in the *other* window.
        let panelPreloadButton = app.buttons["预加载模型"]
        XCTAssertTrue(panelPreloadButton.waitForExistence(timeout: 5), "floating panel status control should show the preload affordance in sync with Settings")
    }

    /// `preloadModel()` silently falls back to the system engine when the
    /// selected variant isn't downloaded (see
    /// `RecordingSessionSettingsTests.preloadModelFallsBackToSystemEngineWhenTheSelectedVariantIsntDownloaded`
    /// in `OmniVoiceCoreTests`) — `usesOnDeviceModelEngine` then flips back
    /// to `false`. Both surfaces must lose the preload control together;
    /// neither should be left showing a stale "on-device engine selected"
    /// affordance after the other has already updated.
    func testFallbackToSystemEngineHidesThePreloadControlOnBothSurfacesTogether() {
        openSettings()

        let enginePicker = app.popUpButtons["引擎"].firstMatch
        XCTAssertTrue(enginePicker.waitForExistence(timeout: 10))
        enginePicker.click()
        app.menuItems["R2T2 离线大模型（未下载 · 点击配置）"].click()

        let settingsPreloadButton = app.buttons["⚡ 预加载到内存"]
        let panelPreloadButton = app.buttons["预加载模型"]
        XCTAssertTrue(settingsPreloadButton.waitForExistence(timeout: 5))
        XCTAssertTrue(panelPreloadButton.waitForExistence(timeout: 5))

        settingsPreloadButton.click()

        let settingsGone = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: settingsPreloadButton)],
            timeout: 10
        )
        let panelGone = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: panelPreloadButton)],
            timeout: 10
        )
        XCTAssertEqual(settingsGone, .completed, "Settings memory console should disappear after the fallback-to-system engine switch")
        XCTAssertEqual(panelGone, .completed, "floating panel status control should disappear in the same run loop turn as Settings, not lag behind")
    }
}
