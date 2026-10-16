import AppKit

/// Quits and reopens the app — used after the interface language changes,
/// since the language is resolved once at launch.
enum AppRelauncher {
    /// Only a packaged `.app` can reopen itself; `swift run` can't.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func relaunch() {
        guard canRelaunch else { return }
        // The helper outlives this process (it is re-parented to launchd);
        // the short sleep lets this instance finish quitting first, otherwise
        // `open` would just re-activate it.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? helper.run()
        NSApp.terminate(nil)
    }
}
