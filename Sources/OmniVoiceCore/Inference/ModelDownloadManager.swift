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
    /// The cache directory's volume doesn't have enough free space for
    /// `ModelVariant.approximateSizeMB` — checked before starting the
    /// transfer, not discovered partway through as an `ENOSPC` write failure.
    case insufficientDiskSpace(requiredMB: Int, availableMB: Int)

    public var errorDescription: String? {
        switch self {
        case .missingDownloadURL(let variantID):
            return "模型 \(variantID) 尚未配置下载地址"
        case .httpError(let statusCode):
            return "下载失败，服务器返回状态码 \(statusCode)"
        case .checksumMismatch(let variantID):
            return "模型 \(variantID) 校验和不匹配，下载文件可能已损坏，请重试"
        case .insufficientDiskSpace(let requiredMB, let availableMB):
            return "磁盘空间不足：需要约 \(requiredMB) MB，可用空间仅 \(availableMB) MB"
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
/// mutating this class's state directly. They're implemented on a private
/// `DownloadDelegateProxy` that holds `self` *weakly*, not on this class
/// directly — `URLSession` retains its delegate for as long as the session
/// lives, and this class's own `session` property retains the session right
/// back; conforming directly would make that a permanent retain cycle for
/// any non-`shared` instance (every unit test's own instance included) the
/// moment its first download touched `session`.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    public static let shared = ModelDownloadManager()

    private nonisolated static let tempFilePrefix = "omnivoice-model-download-"
    private nonisolated static let diskSpaceSafetyMarginMB = 512

    private let cacheDirectory: URL
    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session = URLSession(
        configuration: sessionConfiguration, delegate: DownloadDelegateProxy(target: self), delegateQueue: nil
    )

    /// The whole `ensureDownloaded` pipeline for a variant currently in
    /// flight — see the type's doc for why this covers more than just the
    /// network transfer.
    private var jobs: [String: Task<URL, Error>] = [:]
    private var networkTasks: [String: URLSessionDownloadTask] = [:]
    private var networkContinuations: [String: CheckedContinuation<URL, Error>] = [:]
    /// Every caller currently waiting on a variant's progress — the
    /// *initiating* `ensureDownloaded(_:progress:)` call's closure, plus any
    /// later call that joined the same in-flight job (see `ensureDownloaded`'s
    /// doc). Values are only ever created and invoked on the main actor (this
    /// class's default isolation) — `ensureDownloaded`'s `progress` parameter
    /// is declared `@MainActor @Sendable` precisely so a caller can mutate
    /// its own main-actor state directly from inside the closure, without
    /// needing its own inner `Task { @MainActor in ... }` hop on every one of
    /// a multi-gigabyte download's several-thousand progress callbacks.
    private var progressHandlers: [String: [@MainActor (Double) -> Void]] = [:]
    /// Throttle state for `handleProgress` — see its doc.
    private var lastReportedProgress: [String: (fraction: Double, time: Date)] = [:]

    /// `0...1` per variant currently downloading — for a SwiftUI progress
    /// view to observe directly, instead of every caller needing to thread
    /// its own `progress` closure through. Cleared once `ensureDownloaded`
    /// returns or throws.
    @Published public private(set) var downloadProgress: [String: Double] = [:]

    /// - Parameter sessionConfiguration: injectable so tests can register a
    ///   custom `URLProtocol` (via `.protocolClasses`) to exercise the
    ///   network phase (redirects, HTTP errors, disconnects) without a real
    ///   network round-trip. Defaults to `.default`.
    public init(cacheDirectory: URL? = nil, sessionConfiguration: URLSessionConfiguration = .default) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.sessionConfiguration = sessionConfiguration
        super.init()
        prepareCacheDirectory()
        cleanUpOrphanedTempFiles()
    }

    /// Creates the cache directory up front (idempotent — `runJob` no longer
    /// needs to) and excludes it from Time Machine/iCloud backup. Application
    /// Support is backed up by default, and these are multi-GB, perfectly
    /// re-downloadable files — backing them up just burns the user's backup
    /// disk/APFS snapshot space for no benefit.
    private func prepareCacheDirectory() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var mutableCacheDirectory = cacheDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableCacheDirectory.setResourceValues(values)
    }

    /// A crash, force-quit, or system shutdown mid-download leaves its
    /// stable temp file (see `handleDidFinishDownloading`'s doc) behind
    /// forever otherwise — nothing else would ever revisit or remove it,
    /// and it can be as large as the model itself (multi-GB).
    private func cleanUpOrphanedTempFiles() {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: nil
            )
        else { return }
        for url in entries where url.lastPathComponent.hasPrefix(Self.tempFilePrefix) {
            try? FileManager.default.removeItem(at: url)
        }
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
    /// app. A no-op if nothing is cached. Also cancels an in-flight download
    /// for this variant, if any — without that, a download already
    /// partway through would just silently re-populate the cache a few
    /// minutes later, defeating the point of "delete this model".
    public func deleteCachedModel(for variant: ModelVariant) throws {
        cancelDownload(for: variant)
        let url = localURL(for: variant)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // `isDownloaded(_:)` is a plain file-existence check, not a
        // `@Published` property — nothing here would otherwise tell a
        // SwiftUI observer (`ModelManagementView`/`SettingsView`) that it
        // just changed, leaving a stale "已下载" row on screen until some
        // unrelated `@Published` mutation happened to trigger a re-render.
        objectWillChange.send()
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
    /// results resolve together once the single underlying job finishes, and
    /// a non-nil `progress` from *either* call fires for the rest of that
    /// job's lifetime (both closures are registered, not just the
    /// initiating call's).
    public func ensureDownloaded(
        _ variant: ModelVariant,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = localURL(for: variant)
        if isDownloaded(variant) { return destination }
        guard variant.downloadURL != nil else {
            throw ModelDownloadError.missingDownloadURL(variantID: variant.id)
        }

        if let progress {
            // A call joining a download already partway through would
            // otherwise not hear anything until the next network chunk (or,
            // worse, not at all if that chunk lands during the SHA-256
            // verify/move phase, which reports no progress of its own) —
            // report whatever's already known immediately.
            if let current = downloadProgress[variant.id] {
                progress(current)
            }
            progressHandlers[variant.id, default: []].append(progress)
        }

        if let existingJob = jobs[variant.id] {
            return try await existingJob.value
        }

        // The cleanup `defer` lives inside the job's own `Task` body, not in
        // this function's scope. This isn't guarding against caller
        // cancellation racing job completion — cancelling *this* call's own
        // awaiting context doesn't interrupt `try await job.value` early (an
        // unstructured `Task`'s `.value` waits for the task to actually
        // finish regardless); only an explicit `cancelDownload(for:)` call
        // does, by cancelling `job` itself. Tying cleanup to the job's own
        // body just ties its lifetime to the job's real completion by
        // construction, rather than to however many/few callers happen to
        // still be awaiting it — simpler to reason about than relying on the
        // above being true.
        let job = Task { [weak self] () throws -> URL in
            guard let self else { throw CancellationError() }
            defer {
                self.jobs[variant.id] = nil
                self.downloadProgress[variant.id] = nil
                self.progressHandlers[variant.id] = nil
                self.lastReportedProgress[variant.id] = nil
            }
            return try await self.runJob(for: variant)
        }
        // `jobs` isn't `@Published` either — without this, `isDownloading(_:)`
        // flipping to `true` right here (well before the first
        // `downloadProgress` tick, which is what actually publishes) has
        // nothing to prompt a SwiftUI observer to re-check it, leaving a
        // "下载" button showing during the DNS/TLS/redirect gap instead of
        // the "准备下载…" state it's meant to cover.
        objectWillChange.send()
        jobs[variant.id] = job
        return try await job.value
    }

    private func runJob(for variant: ModelVariant) async throws -> URL {
        try Task.checkCancellation()
        let destination = localURL(for: variant)
        guard let downloadURL = variant.downloadURL else {
            throw ModelDownloadError.missingDownloadURL(variantID: variant.id)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // A safety margin beyond the model's own size, not just "does it
        // technically fit" — landing at only a few MB of free space after a
        // multi-GB download risks starving APFS/other processes right after
        // the download that was supposed to succeed.
        let requiredMB = variant.approximateSizeMB + Self.diskSpaceSafetyMarginMB
        if let availableMB = Self.availableDiskSpaceMB(at: cacheDirectory), availableMB < requiredMB {
            throw ModelDownloadError.insufficientDiskSpace(requiredMB: requiredMB, availableMB: availableMB)
        }

        let tempFileURL = try await runDownload(variantID: variant.id, from: downloadURL)
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

    private func runDownload(variantID: String, from url: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url)
                task.taskDescription = variantID
                networkTasks[variantID] = task
                networkContinuations[variantID] = continuation
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
        continuation.resume(with: result)
    }

    /// A high-bandwidth multi-GB transfer can call this thousands of times
    /// per second (`didWriteData` fires roughly once per TCP read, often
    /// 64–512 KB) — writing `downloadProgress` (a `@Published` property)
    /// unconditionally on every call would fire `objectWillChange` just as
    /// often, which is much more expensive than the dictionary write itself
    /// once any SwiftUI view is actually observing it. Throttled to at most
    /// once per ~0.5% of progress or 100ms, whichever comes first — except
    /// the terminal `1.0`, which always gets through so a progress view
    /// never gets stuck just short of "done".
    fileprivate func handleProgress(variantID: String, fraction: Double) {
        let now = Date()
        if let last = lastReportedProgress[variantID], fraction < 1.0,
            fraction - last.fraction < 0.005, now.timeIntervalSince(last.time) < 0.1
        {
            return
        }
        lastReportedProgress[variantID] = (fraction, now)
        downloadProgress[variantID] = fraction
        progressHandlers[variantID]?.forEach { $0(fraction) }
    }

    /// Best-effort — `nil` (never blocking a download) if the volume's
    /// available capacity can't be determined, e.g. an unusual filesystem
    /// that doesn't report `.volumeAvailableCapacityForImportantUsageKey`.
    private nonisolated static func availableDiskSpaceMB(at url: URL) -> Int? {
        guard
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(capacity / (1024 * 1024))
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

extension ModelDownloadManager {
    fileprivate nonisolated func handleDidWriteData(
        downloadTask: URLSessionDownloadTask, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let variantID = downloadTask.taskDescription else { return }
        // Clamped defensively — a server-reported `Content-Length` that
        // doesn't quite match the actual byte count would otherwise hand a
        // SwiftUI `ProgressView(value:)` a fraction slightly over 1.0.
        let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task { @MainActor [weak self] in
            self?.handleProgress(variantID: variantID, fraction: fraction)
        }
    }

    /// `location` is deleted the instant this method returns, so it's moved
    /// to a stable temp path synchronously, on this delegate's own thread,
    /// before hopping back to the main actor to resolve the continuation.
    /// That stable temp path lives inside `cacheDirectory` itself (not the
    /// system temp directory) — `verifyAndMove`'s later
    /// `FileManager.replaceItemAt` requires both URLs on the same volume,
    /// which the system temp directory isn't guaranteed to share with a
    /// caller-supplied `cacheDirectory` on a different disk/external volume.
    fileprivate nonisolated func handleDidFinishDownloading(downloadTask: URLSessionDownloadTask, location: URL) {
        guard let variantID = downloadTask.taskDescription else { return }
        let httpResponse = downloadTask.response as? HTTPURLResponse
        if let statusCode = httpResponse?.statusCode, !(200..<300).contains(statusCode) {
            Task { @MainActor [weak self] in
                self?.finish(variantID: variantID, result: .failure(ModelDownloadError.httpError(statusCode: statusCode)))
            }
            return
        }
        let stableTempURL = cacheDirectory
            .appendingPathComponent("\(Self.tempFilePrefix)\(UUID().uuidString)")
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

    /// Success is already handled by `handleDidFinishDownloading` above —
    /// this only fires meaningfully (non-nil `error`) on a failure that
    /// happens before/without a completed download (network error,
    /// cancellation). `URLSessionTask.cancel()` surfaces as
    /// `URLError(.cancelled)`, not `CancellationError` — mapped here so
    /// every awaiter of `ensureDownloaded(_:)` sees the same
    /// `CancellationError` regardless of which phase (network vs.
    /// SHA-256 verify/move) the cancellation landed in.
    fileprivate nonisolated func handleDidComplete(task: URLSessionTask, error: Error?) {
        guard let error, let variantID = task.taskDescription else { return }
        let mappedError: Error = (error as? URLError)?.code == .cancelled ? CancellationError() : error
        Task { @MainActor [weak self] in
            self?.finish(variantID: variantID, result: .failure(mappedError))
        }
    }
}

/// Holds `ModelDownloadManager` weakly as `URLSession`'s delegate — see
/// `ModelDownloadManager`'s doc for why conforming directly would retain it
/// permanently once a download touches `session`.
private final class DownloadDelegateProxy: NSObject, URLSessionDownloadDelegate {
    private weak var target: ModelDownloadManager?

    init(target: ModelDownloadManager) {
        self.target = target
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        target?.handleDidWriteData(
            downloadTask: downloadTask, totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        target?.handleDidFinishDownloading(downloadTask: downloadTask, location: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        target?.handleDidComplete(task: task, error: error)
    }
}
