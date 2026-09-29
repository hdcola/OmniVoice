import XCTest

/// Phase A infra smoke test — proves the unhosted `XCUIApplication(url:)`
/// setup (see `OmniVoiceUITestApp`'s doc) actually launches the real app
/// bundle and that XCUITest can see into its UI, before any of the
/// behavioral tests in this target rely on that working.
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        OmniVoiceUITestApp.resetUserDefaults()
        app = OmniVoiceUITestApp.launch()
    }

    /// Always runs even if the test body's assertion fails first
    /// (`continueAfterFailure = false` stops the test method immediately,
    /// which previously skipped an in-line `app.terminate()`)  — a leaked,
    /// still-running instance would otherwise get silently reactivated by
    /// the next test's `launch()` instead of that test getting its own
    /// fresh process (see `terminateAnyRunningInstance()`'s doc).
    override func tearDownWithError() throws {
        app.terminate()
    }

    /// A fresh install (see `setUpWithError`'s reset) always shows the
    /// onboarding window first (`AppDelegate.presentOnboardingIfNeeded()`) —
    /// its title bar text is the simplest, permission/network/model-free
    /// thing this app ever renders, so this only proves "the app launches
    /// and XCUITest can read its window", nothing behavioral yet.
    func testAppLaunchesAndShowsOnboardingWindow() {
        let onboardingWindow = app.windows["欢迎使用 OmniVoice"]
        XCTAssertTrue(onboardingWindow.waitForExistence(timeout: 10))
    }
}
