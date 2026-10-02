import AppKit
import AVFoundation
import Combine
import OmniVoiceCore
import SwiftUI

/// Push-to-talk dictation: hold (or tap) a modifier key anywhere, speak, and
/// the text is typed into the focused app. Owns the key monitor, the
/// `DictationSession` doing the recognition, and the HUD; `AppDelegate`
/// constructs it at launch so the key works before any window is opened.
@MainActor
final class DictationController: ObservableObject {
    static let enabledKey = "org.hdcola.omnivoice.dictation.enabled"
    static let triggerKeyKey = "org.hdcola.omnivoice.dictation.triggerKey"
    static let modeKey = "org.hdcola.omnivoice.dictation.mode"

    /// Off until the user opts in: it needs the Input Monitoring permission,
    /// which launch should never ask for out of the blue.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                requestPermissions()
                warmUp()
            }
            updateMonitor()
        }
    }

    @Published var triggerKey: DictationTriggerKey {
        didSet {
            UserDefaults.standard.set(triggerKey.rawValue, forKey: Self.triggerKeyKey)
            monitor.triggerKey = triggerKey
            // The key a running dictation is waiting on just changed.
            cancelActiveDictation()
        }
    }

    @Published var mode: DictationTriggerMachine.Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            machine.mode = mode
            cancelActiveDictation()
        }
    }

    /// Something the HUD should tell the user instead of listening.
    @Published private(set) var notice: String?
    /// What the background warm-up is doing, for Settings — nil when idle.
    @Published private(set) var warmupMessage: String?

    let dictation: DictationSession

    private let monitor = DictationKeyMonitor()
    private var machine: DictationTriggerMachine
    private let hud = DictationHUDPanel()
    private var noticeTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    /// True while a finished dictation is being pasted — the clipboard is
    /// borrowed until it is put back, so the next one waits its turn.
    private var isInserting = false
    private var errorObserver: AnyCancellable?
    private let languageCode: () -> String?
    private let deviceID: () -> String?

    /// `languageCode`/`deviceID` are read at the moment a dictation starts,
    /// so it follows whatever 转录 is set to in Settings.
    init(dictation: DictationSession, languageCode: @escaping () -> String?, deviceID: @escaping () -> String?) {
        self.dictation = dictation
        self.languageCode = languageCode
        self.deviceID = deviceID
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedKey = defaults.string(forKey: Self.triggerKeyKey).flatMap(DictationTriggerKey.init) ?? .rightOption
        let storedMode = defaults.string(forKey: Self.modeKey).flatMap(DictationTriggerMachine.Mode.init) ?? .hold
        triggerKey = storedKey
        mode = storedMode
        machine = DictationTriggerMachine(mode: storedMode)
        monitor.triggerKey = storedKey

        hud.contentView = NSHostingView(rootView: DictationHUDView(controller: self, dictation: dictation))

        monitor.onKeyDown = { [weak self] time in
            guard let self else { return }
            perform(machine.keyDown(at: time))
        }
        monitor.onKeyUp = { [weak self] time in
            guard let self else { return }
            perform(machine.keyUp(at: time))
        }
        monitor.onOtherKey = { [weak self] in
            guard let self else { return }
            perform(machine.otherKeyPressed())
        }
        monitor.onEscape = { [weak self] in
            guard let self else { return }
            dismissNotice()
            perform(machine.escapePressed())
        }

        // A start that fails (no microphone permission, unsupported language)
        // never reaches `finish`, so the failure is what ends it.
        errorObserver = dictation.$errorMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.machine.reset()
                self?.showNotice(message)
            }
        updateMonitor()
        if isEnabled { warmUp() }
    }

    var hasInputMonitoringPermission: Bool { DoubleCopyMonitor.hasPermission }

    // MARK: - Flow

    private func perform(_ action: DictationTriggerMachine.Action) {
        switch action {
        case .none:
            break
        case .start:
            start()
        case .finish:
            Task { await finish() }
        case .cancel:
            Task {
                await dictation.cancel()
                hideHUD()
            }
        }
    }

    private func start() {
        // The previous dictation is still being typed out.
        guard !dictation.isActive, !isInserting else {
            machine.reset()
            return
        }
        noticeTask?.cancel()
        notice = nil
        hud.positionOnActiveScreen()
        hud.orderFrontRegardless()
        let deviceID = deviceID()
        dictation.start(
            languageCode: languageCode(),
            deviceID: deviceID == AudioInputDevice.noneID ? nil : deviceID
        )
    }

    private func finish() async {
        let text = await dictation.finish()
        guard notice == nil else { return }
        guard !text.isEmpty else {
            hideHUD()
            return
        }
        hideHUD()
        isInserting = true
        let outcome = await DictationTextInserter.insert(text)
        isInserting = false
        if case .copiedOnly(let reason) = outcome {
            showNotice(reason)
        }
    }

    // MARK: - HUD

    private func showNotice(_ message: String) {
        notice = message
        hud.positionOnActiveScreen()
        hud.orderFrontRegardless()
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
            self?.hideHUD()
        }
    }

    /// Esc closes a notice without waiting out its timer.
    private func dismissNotice() {
        guard notice != nil else { return }
        noticeTask?.cancel()
        notice = nil
        hideHUD()
    }

    private func hideHUD() {
        guard notice == nil else { return }
        hud.orderOut(nil)
    }

    // MARK: - Setup

    /// Gets the slow first-use work out of the way while the user is still in
    /// Settings (or at launch): the system recognizer's language assets, which
    /// are also what a dictation falls back to when no local model is loaded.
    /// The microphone is deliberately not opened — that would flash the
    /// system's recording indicator for nothing. A failure here is left for
    /// the first dictation to report.
    private func warmUp() {
        warmupTask?.cancel()
        let code = languageCode() ?? Locale.current.identifier(.bcp47)
        warmupTask = Task { [weak self] in
            do {
                try await SystemTranscriptionProvider.prepareAssets(languageCode: code) {
                    Task { @MainActor in self?.warmupMessage = "正在下载语言识别资源，完成后首次听写会更快…" }
                }
            } catch {}
            guard !Task.isCancelled else { return }
            self?.warmupMessage = nil
        }
    }

    private func updateMonitor() {
        if isEnabled {
            monitor.start()
        } else {
            monitor.stop()
            // Nothing can end a dictation once the monitor is gone — no
            // trigger key, no Esc — so end it here rather than leave the
            // microphone and the HUD up.
            cancelActiveDictation()
        }
    }

    private func cancelActiveDictation() {
        machine.reset()
        dismissNotice()
        guard dictation.isActive else { return }
        Task {
            await dictation.cancel()
            hideHUD()
        }
    }

    /// Only the user switching it on asks: the key monitor needs Input
    /// Monitoring, pasting needs Accessibility, and recognition the
    /// microphone.
    private func requestPermissions() {
        if !DoubleCopyMonitor.hasPermission { DoubleCopyMonitor.requestPermission() }
        if !SelectedTextReader.isAccessibilityTrusted { SelectedTextReader.requestAccessibilityPermission() }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
}
