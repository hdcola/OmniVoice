import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    /// Sentinel id meaning "whatever macOS considers the default input
    /// device right now", rather than a specific pinned device.
    public static let systemDefaultID = "system-default"
    public static let systemDefault = AudioInputDevice(id: systemDefaultID, name: "系统默认")

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
