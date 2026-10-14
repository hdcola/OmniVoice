import Foundation
import os

/// The step `DictationController.finish()` runs between recognition and
/// typing/translation. Whatever goes wrong, the original text comes back.
public struct DictationPolishFlow: Sendable {
    public enum Skip: Equatable, Sendable {
        case disabled
        case notConfigured
        case tooShort
    }

    public enum Outcome: Equatable, Sendable {
        case polished
        case skipped(Skip)
        /// The user chose to type the original while it was working.
        case cancelled
        case failed(PolishError)
    }

    public struct Result: Equatable, Sendable {
        public let text: String
        public let outcome: Outcome
    }

    /// Shorter than this many characters (CJK) or words (everything else)
    /// isn't worth a request.
    public static let minimumUnits = 8

    private static let log = Logger(subsystem: "org.hdcola.omnivoice", category: "dictation")

    public let settings: PolishSettings
    public let hasAPIKey: Bool
    private let makePolisher: @Sendable (PolishSettings) -> any TextPolisher

    public init(
        settings: PolishSettings, hasAPIKey: Bool,
        makePolisher: @escaping @Sendable (PolishSettings) -> any TextPolisher
    ) {
        self.settings = settings
        self.hasAPIKey = hasAPIKey
        self.makePolisher = makePolisher
    }

    /// The reason `run` would send nothing, or nil when it will make a request.
    public func skipReason(for text: String) -> Skip? {
        guard settings.isEnabled else { return .disabled }
        guard settings.isConfigured(hasAPIKey: hasAPIKey) else { return .notConfigured }
        guard Self.units(in: text) >= Self.minimumUnits else { return .tooShort }
        return nil
    }

    /// CJK characters count one each, other text counts by word.
    static func units(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }

    /// Cancelling the calling task types the original. Never throws.
    public func run(_ text: String) async -> Result {
        if let skip = skipReason(for: text) { return Result(text: text, outcome: .skipped(skip)) }

        let (masked, verbatim) = EntityMasker.mask(text)
        let polisher = makePolisher(settings)
        let started = Date()
        do {
            let raw = try await withTimeout(seconds: settings.timeoutSeconds) { try await polisher.polish(masked) }
            guard let valid = PolishOutputGuard.validate(output: raw, source: masked, style: settings.style) else {
                throw PolishError.rejected
            }
            let restored = EntityMasker.restore(translation: valid, verbatim: verbatim)
            Self.log.info("polish ok in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return Result(text: restored, outcome: .polished)
        } catch is CancellationError {
            Self.log.info("polish skipped by user")
            return Result(text: text, outcome: .cancelled)
        } catch let error as PolishError {
            Self.log.info("polish failed: \(error.message, privacy: .public)")
            return Result(text: text, outcome: .failed(error))
        } catch {
            Self.log.info("polish failed: network")
            return Result(text: text, outcome: .failed(.network))
        }
    }

    private func withTimeout(
        seconds: Int, _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PolishError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PolishError.network }
            return first
        }
    }
}
