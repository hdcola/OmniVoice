import AppKit
import OmniVoiceCore

/// Pauses and resumes Music and Spotify with their own Apple Events, sent to
/// the running process: an event addressed by PID never launches an app, and
/// one that finds the process gone just fails. Permission is only ever
/// checked here, never asked — the Automation prompt would steal the focus
/// mid-dictation. It is asked from Settings (`requestAccess`).
///
/// Unreachable players aren't left unpaused: `MediaPauser` falls back to the
/// play/pause key for them.
struct AppleEventPlayerController: PlayerController {
    struct Player: Sendable {
        let bundleID: String
        let name: String
        /// The suite `play`/`pause` belong to in the app's scripting dictionary.
        let suite: AEEventClass
    }

    /// Both dictionaries share the iTunes-era codes: `play`, `pause` and
    /// `player state` (`pPlS`), whose `playing` is `kPSP`.
    static let players = [
        Player(bundleID: "com.apple.Music", name: "Music", suite: fourCC("hook")),
        Player(bundleID: "com.spotify.client", name: "Spotify", suite: fourCC("spfy")),
    ]

    enum Access: Equatable {
        case allowed, notDetermined, denied, notRunning, notInstalled
    }

    private static let playCode = fourCC("Play")
    private static let pauseCode = fourCC("Paus")
    private static let playerStateCode = fourCC("pPlS")
    private static let playingCode = fourCC("kPSP")

    func reachablePlayers() -> [PlayerHandle] {
        Self.players.compactMap { player in
            guard let pid = Self.pid(of: player), Self.access(pid: pid, ask: false) == .allowed else { return nil }
            return PlayerHandle(bundleID: player.bundleID, pid: pid)
        }
    }

    func isPlaying(_ player: PlayerHandle) -> Bool {
        // `get player state of application`
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: FourCharCode(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: Self.playerStateCode), forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        guard let property = specifier.coerce(toDescriptorType: DescType(typeObjectSpecifier)),
              let reply = Self.send(AEEventClass(kAECoreSuite), AEEventID(kAEGetData), to: player.pid, directObject: property)
        else { return false }
        return reply.paramDescriptor(forKeyword: keyDirectObject)?.enumCodeValue == Self.playingCode
    }

    func pause(_ player: PlayerHandle) -> Bool {
        guard let suite = Self.suite(of: player) else { return false }
        return Self.send(suite, Self.pauseCode, to: player.pid) != nil
    }

    func play(_ player: PlayerHandle) {
        guard let suite = Self.suite(of: player) else { return }
        _ = Self.send(suite, Self.playCode, to: player.pid)
    }

    /// Where each player stands, without asking.
    static func accessStatus() -> [(player: Player, access: Access)] {
        players.map { player in
            guard isInstalled(player) else { return (player, .notInstalled) }
            // Not running, macOS won't say; the last answer seen stands in.
            guard let pid = pid(of: player) else { return (player, lastKnownAccess(player) ?? .notRunning) }
            let access = access(pid: pid, ask: false)
            remember(access, for: player)
            return (player, access)
        }
    }

    /// Shows the Automation prompt for each installed player not yet decided.
    /// macOS only asks on behalf of a running app, so one that isn't running
    /// is started hidden, without taking the focus, and quit again once
    /// answered. Settings only: the user just clicked for this.
    @MainActor
    static func requestAccess() async {
        for player in players {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { continue }
            var launched: NSRunningApplication?
            if pid(of: player) == nil {
                // Already answered: starting it would only re-read that answer.
                guard lastKnownAccess(player) == nil else { continue }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                configuration.addsToRecentItems = false
                guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                else { continue }
                launched = app
                for _ in 0..<50 where !app.isFinishedLaunching {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard let pid = launched?.processIdentifier ?? pid(of: player) else { continue }
            // Blocks until answered (at once if already decided).
            let access = await Task.detached { access(pid: pid, ask: true) }.value
            remember(access, for: player)
            launched?.terminate()
        }
    }

    /// A closed player's denial can't be re-checked, so it would stand even
    /// after the user turns it on in System Settings. Forgotten, it shows as
    /// not running and `requestAccess` starts it to check again.
    static func forgetDeniedAccessOfClosedPlayers() {
        for player in players where pid(of: player) == nil && lastKnownAccess(player) == .denied {
            UserDefaults.standard.removeObject(forKey: lastKnownAccessKey(player))
        }
    }

    private static func lastKnownAccessKey(_ player: Player) -> String {
        "org.hdcola.omnivoice.dictation.playerAccess.\(player.bundleID)"
    }

    private static func lastKnownAccess(_ player: Player) -> Access? {
        switch UserDefaults.standard.string(forKey: lastKnownAccessKey(player)) {
        case "allowed": .allowed
        case "denied": .denied
        default: nil
        }
    }

    /// Only decided answers; anything else says nothing about the permission.
    private static func remember(_ access: Access, for player: Player) {
        switch access {
        case .allowed: UserDefaults.standard.set("allowed", forKey: lastKnownAccessKey(player))
        case .denied: UserDefaults.standard.set("denied", forKey: lastKnownAccessKey(player))
        case .notDetermined: UserDefaults.standard.removeObject(forKey: lastKnownAccessKey(player))
        case .notRunning, .notInstalled: break
        }
    }

    private static func isInstalled(_ player: Player) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) != nil
    }

    private static func pid(of player: Player) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }

    private static func suite(of handle: PlayerHandle) -> AEEventClass? {
        players.first { $0.bundleID == handle.bundleID }?.suite
    }

    private static func access(pid: pid_t, ask: Bool) -> Access {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let desc = target.aeDesc else { return .notRunning }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notRunning // procNotFound: quit in the meantime
        }
    }

    /// Never interacts: an undecided permission fails instead of prompting.
    private static func send(
        _ eventClass: AEEventClass,
        _ eventID: AEEventID,
        to pid: pid_t,
        directObject: NSAppleEventDescriptor? = nil
    ) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let directObject { event.setParam(directObject, forKeyword: keyDirectObject) }
        return try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.5)
    }
}

private func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
