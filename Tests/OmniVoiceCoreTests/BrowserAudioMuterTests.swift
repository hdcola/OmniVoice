import XCTest
@testable import OmniVoiceCore

final class BrowserAudioMuterTests: XCTestCase {
    func testBrowserHelpersWithAnOpenOutputAreMuted() {
        XCTAssertTrue(CoreAudioBrowserMuter.shouldMute(bundleID: "com.google.Chrome.helper", isRunningOutput: true, isRunningInput: false))
        XCTAssertTrue(CoreAudioBrowserMuter.shouldMute(bundleID: "com.apple.WebKit.GPU", isRunningOutput: true, isRunningInput: false))
        XCTAssertTrue(CoreAudioBrowserMuter.shouldMute(bundleID: "company.thebrowser.Browser.helper", isRunningOutput: true, isRunningInput: false))
    }

    /// Recording too means a call: the other side must stay audible.
    func testBrowserInACallIsLeftAlone() {
        XCTAssertFalse(CoreAudioBrowserMuter.shouldMute(bundleID: "com.google.Chrome.helper", isRunningOutput: true, isRunningInput: true))
    }

    func testOnlyBrowsersWithAnOpenOutput() {
        XCTAssertFalse(CoreAudioBrowserMuter.shouldMute(bundleID: "com.google.Chrome.helper", isRunningOutput: false, isRunningInput: false))
        XCTAssertFalse(CoreAudioBrowserMuter.shouldMute(bundleID: "com.apple.Music", isRunningOutput: true, isRunningInput: false))
        XCTAssertFalse(CoreAudioBrowserMuter.shouldMute(bundleID: "systemsoundserverd", isRunningOutput: true, isRunningInput: false))
    }

    /// The real CoreAudio calls have no mock to hide behind: they must at
    /// least run. A browser playing right now goes quiet for a moment.
    func testMuteAndUnmuteRunAgainstTheRealSystem() {
        let muter = CoreAudioBrowserMuter()
        _ = muter.mute()
        muter.unmute()
        muter.unmute()
    }
}
