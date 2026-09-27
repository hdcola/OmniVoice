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

    private let hugeVariant = ModelVariant(
        id: "huge-variant", engineID: "model.r2t2", displayName: "Huge Variant",
        quantization: "Q8_0", approximateSizeMB: Int.max / 2,
        downloadURL: URL(string: "https://example.invalid/model.gguf")
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

    @Test func ensureDownloadedThrowsWhenDiskSpaceIsInsufficient() async throws {
        // No real network involved — the disk-space preflight check runs
        // (and this throws) before `runDownload` ever touches
        // `example.invalid`.
        let cacheDirectory = makeTempCacheDirectory()
        let manager = ModelDownloadManager(cacheDirectory: cacheDirectory)

        do {
            _ = try await manager.ensureDownloaded(hugeVariant)
            Issue.record("expected ensureDownloaded to throw")
        } catch let error as ModelDownloadError {
            guard case .insufficientDiskSpace = error else {
                Issue.record("expected .insufficientDiskSpace, got \(error)")
                return
            }
        }

        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func initRemovesOrphanedTempFilesButKeepsCachedModels() throws {
        let cacheDirectory = makeTempCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let orphan = cacheDirectory.appendingPathComponent("omnivoice-model-download-orphan")
        FileManager.default.createFile(atPath: orphan.path, contents: Data([0x01]))
        let cached = cacheDirectory.appendingPathComponent("test-variant.gguf")
        FileManager.default.createFile(atPath: cached.path, contents: Data([0x02]))

        _ = ModelDownloadManager(cacheDirectory: cacheDirectory)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: cached.path))

        try FileManager.default.removeItem(at: cacheDirectory)
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

    // MARK: - Network phase, mocked via a custom URLProtocol (no real
    // network — `sessionConfiguration` is injectable for exactly this)

    private func makeMockedManager(cacheDirectory: URL) -> ModelDownloadManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ModelDownloadManager(cacheDirectory: cacheDirectory, sessionConfiguration: configuration)
    }

    @Test func ensureDownloadedSucceedsAgainstAMockedHTTPResponse() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = makeMockedManager(cacheDirectory: cacheDirectory)
        let mockedVariant = ModelVariant(
            id: "mocked-ok", engineID: "model.r2t2", displayName: "Mocked", quantization: "Q8_0",
            approximateSizeMB: 1, downloadURL: StubURLProtocol.url(status: 200, path: "ok.gguf")
        )

        let resolved = try await manager.ensureDownloaded(mockedVariant)
        let content = try Data(contentsOf: resolved)
        #expect(content == StubURLProtocol.body(forPath: "ok.gguf"))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func ensureDownloadedVerifiesChecksumAgainstAMockedResponse() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = makeMockedManager(cacheDirectory: cacheDirectory)
        let path = "checksummed.gguf"
        let expectedSHA256 = SHA256.hash(data: StubURLProtocol.body(forPath: path))
            .map { String(format: "%02x", $0) }.joined()
        let mockedVariant = ModelVariant(
            id: "mocked-checksum-ok", engineID: "model.r2t2", displayName: "Mocked", quantization: "Q8_0",
            approximateSizeMB: 1, downloadURL: StubURLProtocol.url(status: 200, path: path),
            sha256: expectedSHA256
        )

        let resolved = try await manager.ensureDownloaded(mockedVariant)
        #expect(FileManager.default.fileExists(atPath: resolved.path))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func ensureDownloadedThrowsOnMockedChecksumMismatch() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = makeMockedManager(cacheDirectory: cacheDirectory)
        let mockedVariant = ModelVariant(
            id: "mocked-checksum-bad", engineID: "model.r2t2", displayName: "Mocked", quantization: "Q8_0",
            approximateSizeMB: 1, downloadURL: StubURLProtocol.url(status: 200, path: "bad-checksum.gguf"),
            sha256: String(repeating: "0", count: 64)
        )

        await #expect(throws: ModelDownloadError.self) {
            _ = try await manager.ensureDownloaded(mockedVariant)
        }
        #expect(!manager.isDownloaded(mockedVariant))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func ensureDownloadedThrowsOnMockedHTTPError() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = makeMockedManager(cacheDirectory: cacheDirectory)
        let mockedVariant = ModelVariant(
            id: "mocked-404", engineID: "model.r2t2", displayName: "Mocked", quantization: "Q8_0",
            approximateSizeMB: 1, downloadURL: StubURLProtocol.url(status: 404, path: "missing.gguf")
        )

        do {
            _ = try await manager.ensureDownloaded(mockedVariant)
            Issue.record("expected ensureDownloaded to throw")
        } catch let error as ModelDownloadError {
            guard case .httpError(let statusCode) = error else {
                Issue.record("expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 404)
        }

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func deleteCachedModelCancelsAnInFlightDownload() async throws {
        let cacheDirectory = makeTempCacheDirectory()
        let manager = makeMockedManager(cacheDirectory: cacheDirectory)
        let mockedVariant = ModelVariant(
            id: "mocked-delete-inflight", engineID: "model.r2t2", displayName: "Mocked", quantization: "Q8_0",
            approximateSizeMB: 1,
            downloadURL: StubURLProtocol.slowURL(status: 200, delayMS: 300, path: "slow.gguf")
        )

        let task = Task { try await manager.ensureDownloaded(mockedVariant) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.isDownloading(mockedVariant))

        try manager.deleteCachedModel(for: mockedVariant)

        do {
            _ = try await task.value
            Issue.record("expected the in-flight download to be cancelled")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(!manager.isDownloaded(mockedVariant))

        try FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test func cacheDirectoryIsExcludedFromBackup() throws {
        let cacheDirectory = makeTempCacheDirectory()
        _ = ModelDownloadManager(cacheDirectory: cacheDirectory)

        let values = try cacheDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        try FileManager.default.removeItem(at: cacheDirectory)
    }
}

/// A minimal `URLProtocol` stub so the network phase (success, checksum
/// verification, HTTP errors) can be exercised without a real network call.
/// The desired status code and a path-derived body are both encoded in the
/// request URL itself — not shared mutable state — so tests stay
/// independent under parallel execution.
private final class StubURLProtocol: URLProtocol {
    static func url(status: Int, path: String) -> URL {
        URL(string: "https://mock.invalid/\(status)/\(path)")!
    }

    /// A response delayed by `delayMS` — for tests that need a window
    /// during which the "download" is still in flight (e.g. cancellation).
    static func slowURL(status: Int, delayMS: Int, path: String) -> URL {
        URL(string: "https://mock.invalid/\(status)/slow-\(delayMS)/\(path)")!
    }

    static func body(forPath path: String) -> Data {
        Data("stubbed content for \(path)".utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var components = url.pathComponents.filter { $0 != "/" }
        let statusCode = components.first.flatMap { Int($0) } ?? 200
        components = Array(components.dropFirst())
        var delayMS = 0
        if let first = components.first, first.hasPrefix("slow-"), let ms = Int(first.dropFirst(5)) {
            delayMS = ms
            components = Array(components.dropFirst())
        }
        let path = components.joined(separator: "/")
        let body = Self.body(forPath: path)

        let respond = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil,
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if (200..<300).contains(statusCode) {
                self.client?.urlProtocol(self, didLoad: body)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delayMS > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMS), execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
