import XCTest

/// Priority item 1 — `OnboardingView.finish(startDownload:)`, guarding
/// against the Round 1/Round 2 must-fix regressions documented inline in
/// `OnboardingView.swift` (`diskSpaceWarningMessage`'s doc,
/// `finish(startDownload:)`'s doc): the window used to close and
/// `hasCompletedOnboarding` used to get persisted in the same run-loop turn
/// as a disk-space check failing, destroying the `.alert` before SwiftUI
/// ever presented it and leaving the wizard unrecoverable (already
/// "completed" with nothing actually downloaded).
///
/// SCOPED DOWN for the disk-space-insufficient path specifically — see this
/// task's final report. In summary: `ModelDownloadManager`'s disk-space
/// check (`insufficientDiskSpaceWarning(forTotalMB:)`) reads the *real*
/// available space on this machine's actual boot volume (there is no
/// injectable override reachable without a production-code change — see
/// `AppDelegate.init()`, which always constructs `RecordingSession` with the
/// default `modelDownloadManager: nil`); this dev machine has ample free
/// disk, so the warning path never fires naturally, and deliberately
/// exhausting real disk space to force it is destructive and out of scope.
/// Separately, actually clicking "一键开启并下载" with the `.balanced`/
/// `.offlineModel` mode selected would kick off a real ~3.4–12.4GB
/// background download — also out of scope for a UI test, so these tests
/// never select those modes before clicking the trigger button.
///
/// What IS covered: the "跳过向导" (no download at all) and `.lightweight`
/// mode (`selectedBundleID == nil`, so `finish(startDownload:)`'s own
/// `guard startBundleDownload() else { return }` trivially passes with
/// nothing to check) happy paths both still close the window promptly, and
/// mode-card selection itself updates visibly — regression coverage for the
/// "window closes when it's supposed to" half of this logic, which the
/// disk-space fix could just as easily have broken by *always* keeping the
/// window open.
final class OnboardingFinishFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = OmniVoiceUITestApp.launchFreshOnboarding()
    }

    override func tearDownWithError() throws {
        guard let app else { return }
        app.terminate()
    }

    private var onboardingWindow: XCUIElement { app.windows["欢迎使用 OmniVoice"] }

    /// "跳过向导" → `finish(startDownload: false)` → nothing to check, no
    /// alert possible — the window must close.
    func testSkipClosesTheOnboardingWindowImmediately() {
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 10))
        app.buttons["跳过向导"].click()
        let closed = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: onboardingWindow)],
            timeout: 5
        )
        XCTAssertEqual(closed, .completed, "onboarding window should close right after skipping, with nothing left to download")
    }

    /// `.lightweight` has nothing to download (`selectedBundleID == nil` in
    /// `OnboardingView`) — clicking "完成" (the button's label when nothing downloads) after selecting it takes
    /// the same `startDownload: false` path as skipping, and must likewise
    /// close the window immediately rather than hanging or leaving it open.
    func testFinishWithLightweightModeSelectedClosesTheWindowImmediately() {
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "极速轻量模式")).firstMatch.click()
        // Nothing to download in this mode, so the button reads "完成".
        app.buttons["完成"].click()
        let closed = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: onboardingWindow)],
            timeout: 5
        )
        XCTAssertEqual(closed, .completed, "onboarding window should close once startBundleDownload() has nothing to do, same as the skip path")
    }
}
