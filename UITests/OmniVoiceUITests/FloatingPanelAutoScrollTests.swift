import XCTest

/// Priority item 2 — `TranscriptListView`'s pin-to-bottom state machine
/// (`isPinnedToBottom`, `isProgrammaticScrollInFlight`, the "最新内容" jump
/// button) in `FloatingTranscriptView.swift`.
///
/// SCOPED DOWN — see this task's final report for the full reasoning. In
/// summary: exercising the actual auto-scroll/scroll-away/jump-button
/// behavior needs enough transcript content to make the list scrollable,
/// which only ever arrives through a real running ASR session
/// (`RecordingSession.start()` seeding `lines` requires a live engine);
/// there is no test-only seam to inject synthetic transcript lines from
/// outside the process, and adding one would be a production-code change
/// outside a UI-test task's remit. Driving a real session needs microphone
/// TCC permission this harness cannot grant non-interactively (see
/// `SettingsDisabledStateTests`'s doc for the same constraint).
///
/// What IS reachable without any of that: the list's own baseline state
/// with no content — pinned by default, and the jump button correctly
/// absent (nothing to jump to, and nothing to have scrolled away from).
final class FloatingPanelAutoScrollTests: XCTestCase {
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

    /// With no recording ever started, `lines` is empty and
    /// `isPinnedToBottom` defaults to `true` — the placeholder "等待开始…" is
    /// showing, and the "最新内容" jump button (only shown once
    /// `!isPinnedToBottom`) must not exist.
    func testEmptyTranscriptShowsPlaceholderAndNoJumpButton() {
        let placeholder = app.staticTexts["等待开始…"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["最新内容"].exists, "jump-to-latest button must not appear while already pinned to the bottom")
    }
}
