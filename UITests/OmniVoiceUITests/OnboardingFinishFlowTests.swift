import XCTest

/// Priority item 1 — `OnboardingView.finish()`, guarding
/// against the Round 1/Round 2 must-fix regressions documented inline in
/// `OnboardingView.swift` (`diskSpaceWarningMessage`'s doc,
/// `finish()`'s doc): the window used to close and
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
/// Separately, actually clicking "一键开启并下载" with a local
/// model selected would kick off a real multi-GB background download — also
/// out of scope for a UI test, so these tests never select a model that
/// downloads before clicking the trigger button.
///
/// What IS covered: the "跳过向导" (no download at all) and system-engines
/// (`plan.transcription`/`plan.translation` both nil, so `finish()`'s
/// `startDownload` trivially passes with nothing to check) happy paths both
/// still close the window promptly through the three-step wizard — regression
/// coverage for the "window closes when it's supposed to" half of this logic,
/// which the disk-space fix could just as easily have broken by *always*
/// keeping the window open.
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

    /// The system speech recognition and system translation rows have
    /// nothing to download (`plan.transcription`/`plan.translation` are nil
    /// in `OnboardingView`) — clicking "完成" (the button's label when nothing
    /// downloads) after selecting both takes the same no-download path as
    /// skipping, and must likewise close the window immediately.
    func testFinishWithSystemEnginesSelectedClosesTheWindowImmediately() {
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 10))
        app.buttons["下一步"].click()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "系统语音识别")).firstMatch.click()
        app.buttons["下一步"].click()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "系统翻译")).firstMatch.click()
        // Nothing to download with system engines, so the button reads "完成".
        app.buttons["完成"].click()
        let closed = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: onboardingWindow)],
            timeout: 5
        )
        XCTAssertEqual(closed, .completed, "onboarding window should close once startDownload has nothing to do, same as the skip path")
    }
}
