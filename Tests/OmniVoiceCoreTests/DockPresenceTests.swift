import Testing
@testable import OmniVoiceCore

@Suite("DockPresenceTracker")
struct DockPresenceTests {
    @Test("first window shows the Dock icon, closing the last hides it")
    func singleWindow() {
        var t = DockPresenceTracker()
        #expect(t.windowOpened("settings") == .showDock)
        #expect(t.windowClosed("settings") == .hideDock)
        #expect(t.openCount == 0)
    }

    @Test("with several windows the Dock icon stays until the last one closes")
    func multipleWindows() {
        var t = DockPresenceTracker()
        #expect(t.windowOpened("onboarding") == .showDock)
        #expect(t.windowOpened("settings") == nil)
        #expect(t.windowClosed("onboarding") == nil)
        #expect(t.windowClosed("settings") == .hideDock)
    }

    @Test("re-opening the same window is not double counted")
    func idempotentOpen() {
        var t = DockPresenceTracker()
        _ = t.windowOpened("settings")
        #expect(t.windowOpened("settings") == nil)
        #expect(t.windowClosed("settings") == .hideDock)
    }

    @Test("closing an unknown window changes nothing; reopening after close shows again")
    func unknownAndReopen() {
        var t = DockPresenceTracker()
        #expect(t.windowClosed("ghost") == nil)
        _ = t.windowOpened("settings")
        _ = t.windowClosed("settings")
        #expect(t.windowOpened("settings") == .showDock)
    }
}
