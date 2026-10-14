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

    /// Clicks a Settings tab pill and waits for its `.isSelected` trait —
    /// the engine pickers and memory console live on "语音识别", the 快捷翻译
    /// engine on "快捷翻译".
    private func selectSettingsTab(_ title: String) {
        let tab = app.buttons[title].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Settings tab \(title) should exist")
        tab.click()
        let selected = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tab)],
            timeout: 5
        )
        XCTAssertEqual(selected, .completed, "Settings tab \(title) should become selected")
    }

    /// At rest (`isBusy == false`), the ASR/translation engine pickers must
    /// be enabled — a regression here (an always-`.disabled` picker, say)
    /// would permanently lock the user out of switching engines.
    func testEnginePickersAreEnabledWhenIdle() {
        // `matching(identifier:)` matches only `accessibilityIdentifier`,
        // which these SwiftUI `Picker`s never set (only their label) — use
        // a label predicate instead, the same way the single-element
        // subscript `app.popUpButtons["识别引擎"]` below (and in
        // `CrossSurfaceModelStateSyncTests`) already matches by label, just
        // as a proper multi-element query. The ASR and transcription
        // translation engines live on "语音识别", the 快捷翻译 engine on its
        // own "快捷翻译" tab, so each tab is asserted separately.
        selectSettingsTab("语音识别")
        let recognitionPickers = app.popUpButtons.matching(NSPredicate(format: "label ENDSWITH %@", "引擎"))
        XCTAssertTrue(recognitionPickers.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(recognitionPickers.count, 2, "语音识别 holds the ASR and transcription-translation engine pickers")
        for index in 0..<recognitionPickers.count {
            XCTAssertTrue(recognitionPickers.element(boundBy: index).isEnabled, "recognition engine picker \(index) should be enabled while idle")
        }

        selectSettingsTab("快捷翻译")
        let quickPickers = app.popUpButtons.matching(NSPredicate(format: "label ENDSWITH %@", "引擎"))
        XCTAssertTrue(quickPickers.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(quickPickers.count, 1, "快捷翻译 holds exactly the quick-translation engine picker")
        XCTAssertTrue(quickPickers.firstMatch.isEnabled, "quick-translation engine picker should be enabled while idle")
    }

    /// Once an on-device engine is selected but nothing is downloaded/loaded
    /// yet (`isModelLoaded == false`, `isBusy == false`): "⚡ 预加载到内存" must
    /// be enabled (there's something to preload) and "🧹 释放内存占用" must be
    /// disabled (`!isModelLoaded` — nothing loaded yet to release).
    func testMemoryConsolePreloadEnabledReleaseDisabledWhenNothingIsLoaded() {
        selectSettingsTab("语音识别")
        let enginePicker = app.popUpButtons["识别引擎"].firstMatch
        XCTAssertTrue(enginePicker.waitForExistence(timeout: 10))
        enginePicker.click()
        app.menuItems["R2T2 离线大模型（未下载 · 点击配置）"].click()

        let preloadButton = app.buttons["⚡ 预加载到内存"]
        let releaseButton = app.buttons["🧹 释放内存占用"]
        XCTAssertTrue(preloadButton.waitForExistence(timeout: 5))
        XCTAssertTrue(releaseButton.waitForExistence(timeout: 5))
        XCTAssertTrue(preloadButton.isEnabled, "preload should be enabled — nothing loaded yet, and nothing else busy")
        XCTAssertFalse(releaseButton.isEnabled, "release should stay disabled until something is actually loaded")
    }
}
