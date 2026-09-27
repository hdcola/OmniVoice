import CryptoKit
import Foundation

/// Errors `ModelDownloadManager.ensureDownloaded(_:progress:)` can throw.
public enum ModelDownloadError: LocalizedError, Sendable {
    /// `ModelVariant.downloadURL` is nil — nothing to fetch yet.
    case missingDownloadURL(variantID: String)
    /// A download for this variant is already running — callers should
    /// observe the existing one instead of starting a second, since two
    /// concurrent downloads to the same destination would race each other's
    /// temp file.
    case alreadyInProgress(variantID: String)
    case httpError(statusCode: Int)
    /// The downloaded file's SHA-256 didn't match `ModelVariant.sha256` — the
    /// partial/corrupted download is discarded, never moved into the cache.
    case checksumMismatch(variantID: String)

    public var errorDescription: String? {
        switch self {
        case .missingDownloadURL(let variantID):
            return "模型 \(variantID) 尚未配置下载地址"
        case .alreadyInProgress(let variantID):
            return "模型 \(variantID) 正在下载中"
        case .httpError(let statusCode):
            return "下载失败，服务器返回状态码 \(statusCode)"
        case .checksumMismatch(let variantID):
            return "模型 \(variantID) 校验和不匹配，下载文件可能已损坏，请重试"
        }
    }
}

/// Downloads and caches a `.model`-kind engine's weights on first use (see
/// `Docs/PROGRESS.md` Open Items — "Model download-on-first-use"), instead of
/// requiring an `R2T2_MODEL_PATH`/`R2T2_T3PO_MODEL_PATH` env var or a
/// repo-relative `models/` directory (`InProcessTranscriber`/
/// `InProcessTranslator.resolveModelPath`'s dev-only fallback, still used by
/// debug builds run from a source checkout).
///
/// One cached file per `ModelVariant`, named by `variant.id` under
/// Application Support, so switching quantizations never collides with or
/// silently reuses a different variant's file. A download is only ever
/// considered usable once its SHA-256 matches `ModelVariant.sha256` — a
/// partial or corrupted transfer must never reach
/// `InProcessTranscriber`/`InProcessTranslator.loadModel(modelPath:)`, which
/// have no validation of their own and would just fail deep inside
/// audio.cpp/llama.cpp with an unhelpful error (or, worse, load a truncated
/// GGUF that happens to still parse).
///
/// Delegate callbacks (`URLSessionDownloadDelegate`) arrive off the main
/// actor — same reasoning `SystemTranscriptionProvider`'s audio-path methods
/// document for being `nonisolated` — so they're marked `nonisolated` and
/// hop back to the main actor themselves for every mutation, rather than
/// mutating `activeTasks`/`continuations`/`progressHandlers` directly.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    public static let shared = ModelDownloadManager()

    private let cacheDirectory: URL
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var continuations: [String: CheckedContinuation<URL, Error>] = [:]
    private var progressHandlers: [String: @Sendable (Double) -> Void] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        super.init()
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OmniVoice/Models", isDirectory: true)
    }

    /// Where `variant`'s weights live once downloaded — regardless of
    /// whether they actually are yet (see `isDownloaded(_:)`).
    public func localURL(for variant: ModelVariant) -> URL {
        cacheDirectory.appendingPathComponent("\(variant.id).gguf")
    }

    public func isDownloaded(_ variant: ModelVariant) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: variant).path)
    }

    public func cancelDownload(for variant: ModelVariant) {
        activeTasks[variant.id]?.cancel()
    }

    /// Downloads `variant`'s weights if not already cached, verifying their
    /// SHA-256 before the file is considered usable, and returns the local
    /// path either way. `progress` is called on the main actor with a
    /// fraction in `0...1`; best-effort only — a response with no
    /// `Content-Length` never calls it.
    ///
    /// Throws `.alreadyInProgress` rather than joining an in-flight download
    /// for the same variant — callers that want to observe an existing
    /// download should read `isDownloading(_:)` first instead of racing a
    /// second `ensureDownloaded` call.
    public func ensureDownloaded(
        _ variant: ModelVariant,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = localURL(for: variant)
        if isDownloaded(variant) { return destination }
        guard let downloadURL = variant.downloadURL else {
            throw ModelDownloadError.missingDownloadURL(variantID: variant.id)
        }
        guard activeTasks[variant.id] == nil else {
            throw ModelDownloadError.alreadyInProgress(variantID: variant.id)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let tempFileURL = try await runDownload(variantID: variant.id, from: downloadURL, progress: progress)
        do {
            let expectedSHA256 = variant.sha256
            try await Task.detached(priority: .utility) {
                if let expectedSHA256 {
                    let actual = try Self.sha256Hex(ofFileAt: tempFileURL)
                    guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                        throw ModelDownloadError.checksumMismatch(variantID: variant.id)
                    }
                }
                try FileManager.default.moveItem(at: tempFileURL, to: destination)
            }.value
            return destination
        } catch {
            try? FileManager.default.removeItem(at: tempFileURL)
            throw error
        }
    }

    public func isDownloading(_ variant: ModelVariant) -> Bool {
        activeTasks[variant.id] != nil
    }

    private func runDownload(
        variantID: String, from url: URL, progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url)
                task.taskDescription = variantID
                activeTasks[variantID] = task
                continuations[variantID] = continuation
                if let progress {
                    progressHandlers[variantID] = progress
                }
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activeTasks[variantID]?.cancel()
            }
        }
    }

    private func finish(variantID: String, result: Result<URL, Error>) {
        guard let continuation = continuations.removeValue(forKey: variantID) else { return }
        activeTasks.removeValue(forKey: variantID)
        progressHandlers.removeValue(forKey: variantID)
        continuation.resume(with: result)
    }

    nonisolated private static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let variantID = downloadTask.taskDescription else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            self?.progressHandlers[variantID]?(fraction)
        }
    }

    /// `location` is deleted the instant this method returns, so it's moved
    /// to a stable temp path synchronously, on this delegate's own thread,
    /// before hopping back to the main actor to resolve the continuation.
    nonisolated public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let variantID = downloadTask.taskDescription else { return }
        let httpResponse = downloadTask.response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200..<300).contains(statusCode) {
            Task { @MainActor [weak self] in
                self?.finish(variantID: variantID, result: .failure(ModelDownloadError.httpError(statusCode: statusCode)))
            }
            return
        }
        let stableTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnivoice-model-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stableTempURL)
            Task { @MainActor [weak self] in
                self?.finish(variantID: variantID, result: .success(stableTempURL))
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.finish(variantID: variantID, result: .failure(error))
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        // Success is already handled by `didFinishDownloadingTo` above —
        // this only fires meaningfully (non-nil `error`) on a failure that
        // happens before/without a completed download (network error,
        // cancellation).
        guard let error, let variantID = task.taskDescription else { return }
        Task { @MainActor [weak self] in
            self?.finish(variantID: variantID, result: .failure(error))
        }
    }
}
