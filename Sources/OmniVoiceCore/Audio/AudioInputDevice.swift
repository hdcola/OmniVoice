import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    /// Sentinel id meaning "whatever macOS considers the default input
    /// device right now", rather than a specific pinned device.
    public static let systemDefaultID = "system-default"
    public static let systemDefault = AudioInputDevice(id: systemDefaultID, name: "系统默认")

    /// Sentinel id meaning "don't capture a microphone at all" — typically
    /// paired with "包含系统声音" on, for recording a meeting/lecture played
    /// through the Mac's own speakers/output with no one talking into a mic,
    /// but that's a separate, independently-toggled setting — not implied by
    /// this label, since picking "无" without it just means no audio source
    /// at all (`RecordingSession.start()` refuses to start in that case). See
    /// `RecordingSession.start()`'s handling of this id for what changes in
    /// the capture pipeline when it's selected (no `MicrophoneCapture`,
    /// `AudioMixer.micEnabled = false`, VAD segmentation driven by system
    /// audio instead of mic samples).
    public static let noneID = "none"
    public static let none = AudioInputDevice(id: noneID, name: "无")

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
