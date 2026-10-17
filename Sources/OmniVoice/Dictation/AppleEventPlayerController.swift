import AppKit
import OmniVoiceCore

/// Pauses and resumes Music and Spotify with their own Apple Events, sent to
/// the running process: an event addressed by PID never launches an app, and
/// one that finds the process gone just fails. Permission is only ever
/// checked here, never asked — the Automation prompt would steal the focus
/// mid-dictation. It is asked from Settings (`requestAccess`).
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
        case allowed, notDetermined, denied, notRunning
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
            guard let pid = pid(of: player) else { return (player, .notRunning) }
            return (player, access(pid: pid, ask: false))
        }
    }

    /// Shows the Automation prompt for each running player not yet decided.
    /// Blocks until answered, so it runs off the main thread; Settings only.
    static func requestAccess() async {
        let pids = players.compactMap { pid(of: $0) }
        await Task.detached {
            for pid in pids { _ = access(pid: pid, ask: true) }
        }.value
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
