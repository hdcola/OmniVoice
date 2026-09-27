import CryptoKit
import Foundation

/// Errors `ModelDownloadManager.ensureDownloaded(_:progress:)` can throw.
public enum ModelDownloadError: LocalizedError, Sendable {
    /// `ModelVariant.downloadURL` is nil — nothing to fetch yet.
    case missingDownloadURL(variantID: String)
    case httpError(statusCode: Int)
    /// The downloaded file's SHA-256 didn't match `ModelVariant.sha256` — the
    /// partial/corrupted download is discarded, never moved into the cache.
    case checksumMismatch(variantID: String)

    public var errorDescription: String? {
        switch self {
        case .missingDownloadURL(let variantID):
            return "模型 \(variantID) 尚未配置下载地址"
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
/// A whole `ensureDownloaded` run (network transfer → SHA-256 verify → move
/// into the cache) is tracked as one `Task` per variant in `jobs`, not just
/// the network phase — a second `ensureDownloaded(_:)` call for the same
/// variant while one is already running joins that same `Task` instead of
/// starting a redundant multi-gigabyte transfer, and `isDownloading(_:)`/
/// `cancelDownload(for:)` stay accurate for the whole pipeline, not just
/// while bytes are actually in flight.
///
/// Delegate callbacks (`URLSessionDownloadDelegate`) arrive off the main
/// actor — same reasoning `SystemTranscriptionProvider`'s audio-path methods
/// document for being `nonisolated` — so they're marked `nonisolated` and
/// hop back to the main actor themselves for every mutation, rather than
/// mutating this class's state directly.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    public static let shared = ModelDownloadManager()

    private let cacheDirectory: URL
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// The whole `ensureDownloaded` pipeline for a variant currently in
    /// flight — see the type's doc for why this covers more than just the
    /// network transfer.
    private var jobs: [String: Task<URL, Error>] = [:]
    private var networkTasks: [String: URLSessionDownloadTask] = [:]
    private var networkContinuations: [String: CheckedContinuation<URL, Error>] = [:]
    /// Values are only ever created and called on the main actor (this
    /// class's default isolation) — not `@Sendable`, so the closure built in
    /// `runJob` can mutate `downloadProgress` directly instead of needing its
    /// own inner `Task { @MainActor in ... }` hop on every one of a
    /// multi-gigabyte download's several-thousand progress callbacks.
    private var progressHandlers: [String: (Double) -> Void] = [:]

    /// `0...1` per variant currently downloading — for a SwiftUI progress
    /// view to observe directly, instead of every caller needing to thread
    /// its own `progress` closure through. Cleared once `ensureDownloaded`
    /// returns or throws.
    @Published public private(set) var downloadProgress: [String: Double] = [:]

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

    public func isDownloading(_ variant: ModelVariant) -> Bool {
        jobs[variant.id] != nil
    }

    /// Cancels `variant`'s in-flight `ensureDownloaded` pipeline, whichever
    /// phase it's currently in (network transfer or SHA-256 verify/move) —
    /// every awaiter of that same job (see `ensureDownloaded`'s doc on
    /// joining an existing job) sees it throw `CancellationError`. A no-op
    /// if nothing is in flight for this variant.
    public func cancelDownload(for variant: ModelVariant) {
        jobs[variant.id]?.cancel()
    }

    /// Removes `variant`'s cached weights, if any — e.g. to let a user
    /// recover from a corrupted/stale local file without waiting for an
    /// engine switch (which doesn't touch the cache) or reinstalling the
    /// app. A no-op if nothing is cached.
    public func deleteCachedModel(for variant: ModelVariant) throws {
        let url = localURL(for: variant)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Downloads `variant`'s weights if not already cached, verifying their
    /// SHA-256 before the file is considered usable, and returns the local
    /// path either way. `progress` is called on the main actor with a
    /// fraction in `0...1` (best-effort — a response with no
    /// `Content-Length` never calls it); `downloadProgress` reflects the
    /// same values for any caller that'd rather observe than pass a closure.
    ///
    /// If a download for this variant is already running, this call joins
    /// it rather than starting a second, redundant one — the two calls'
    /// results resolve together once the single underlying job finishes.
    /// Only the joining call's own `progress` closure is not attached to
    /// that job (the job already reports through `downloadProgress`, which
    /// every caller can observe); the *initiating* call's `progress` closure
    /// still fires for however many callers are waiting.
    public func ensureDownloaded(
        _ variant: ModelVariant,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = localURL(for: variant)
        if isDownloaded(variant) { return destination }
        guard variant.downloadURL != nil else {
            throw ModelDownloadError.missingDownloadURL(variantID: variant.id)
        }

        if let existingJob = jobs[variant.id] {
            return try await existingJob.value
        }

        // The cleanup `defer` lives inside the job's own `Task` body, not in
        // this function's scope — this function returns (or throws, e.g. on
        // cancellation) as soon as `job.value` does for *this* caller, which
        // can happen well before the job itself finishes for any other
        // caller that joined it. A `defer` here would clear `jobs[variant.id]`
        // out from under a still-running job the moment the *first* caller's
        // own await was cancelled, making a second `ensureDownloaded(_:)`
        // call start a redundant second download while the first is still
        // writing to (and, on delegate callback, resuming a continuation
        // for) the very same temp file / `networkContinuations` entry.
        let job = Task { [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            defer {
                self.jobs[variant.id] = nil
                self.downloadProgress[variant.id] = nil
            }
            return try await self.runJob(for: variant, progress: progress)
        }
        jobs[variant.id] = job
        return try await job.value
    }

    private func runJob(
        for variant: ModelVariant, progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try Task.checkCancellation()
        let destination = localURL(for: variant)
        guard let downloadURL = variant.downloadURL else {
            throw ModelDownloadError.missingDownloadURL(variantID: variant.id)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let tempFileURL = try await runDownload(variantID: variant.id, from: downloadURL) { [weak self] fraction in
            self?.downloadProgress[variant.id] = fraction
            progress?(fraction)
        }
        do {
            try await verifyAndMove(
                variantID: variant.id, expectedSHA256: variant.sha256,
                tempFileURL: tempFileURL, destination: destination
            )
            return destination
        } catch {
            try? FileManager.default.removeItem(at: tempFileURL)
            throw error
        }
    }

    private func runDownload(
        variantID: String, from url: URL, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url)
                task.taskDescription = variantID
                networkTasks[variantID] = task
                networkContinuations[variantID] = continuation
                progressHandlers[variantID] = progress
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.networkTasks[variantID]?.cancel()
            }
        }
    }

    /// SHA-256 verification (multi-GB files, a few seconds of pure hashing)
    /// runs off the main actor entirely — same reasoning the `.model`
    /// providers' own load-off-main-actor fix documents (see CHANGELOG) —
    /// and checks `Task.checkCancellation()` between chunks so
    /// `cancelDownload(for:)` lands promptly instead of running the whole
    /// hash to completion regardless. Internal (not `private`) so tests can
    /// exercise the verify/move logic directly against a fabricated temp
    /// file, without a real network transfer to produce one.
    func verifyAndMove(
        variantID: String, expectedSHA256: String?, tempFileURL: URL, destination: URL
    ) async throws {
        let task = Task.detached(priority: .utility) {
            if let expectedSHA256 {
                let actual = try Self.sha256Hex(ofFileAt: tempFileURL)
                guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                    throw ModelDownloadError.checksumMismatch(variantID: variantID)
                }
            }
            try Task.checkCancellation()
            // `replaceItemAt` (rather than a check-then-`moveItem`) handles
            // a stale file already sitting at `destination` (e.g. left over
            // from a build that cached under a since-changed layout)
            // atomically, instead of a separate remove-then-move that could
            // race a concurrent reader of `destination`.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempFileURL)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(variantID: String, result: Result<URL, Error>) {
        guard let continuation = networkContinuations.removeValue(forKey: variantID) else { return }
        networkTasks.removeValue(forKey: variantID)
        progressHandlers.removeValue(forKey: variantID)
        continuation.resume(with: result)
    }

    private nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
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
