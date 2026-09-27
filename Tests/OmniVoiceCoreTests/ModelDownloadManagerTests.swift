import CryptoKit
import Foundation
import Testing

@testable import OmniVoiceCore

/// Covers the parts of `ModelDownloadManager` that don't require an actual
/// network round-trip to a multi-gigabyte Hugging Face file — cache path
/// construction, the "already cached" short-circuit, and the guard errors.
/// The download/verify/move happy path is exercised manually (see
/// `Docs/MODEL_ENGINE_SETUP.md`); a real download is deliberately not part
/// of CI.
@MainActor
struct ModelDownloadManagerTests {
    private func makeTempCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadManagerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private let variant = ModelVariant(
        id: "test-variant", engineID: "model.r2t2", displayName: "Test Variant",
        quantization: "Q8_0", approximateSizeMB: 1,
        downloadURL: URL(string: "https://example.invalid/model.gguf"),
        sha256: "abc123"
    )

    private let variantWithNoDownloadURL = ModelVariant(
        id: "no-url-variant", engineID: "model.r2t2", displayName: "No URL Variant",
        quantization: "Q8_0", approximateSizeMB: 1
    )

    @Test func localURLIsKeyedByVariantIDUnderTheCacheDirectory() {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        #expect(manager.localURL(for: variant) == cacheDirectory.appendingPathComponent("test-variant.gguf"))
    }

    @Test func isDownloadedReflectsWhetherTheCachedFileExists() throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        #expect(!manager.isDownloaded(variant))

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: manager.localURL(for: variant).path, contents: Data([0x01]))
        #expect(manager.isDownloaded(variant))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func ensureDownloadedReturnsTheCachedPathWithoutTouchingTheNetwork() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let expectedPath = manager.localURL(for: variant)
        FileManager.default.createFile(atPath: expectedPath.path, contents: Data([0x01, 0x02]))

        let resolved = try await manager.ensureDownloaded(variant)
        #expect(resolved == expectedPath)

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func ensureDownloadedThrowsWhenTheVariantHasNoDownloadURL() async {
        let manager = ModelDownloadManager(cacheDirectory: makeTempCacheDirectory())
        await #expect(throws: ModelDownloadError.self) {
            _ = try await manager.ensureDownloaded(variantWithNoDownloadURL)
        }
    }

    @Test func isDownloadingIsFalseWithNoDownloadInFlight() {
        let manager = ModelDownloadManager(cacheDirectory: makeTempCacheDirectory())
        #expect(!manager.isDownloading(variant))
    }

    @Test func deleteCachedModelRemovesTheCachedFile() throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: manager.localURL(for: variant).path, contents: Data([0x01]))
        #expect(manager.isDownloaded(variant))

        try manager.deleteCachedModel(for: variant)
        #expect(!manager.isDownloaded(variant))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func deleteCachedModelIsANoOpWhenNothingIsCached() throws {
        let manager = ModelDownloadManager(cacheDirectory: makeTempCacheDirectory())
        try manager.deleteCachedModel(for: variant)
    }

    // MARK: - verifyAndMove (no network needed — exercises the checksum/move
    // logic directly against a fabricated "downloaded" temp file)

    @Test func verifyAndMoveMovesTheFileWhenChecksumMatches() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        let content = Data("hello model weights".utf8)
        let tempFileURL = cacheDirectory.appendingPathComponent("temp-download")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: content)
        let destination = cacheDirectory.appendingPathComponent("dest.gguf")
        let correctSHA256 = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()

        try await manager.verifyAndMove(
            variantID: "x", expectedSHA256: correctSHA256, tempFileURL: tempFileURL, destination: destination
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: tempFileURL.path))
        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func verifyAndMoveThrowsAndLeavesNoDestinationFileOnChecksumMismatch() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        let tempFileURL = cacheDirectory.appendingPathComponent("temp-download")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: Data("corrupted".utf8))
        let destination = cacheDirectory.appendingPathComponent("dest.gguf")

        await #expect(throws: ModelDownloadError.self) {
            try await manager.verifyAndMove(
                variantID: "x", expectedSHA256: String(repeating: "0", count: 64),
                tempFileURL: tempFileURL, destination: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func verifyAndMoveThrowsWhenAlreadyCancelled() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)
        let tempFileURL = cacheDirectory.appendingPathComponent("temp-download")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: Data("hello".utf8))
        let destination = cacheDirectory.appendingPathComponent("dest.gguf")

        let task = Task {
            try await manager.verifyAndMove(
                variantID: "x", expectedSHA256: nil, tempFileURL: tempFileURL, destination: destination
            )
        }
        task.cancel()

        var threw = false
        do {
            try await task.value
        } catch {
            threw = true
        }
        #expect(threw)

        try FileManager.default.removeItem(at: cacheDirectory)
    }
}
