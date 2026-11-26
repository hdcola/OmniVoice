import Combine
import Foundation
import os

/// Speaker identification: labels each finished row of a live transcription
/// with who said it (“Speaker A”, “Speaker B”, or a remembered name).
///
/// `RecordingSession` calls it from a few places only:
/// - transcription starts: `beginSession()`
/// - every mixed audio chunk: `push(_:)` (audio thread, near-zero cost)
/// - a VAD pause: `markUtteranceBoundary()`
/// - every finished row: `closeSegment { key in ... }`
/// - a speaker change it hears mid-row: `onSpeakerChange` (RecordingSession ends the row)
/// - a rename that must reach History: `onRenamed`
///
/// Embedding and clustering run on a private serial queue and **never block
/// recognition or translation**; the label lands on the main thread tens of
/// milliseconds later. When switched off, no model is loaded, no audio is
/// buffered and `push` returns immediately.
public final class SpeakerTagger: ObservableObject, @unchecked Sendable {
    public static let shared = SpeakerTagger()

    public enum Status: Equatable {
        case off
        case downloading
        case loading
        case ready
        case failed(String)
    }

    public static let enabledKey = "org.hdcola.omnivoice.speakerID.enabled"
    public static let thresholdKey = "org.hdcola.omnivoice.speakerID.threshold"
    public static let defaultThreshold: Double = 0.6
    /// Voice model: 3D-Speaker CAM++ (Chinese + English), about 28 MB.
    public static let modelFileName = "speaker-campplus-zh-en.onnx"
    static let modelDownloadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!

