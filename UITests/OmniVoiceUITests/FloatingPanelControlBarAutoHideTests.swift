import XCTest

/// Priority item 4 — `FloatingTranscriptView.isControlsVisible`/`autoHideTask`
/// (2s mouse-leave delay, see that file's doc) and the drag-vs-control-click
/// hit test (`DraggableHostingView.mouseDown` in
/// `FloatingTranscriptPanel.swift` only fires `performDrag` for a click no
/// SwiftUI control consumed first).
///
/// No microphone/model-download permissions needed — the floating panel is
/// shown unconditionally from `applicationDidFinishLaunching`, and this
/// entire state machine only depends on hover, never on session/recording
/// state.
final class FloatingPanelControlBarAutoHideTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = OmniVoiceUITestApp.launchFreshOnboarding()
        // Fresh install → the onboarding window is on top; dismiss it via
        // "跳过向导" so the floating panel underneath is the frontmost/only
        // window left to interact with.
        let skipButton = app.buttons["跳过向导"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 5))
        skipButton.click()
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        app.terminate()
    }

    /// A coordinate far outside the 420×280 panel (which
    /// `FloatingTranscriptPanel.positionAtBottomCenterOfScreen()` places at
    /// the bottom-center of the main screen) — top-left corner of the
    /// screen, always clear of it regardless of screen size.
    private func moveMouseAwayFromPanel() {
        let farCorner = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 20))
        farCorner.hover()
    }

    /// Baseline: chrome (start button, close button) is visible/hittable the
    /// moment the panel appears — `isControlsVisible` defaults to `true`.
    func testControlBarIsVisibleOnLaunch() {
        let closeButton = app.buttons["隐藏悬浮窗"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(closeButton.isHittable)
    }

    /// Hovering away from the panel for longer than the 2s `autoHideDelay`
    /// hides the chrome (`.opacity(0)` + `.allowsHitTesting(false)`) — the
    /// close button becomes un-hittable. Hovering back over the panel
    /// immediately re-shows it with no delay.
    func testControlBarHidesAfterMouseLeavesAndDelayElapses() {
        let closeButton = app.buttons["隐藏悬浮窗"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))

        // Establish the "hovering" reference state first — this is also
        // what starts `onHover`'s isHovering=false branch once we move away,
        // since SwiftUI only fires that transition from a genuine prior
        // `true`.
        closeButton.hover()
        XCTAssertTrue(closeButton.isHittable)

        moveMouseAwayFromPanel()
        // Must not have hidden yet — `autoHideDelay` is 2s; checking too
        // early would pass even if the delay were accidentally removed
        // entirely (a real regression), so this is the guard that makes the
        // later "still hidden after 2s+" assertion meaningful evidence of
        // the delay actually being honored rather than an immediate hide.
        XCTAssertTrue(closeButton.isHittable, "chrome hid immediately instead of waiting for the 2s auto-hide delay")

        // Poll past the 2s delay with margin for CI/animation slack (the
        // 0.2s easeInOut) rather than a single fixed sleep.
        let hidden = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: closeButton)], timeout: 4)
        XCTAssertEqual(hidden, .completed, "close button should become un-hittable once the chrome auto-hides")

        // Hovering back over the panel re-shows the chrome immediately (no
        // delay on the way back in).
        closeButton.hover()
        let reshown = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: closeButton)], timeout: 2)
        XCTAssertEqual(reshown, .completed, "hovering back over the panel should re-show the chrome without delay")
    }

    /// Regression guard for `DraggableHostingView.mouseDown` — clicking a
    /// real SwiftUI control (the display-mode picker) must consume the
    /// click as a normal control interaction, not fall through to
    /// `window.performDrag(with:)` (which only fires for clicks landing on
    /// otherwise-empty background). A window drag would move the panel;
    /// this asserts its frame is unchanged by the click.
    func testClickingAControlDoesNotDragTheWindow() {
        let closeButton = app.buttons["隐藏悬浮窗"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))

        let panelWindow = closeButton.frameContainingWindow(in: app)
        XCTAssertNotNil(panelWindow, "could not locate the floating panel's window")
        guard let panelWindow else { return }
        let frameBefore = panelWindow.frame

        // Whichever `Picker` the control bar renders first (source language,
        // target language, display mode, or font scale — all are real
        // SwiftUI controls, not drag-through background) — clicking it pops
        // its menu rather than doing anything destructive.
        let aPicker = app.popUpButtons.firstMatch
        XCTAssertTrue(aPicker.waitForExistence(timeout: 5))
        aPicker.click()
        // Dismiss whatever menu opened (Escape) without selecting anything,
        // so this test doesn't depend on which option happens to be current.
        app.typeKey(.escape, modifierFlags: [])

        let frameAfter = panelWindow.frame
        XCTAssertEqual(frameBefore, frameAfter, "clicking a control moved the panel window — the click fell through to the drag handler")
    }
}

private extension XCUIElement {
    /// Walks up `app.windows` to find the one whose frame contains this
    /// element — there's no direct "containing window" accessor on
    /// `XCUIElement`, and this app only ever has a handful of windows open
    /// at once, so a linear frame-containment scan is simplest.
    func frameContainingWindow(in app: XCUIApplication) -> XCUIElement? {
        let elementFrame = self.frame
        for window in app.windows.allElementsBoundByIndex {
            if window.frame.contains(CGPoint(x: elementFrame.midX, y: elementFrame.midY)) {
                return window
            }
        }
        return nil
    }
}
