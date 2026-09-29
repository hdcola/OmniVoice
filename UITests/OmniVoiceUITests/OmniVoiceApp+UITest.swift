import AppKit
import Foundation
import XCTest

/// Shared support for driving the real `OmniVoice.app` from an "unhosted" UI
/// Testing Bundle (see `UITests/project.yml`'s doc for why there's no
/// project-owned app target to point `XCUIApplication()`'s default
/// initializer at). `XCUIApplication(url:)` — the whole reason this works
/// without an Xcode-built app target — launches whatever `.app` bundle sits
/// at that URL, so every test here launches the exact same bundle
/// `Scripts/build_app.sh` produces for a real release build.
enum OmniVoiceUITestApp {
    /// `org.hdcola.omnivoice` — `Scripts/Info.plist`'s `CFBundleIdentifier`,
    /// the same one every real build of this app ships under. Wiping this
    /// domain (see `resetUserDefaults()`) is how tests get a deterministic
    /// "first launch" (onboarding not yet completed, default settings)
    /// without any test-only launch-argument hook — the app has none (see
    /// `AppDelegate.applicationDidFinishLaunching`), and adding one would be
    /// a production-code change outside a UI-test task's remit.
    static let bundleIdentifier = "org.hdcola.omnivoice"

    /// `UITests/OmniVoiceUITests/OmniVoiceApp+UITest.swift` → walk up to the
    /// repo root, then down into `build/OmniVoice.app` — the exact path
    /// `Scripts/build_app.sh` writes. Computed from `#filePath` (not the
    /// process's current working directory, which `xcodebuild test` doesn't
    /// guarantee) so this resolves correctly regardless of where
    /// `xcodebuild`/Xcode invokes the test bundle from.
    static var appBundleURL: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // OmniVoiceUITests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("build/OmniVoice.app")
    }

    /// `XCUIApplication(url:).launch()` goes through Launch Services, same
    /// as double-clicking the bundle in Finder — if an instance of this
    /// bundle identifier is *already* running (a previous test's app that
    /// crashed/failed before its own `terminate()` ran, or one left over
    /// from manual testing), Launch Services just reactivates that existing
    /// process instead of spawning a fresh one. That stale process already
    /// went through its own `applicationDidFinishLaunching` (onboarding
    /// possibly already dismissed, settings possibly already changed) —
    /// every test below assumes a truly fresh process, so this force-quits
    /// any survivor *before* `resetUserDefaults()`/`launch()` run, rather
    /// than relying on every test's own `tearDown` never being skipped.
    static func terminateAnyRunningInstance() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
        guard !running.isEmpty else { return }
        for instance in running {
            instance.forceTerminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
            NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Wipes every `UserDefaults` key this app persists under, so each test
    /// starts from a deterministic "fresh install" state (onboarding not
    /// completed, engine/language/panel settings back to their documented
    /// defaults) — see `PersistedOnboardingKey`/`RecordingSession`'s
    /// `PersistedSettingsKey` for the keys this clears. Must run *before*
    /// `launch()`, and after `terminateAnyRunningInstance()` — `defaults
    /// delete` on an already-running app's domain doesn't retroactively
    /// change what that process already read at launch, and a still-running
    /// instance can also re-write keys back to disk on its own termination,
    /// racing this reset.
    static func resetUserDefaults() {
        terminateAnyRunningInstance()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Launches a fresh instance of the app bundle at `appBundleURL`. Fails
    /// the calling test immediately (with a clear message, instead of a
    /// generic "app failed to launch" further down the line) if the bundle
    /// doesn't exist yet — the most common cause is simply forgetting to run
    /// `Scripts/build_app.sh` first (see `UITests/README.md`).
    static func launch(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        guard FileManager.default.fileExists(atPath: appBundleURL.path) else {
            XCTFail(
                "OmniVoice.app not found at \(appBundleURL.path) — run Scripts/build_app.sh before running UI tests.",
                file: file, line: line
            )
            return XCUIApplication(url: appBundleURL)
        }
        let app = XCUIApplication(url: appBundleURL)
        app.launch()
        return app
    }
}