    /// The switch shown in the menu bar popover, the Caption panel and Settings.
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? load() : unload()
        }
    }

    /// Similarity threshold (adjustable in Settings): higher splits one person
    /// into two more easily, lower merges two people into one more easily.
    @Published public var threshold: Double {
        didSet {
            UserDefaults.standard.set(threshold, forKey: Self.thresholdKey)
            let t = Float(threshold)
            queue.async {
                self.clusterer.threshold = t
                self.clusterer.seedThreshold = SpeakerClusterer.seedThreshold(for: t)
                self.changeThreshold = SpeakerClusterer.seedThreshold(for: t)
            }
        }
    }

    @Published public private(set) var status: Status = .off
    /// How many people have been heard in this transcription.
    @Published public private(set) var speakerCount = 0

    // Accessed on `queue` only.
    private let queue = DispatchQueue(label: "org.hdcola.omnivoice.speakerid", qos: .utility)
    private var extractor: SpeakerEmbeddingExtractor?
    private var clusterer: SpeakerClusterer
    /// Voiced audio of the row in progress.
    private var buffer: [Float] = []
    /// Rows already ended (by a pause or a speaker change) but not yet labeled, oldest first.
    private var completed: [[Float]] = []
    /// Speaker-change detection: every `changeWindowSeconds` of voiced audio is
    /// embedded and compared with the row so far.
    private var window: [Float] = []
    private var rowEmbeddingSum: [Float]?
    /// Below this similarity to the row so far, the window counts as a new speaker.
    private var changeThreshold: Float = SpeakerClusterer.seedThreshold(for: Float(SpeakerTagger.defaultThreshold))
    private var generation = 0

    // `push` runs on the audio thread and only reads this locked flag.
    private let activeLock = NSLock()
    private var _active = false
    private var active: Bool {
        get { activeLock.lock(); defer { activeLock.unlock() }; return _active }
        set { activeLock.lock(); _active = newValue; activeLock.unlock() }
    }

    /// Minimum voiced audio in a row before identifying; very short rows
    /// (“mm”, “yes”) stay unlabeled rather than risk a wrong label.
    static let minVoicedSeconds: Double = 0.8
    /// Only the last this-many seconds of voiced audio are kept, so long rows stay cheap.
    static let maxVoicedSeconds: Double = 12
    /// Chunks quieter than this (dBFS) count as silence and are ignored.
    static let voicedDBFS: Float = -45

    // Names and remembered voices (main thread only).
    /// Names given in this transcription (key → name). Unnamed speakers are
    /// absent and show as “Speaker A”.
    @Published public private(set) var names: [String: String] = [:]
    /// Speakers in this transcription whose voice is remembered (key → profile id).
    @Published public private(set) var rememberedKeys: [String: UUID] = [:]
    /// All remembered voices (removable in Settings).
    @Published public private(set) var profiles: [SpeakerProfile] = []
    /// Called on rename with (old display name, new display name) so History can follow.
    public var onRenamed: ((String, String) -> Void)?
    /// Called (on this feature's own queue) when a different voice is heard
    /// mid-row, so the row can end there instead of mixing two people.
    public var onSpeakerChange: (() -> Void)?
    /// In testing, 1.5 s windows scored ≥ 0.55 for the same person and a
    /// median of 0.23 across a speaker change.
    static let changeWindowSeconds: Double = 1.5
    private let profileStore: SpeakerProfileStore

    // Cluster numbering (`queue` only).
    /// Cluster index → key. Remembered voices are “P-xxxxxxxx”; new voices get
    /// “A”, “B”, … in order of appearance.
    private var keys: [String] = []
    private var letterCount = 0
    private var heard: Set<String> = []

    init(defaults: UserDefaults = .standard, profileStore: SpeakerProfileStore = SpeakerProfileStore()) {
        let stored = defaults.object(forKey: Self.thresholdKey) as? Double
        let t = stored ?? Self.defaultThreshold
        threshold = t
        clusterer = SpeakerClusterer(threshold: Float(t))
        self.profileStore = profileStore
        profiles = profileStore.load()
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if isEnabled { load() }
    }

    public static var modelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OmniVoice/Models/\(modelFileName)")
    }

    // MARK: - Called by RecordingSession

    /// A new transcription: numbering and names restart at Speaker A, and
    /// remembered voices are seeded so they are recognized from their first
    /// row. Main thread only.
    public func beginSession() {
        var seededNames: [String: String] = [:]
        var seededRemembered: [String: UUID] = [:]
        let seeds = profiles.map { p -> (String, [Float]) in
            let key = Self.profileKey(p.id)
            seededNames[key] = p.name
            seededRemembered[key] = p.id
            return (key, p.embedding)
        }
        names = seededNames
        rememberedKeys = seededRemembered
        speakerCount = 0
        queue.async {
            self.generation += 1
            self.resetRow()
            self.completed.removeAll()
            self.clusterer.reset()
            self.keys = []
            self.letterCount = 0
            self.heard = []
            for (key, embedding) in seeds {
                self.clusterer.seed(embedding)
                self.keys.append(key)
            }
        }
    }

    /// A 16 kHz mono chunk from `AudioMixer`. Returns immediately when off.
    public func push(_ samples: [Float]) {
        guard active, !samples.isEmpty, Self.rmsDBFS(samples) >= Self.voicedDBFS else { return }
        queue.async {
            self.buffer.append(contentsOf: samples)
            let cap = Int(Self.maxVoicedSeconds * 16_000)
            if self.buffer.count > cap { self.buffer.removeFirst(self.buffer.count - cap) }
            self.window.append(contentsOf: samples)
            if Double(self.window.count) / 16_000 >= Self.changeWindowSeconds { self.checkSpeakerChange() }
        }
    }

    /// A VAD pause: keep this row's audio until its `closeSegment` arrives, so
    /// a late `closeSegment` doesn't pick up the next speaker's first words.
    public func markUtteranceBoundary() {
        guard active else { return }
        queue.async { self.finishRow() }
    }

    /// `queue` only.
    private func finishRow() {
        if !buffer.isEmpty { completed.append(buffer) }
        resetRow()
    }

    private func resetRow() {
        buffer.removeAll(keepingCapacity: true)
        window.removeAll(keepingCapacity: true)
        rowEmbeddingSum = nil
    }

    /// `queue` only: if this window sounds unlike the row so far, end the row
    /// before it and ask RecordingSession to start a new one.
    private func checkSpeakerChange() {
        let win = window
        window.removeAll(keepingCapacity: true)
        guard let extractor, let e = extractor.embed(win) else { return }
        let en = SpeakerClusterer.normalized(e)
        guard !en.isEmpty else { return }
        guard let sum = rowEmbeddingSum else { rowEmbeddingSum = en; return }
        let sim = SpeakerClusterer.dot(en, SpeakerClusterer.normalized(sum))
        if sim < changeThreshold {
            Self.log.debug("speaker: change detected (similarity \(sim, format: .fixed(precision: 2)))")
            let before = Array(buffer.dropLast(min(win.count, buffer.count)))
            if !before.isEmpty { completed.append(before) }
            buffer = win
            rowEmbeddingSum = en
            onSpeakerChange?()
        } else {
            rowEmbeddingSum = zip(sum, en).map { $0 + $1 }
        }
    }

    /// A row finished. `completion` runs on the main thread with the speaker's
    /// key (show it via `displayName(for:)`); it is not called when the row is
    /// too short or the feature is off.
    public func closeSegment(_ completion: @escaping @MainActor (String?) -> Void) {
        guard active else { return }
        queue.async {
            // Prefer the rows already ended by a pause or a speaker change; an
            // engine that ignores pauses has none, so fall back to the current
            // row. Of several, use the longest, so two voices aren't mixed.
            let samples: [Float]
            if self.completed.isEmpty {
                samples = self.buffer
                self.resetRow()
            } else {
                let longest = self.completed.max(by: { $0.count < $1.count }) ?? []
                samples = Double(longest.count) / 16_000 >= Self.minVoicedSeconds
                    ? longest : self.completed.flatMap { $0 }
                self.completed.removeAll()
            }
            let gen = self.generation
            let seconds = Double(samples.count) / 16_000
            guard let extractor = self.extractor,
                  seconds >= Self.minVoicedSeconds,
                  let embedding = extractor.embed(samples),
                  gen == self.generation
            else {
                Self.log.debug("speaker: skipped row (\(seconds, format: .fixed(precision: 2)) s voiced)")
                return
            }
            let index = self.clusterer.assign(embedding, seconds: seconds)
            if let sim = self.clusterer.lastBestSeedSimilarity {
                Self.log.debug("speaker: best remembered-voice similarity \(sim, format: .fixed(precision: 3))")
            }
            if index >= self.keys.count {
                self.keys.append(SpeakerClusterer.letter(for: self.letterCount))
                self.letterCount += 1
            }
            let key = self.keys[index]
            self.heard.insert(key)
            let count = self.heard.count
            DispatchQueue.main.async {
                self.speakerCount = count
                MainActor.assumeIsolated { completion(key) }
            }
        }
    }

    // MARK: - Names and remembered voices (UI, main thread only)

    /// The given name, or “Speaker A”.
    public func displayName(for key: String) -> String {
        names[key] ?? String(localized: "Speaker \(key)")
    }

    public func isRemembered(_ key: String) -> Bool { rememberedKeys[key] != nil }

    /// Renames a speaker; an empty name restores “Speaker A”. If the voice is
    /// remembered, the remembered name changes too.
    public func rename(_ key: String, to newName: String) {
        let old = displayName(for: key)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, rememberedKeys[key] == nil { names.removeValue(forKey: key) }
        else if !trimmed.isEmpty { names[key] = trimmed }
        if let id = rememberedKeys[key], let i = profiles.firstIndex(where: { $0.id == id }), !trimmed.isEmpty {
            profiles[i].name = trimmed
            profiles[i].updatedAt = .now
            profileStore.save(profiles)
        }
        let new = displayName(for: key)
        if new != old { onRenamed?(old, new) }
        // Renamed to a remembered name (e.g. a remembered voice that wasn't
        // recognized this time): merge into that voice, which both labels this
        // speaker and makes the remembered voice more accurate.
        if rememberedKeys[key] == nil, !trimmed.isEmpty, profiles.contains(where: { $0.name == trimmed }) {
            remember(key)
        }
    }

    /// Remembers this speaker's voice and name for future transcriptions.
    /// Needs a name first (returns false otherwise). A remembered voice with
    /// the same name gets this one added instead of a duplicate.
    ///
    /// Instead of averaging every row of this speaker, only the dominant voice
    /// is kept (a few rows from somebody else are dropped), and each remember
    /// is stored as its own sample so Settings can flag one that doesn't match.
    @discardableResult
    public func remember(_ key: String) -> Bool {
        guard let name = names[key] else { return false }
        let linked = rememberedKeys[key]
        let sameVoice = self.sameVoice
        queue.async {
            guard let index = self.keys.firstIndex(of: key) else { return }
            var heard = self.clusterer.samples(at: index)
            if heard.isEmpty, let c = self.clusterer.centroid(at: index) { heard = [SpeakerSample(embedding: c, seconds: 0)] }
            let main = SpeakerVoice.dominant(heard, sameVoice: sameVoice)
            guard !main.embedding.isEmpty else { return }
            let seconds = main.included.reduce(0.0) { $0 + heard[$1].seconds }
            Self.log.debug("speaker: remembering \(main.included.count) of \(heard.count) rows")
            let sample = SpeakerSample(embedding: main.embedding, seconds: seconds)
            DispatchQueue.main.async {
                var list = self.profiles
                let id: UUID
                if let i = list.firstIndex(where: { $0.id == linked }) ?? list.firstIndex(where: { $0.name == name }) {
                    list[i].samples = list[i].allSamples + [sample]
                    list[i].refreshEmbedding(sameVoice: sameVoice)
                    list[i].name = name
                    list[i].updatedAt = .now
                    id = list[i].id
                } else {
                    id = UUID()
                    list.append(SpeakerProfile(id: id, name: name, embedding: sample.embedding, updatedAt: .now, samples: [sample]))
                }
                self.saveProfiles(list)
                self.rememberedKeys[key] = id
            }
        }
        return true
    }

    /// Forgets a remembered voice (Settings). Names already shown stay.
    public func forget(_ profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
        profileStore.save(profiles)
        for (k, v) in rememberedKeys where v == profileID { rememberedKeys.removeValue(forKey: k) }
    }

    // MARK: - Tidying up remembered voices (Settings, main thread only)

    /// Samples of one name that disagree, and names that sound alike.
    public var profileIssues: [SpeakerProfileIssue] {
        SpeakerProfileIssue.find(in: profiles, threshold: Float(threshold))
    }

    private var sameVoice: Float { SpeakerClusterer.seedThreshold(for: Float(threshold)) }

    private func saveProfiles(_ list: [SpeakerProfile]) {
        profiles = list
        profileStore.save(list)
    }

    /// Merges `from` into `into` (keeping `into`'s name and both sets of samples).
    public func mergeProfile(_ from: UUID, into: UUID) {
        guard from != into, let f = profiles.first(where: { $0.id == from }),
              let i = profiles.firstIndex(where: { $0.id == into }) else { return }
        var list = profiles
        list[i].samples = list[i].allSamples + f.allSamples
        list[i].distinctFrom = Array(Set((list[i].distinctFrom ?? []) + (f.distinctFrom ?? [])).subtracting([from, into]))
        list[i].refreshEmbedding(sameVoice: sameVoice)
        list[i].updatedAt = .now
        let name = list[i].name
        list.removeAll { $0.id == from }
        saveProfiles(list)
        for (k, v) in rememberedKeys where v == from {
            rememberedKeys[k] = into
            names[k] = name
        }
    }

    /// Removes one sample (e.g. one that picked up somebody else). The last
    /// sample can't be removed this way; use Forget.
    public func removeSample(of profileID: UUID, at index: Int) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var all = profiles[i].allSamples
        guard all.count > 1, all.indices.contains(index) else { return }
        all.remove(at: index)
        var list = profiles
        list[i].samples = all
        list[i].refreshEmbedding(sameVoice: sameVoice)
        list[i].updatedAt = .now
        saveProfiles(list)
    }

    /// Moves one sample out into another name (it was somebody else).
    public func splitSample(of profileID: UUID, at index: Int, as newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var all = profiles[i].allSamples
        guard all.count > 1, all.indices.contains(index) else { return }
        let moved = all.remove(at: index)
        var list = profiles
        list[i].samples = all
        list[i].refreshEmbedding(sameVoice: sameVoice)
        list[i].updatedAt = .now
        if let j = list.firstIndex(where: { $0.name == name }) {
            list[j].samples = list[j].allSamples + [moved]
            list[j].refreshEmbedding(sameVoice: sameVoice)
            list[j].updatedAt = .now
        } else {
            list.append(SpeakerProfile(id: UUID(), name: name, embedding: moved.embedding, updatedAt: .now, samples: [moved]))
        }
        saveProfiles(list)
    }

    /// The user confirmed these two are different people: stop suggesting a merge.
    public func markDistinct(_ a: UUID, _ b: UUID) {
        var list = profiles
        if let i = list.firstIndex(where: { $0.id == a }) {
            list[i].distinctFrom = Array(Set((list[i].distinctFrom ?? []) + [b]))
        }
        saveProfiles(list)
    }

    /// Renames a remembered voice; renaming to another remembered name merges them.
    public func renameProfile(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let other = profiles.first(where: { $0.name == name && $0.id != id }) {
            mergeProfile(id, into: other.id)
            return
        }
        var list = profiles
        list[i].name = name
        list[i].updatedAt = .now
        saveProfiles(list)
        for (k, v) in rememberedKeys where v == id { names[k] = name }
    }

    private static let log = Logger(subsystem: "org.hdcola.omnivoice", category: "speakerid")

    static func profileKey(_ id: UUID) -> String { "P-" + id.uuidString.prefix(8) }

    // MARK: - Model loading

    private func load() {
        setStatus(.loading)
        queue.async {
            guard self.extractor == nil else { self.active = true; self.setStatus(.ready); return }
            let url = Self.modelURL
            if !FileManager.default.fileExists(atPath: url.path) {
                self.setStatus(.downloading)
                if let error = Self.download(to: url) {
                    self.fail(String(localized: "Couldn’t download the voice model: \(error)"))
                    return
                }
            }
            guard let ex = SpeakerEmbeddingExtractor(modelPath: url.path) else {
                self.fail(String(localized: "Couldn’t load the voice model"))
                return
            }
            self.extractor = ex
            self.resetRow()
            self.completed.removeAll()
            self.active = true
            self.setStatus(.ready)
        }
    }

    /// Main thread only (`isEnabled`'s didSet).
    private func unload() {
        active = false
        status = .off
        queue.async {
            self.extractor = nil
            self.resetRow()
            self.completed.removeAll()
        }
    }

    /// On failure: switch the feature off and keep the message for the UI.
    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.isEnabled = false
            self.status = .failed(message)
        }
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async {
            // After switching off, a late downloading/loading/ready must not overwrite .off.
            if !self.isEnabled, s == .downloading || s == .loading || s == .ready { return }
            self.status = s
        }
    }

    /// Synchronous download (background queue only). Returns nil on success, else an error description.
    private static func download(to url: URL) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var failure: String?
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let task = URLSession.shared.downloadTask(with: modelDownloadURL) { tmp, response, error in
            defer { sem.signal() }
            if let error { failure = error.localizedDescription; return }
            guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                failure = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"; return
            }
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
            } catch { failure = error.localizedDescription }
        }
        task.resume()
        sem.wait()
        return failure
    }

    static func rmsDBFS(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-9))
    }
}
