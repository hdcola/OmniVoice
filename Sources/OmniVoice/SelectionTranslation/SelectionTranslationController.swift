import AppKit
import Combine
import OmniVoiceCore
import SwiftUI

/// Owns the selection translation feature's app-side pieces — the panel,
/// its global hot keys, and the ⌥A/⌥S flows that feed `SelectionTranslator`
/// — the same split `AppDelegate`/`RecordingSession` use: engine state and
/// logic in Core, AppKit glue here. Constructed once by `AppDelegate` at
/// launch, so the hot keys work before any menu/window is ever opened.
@MainActor
final class SelectionTranslationController: ObservableObject {
    /// Something the panel should tell the user about how the text got
    /// there (or didn't), shown above the result.
    enum Notice: Equatable {
        /// ⌥A couldn't read the selection — no Accessibility permission.
        case accessibilityNeeded
        /// ⌥S can't freeze the screen — no Screen Recording permission.
        case screenRecordingNeeded
        case nothingRecognized
        case captureFailed
    }

    let translator: SelectionTranslator
    @Published private(set) var notice: Notice?
    /// Bumped whenever the source pane should take focus and select all —
    /// see `PanelTextView.focusRequest`.
    @Published private(set) var sourceFocusRequest = 0
    @Published private(set) var shortcuts: [GlobalShortcutAction: GlobalShortcut] = [:]
    /// While Settings is recording a new combination every hot key is
    /// released, so pressing the current one records it instead of
    /// summoning the panel.
    @Published var isRecordingShortcut = false {
        didSet { hotKeys.values.forEach { $0.setSuspended(isRecordingShortcut) } }
    }

    /// Whether pressing ⌘C twice in quick succession translates the copied
    /// text. Off until the user opts in (onboarding or Settings), because it
    /// needs the Input Monitoring permission.
    @Published var isDoubleCopyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDoubleCopyEnabled, forKey: Self.doubleCopyDefaultsKey)
            // Only the user switching it on asks for the permission: launch
            // never shows the "receive keystrokes from any application"
            // prompt out of the blue.
            if isDoubleCopyEnabled, !DoubleCopyMonitor.hasPermission { DoubleCopyMonitor.requestPermission() }
            updateDoubleCopyMonitor()
        }
    }

    static let doubleCopyDefaultsKey = "doubleCopyTranslateEnabled"

    private let panel = SelectionTranslationPanel()
    private var doubleCopyMonitor: DoubleCopyMonitor?
    private var hotKeys: [GlobalShortcutAction: GlobalHotKey] = [:]
    private var isReadingSelection = false
    private var isCapturing = false
    private var resignKeyObserver: NSObjectProtocol?

    init(translator: SelectionTranslator) {
        self.translator = translator
        isDoubleCopyEnabled = UserDefaults.standard.object(forKey: Self.doubleCopyDefaultsKey) as? Bool ?? false
        panel.contentView = NSHostingView(rootView: SelectionTranslationView(controller: self, translator: translator))
        panel.positionOnActiveScreen()
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfFocusLeft() }
        }

        for action in GlobalShortcutAction.allCases {
            let shortcut = Self.storedShortcut(for: action)
            let hotKey = GlobalHotKey(shortcut: shortcut) { [weak self] in self?.perform(action) }
            hotKeys[action] = hotKey
            // A stored/default combination the system refused (another app
            // holds it) reads as unset rather than claiming a hot key that
            // does nothing.
            if let registered = hotKey?.shortcut { shortcuts[action] = registered }
        }

        doubleCopyMonitor = DoubleCopyMonitor { [weak self] in self?.translateCopiedText() }
        updateDoubleCopyMonitor()
    }

    deinit {
        // Block-based observers aren't removed automatically. The
        // controller lives as long as the app today; this keeps it honest
        // if that ever changes.
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    var isPanelVisible: Bool { panel.isVisible }

    // MARK: - Shortcuts

    func perform(_ action: GlobalShortcutAction) {
        switch action {
        case .translateSelection: toggleWithSelection()
        case .captureText: captureAndTranslate()
        }
    }

    /// Returns an error message when `shortcut` can't be used for `action`.
    func setShortcut(_ shortcut: GlobalShortcut?, for action: GlobalShortcutAction) -> String? {
        if let shortcut, let other = shortcuts.first(where: { $0.key != action && $0.value == shortcut })?.key {
            return "\(shortcut.displayText) 已用于「\(other.title)」"
        }
        guard let hotKey = hotKeys[action] else { return "无法注册全局快捷键" }
        guard hotKey.update(to: shortcut) else {
            return "\(shortcut?.displayText ?? "") 已被系统或其他应用占用"
        }
        shortcuts[action] = shortcut
        let defaults = UserDefaults.standard
        if shortcut == action.defaultShortcut {
            defaults.removeObject(forKey: action.defaultsKey)
        } else {
            // Empty data means "deliberately unset" — distinct from a
            // missing key, which means "use the default".
            defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: action.defaultsKey)
        }
        return nil
    }

    private static func storedShortcut(for action: GlobalShortcutAction) -> GlobalShortcut? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return action.defaultShortcut }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }

    // MARK: - Panel

    /// The menu bar's entry point: shows the panel as it was left, without
    /// reading any selection.
    func showPanel() {
        guard !panel.isVisible else { return }
        panel.positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        sourceFocusRequest += 1
    }

    func hidePanel() {
        panel.orderOut(nil)
    }

    /// Clicking back into another app hides the panel, like Cida's — but not
    /// while Apple Translation's language-download sheet (which takes key
    /// status from the panel) is up.
    private func hideIfFocusLeft() {
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isVisible, !panel.isKeyWindow, panel.attachedSheet == nil else { return }
            if let key = NSApp.keyWindow, key.sheetParent === panel { return }
            panel.orderOut(nil)
        }
    }

    /// ⌥A: hides a visible panel; otherwise reads the frontmost app's
    /// selection first, so a new one appears in the panel already being
    /// translated. The translation keeps running while the panel is hidden,
    /// and an unchanged selection keeps its result (`SelectionTranslator.load(_:)`).
    private func toggleWithSelection() {
        guard !isCapturing else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !isReadingSelection else { return }
        isReadingSelection = true
        Task { @MainActor in
            let trusted = SelectedTextReader.isAccessibilityTrusted
            let selection = trusted ? await SelectedTextReader.read() : nil
            isReadingSelection = false
            notice = trusted ? nil : .accessibilityNeeded
            if let selection { translator.load(selection) }
            showPanel()
        }
    }

    private func updateDoubleCopyMonitor() {
        if isDoubleCopyEnabled {
            doubleCopyMonitor?.start()
        } else {
            doubleCopyMonitor?.stop()
        }
    }

    /// ⌘C ⌘C: the application has just copied the selection, so the text is
    /// on the pasteboard — read it, leave the pasteboard alone (the user
    /// asked for that copy), and show the panel translating it.
    private func translateCopiedText() {
        guard !isCapturing, !isReadingSelection else { return }
        isReadingSelection = true
        Task { @MainActor in
            try? await Task.sleep(for: DoubleCopyMonitor.copySettleDelay)
            let text = PasteboardSelectionCopier.copiedText(on: .general)
            isReadingSelection = false
            guard let text else { return }
            notice = nil
            translator.load(text)
            showPanel()
        }
    }

    /// ⌥S: freezes the screen under the pointer, lets the user frame some
    /// text, recognizes it on-device, and shows the panel translating it.
    private func captureAndTranslate() {
        guard !isCapturing, !isReadingSelection else { return }
        panel.orderOut(nil)
        guard ScreenFreezer.hasPermission else {
            ScreenFreezer.requestPermission()
            notice = .screenRecordingNeeded
            showPanel()
            return
        }
        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
                return
            }
            let frozen: CGImage
            do {
                frozen = try await ScreenFreezer.capture(screen)
            } catch {
                notice = .captureFailed
                showPanel()
                return
            }
            guard let region = await CaptureOverlay.selectRegion(of: frozen, on: screen) else { return }
            let recognizedText = try? await ScreenTextRecognizer.recognizeText(
                in: region, languageCodes: [translator.myLanguageCode, translator.foreignLanguageCode]
            )
            if let recognized = recognizedText {
                notice = nil
                translator.load(recognized)
            } else {
                notice = .nothingRecognized
            }
            showPanel()
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func openAccessibilitySettings() {
        SelectedTextReader.requestAccessibilityPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openInputMonitoringSettings() {
        DoubleCopyMonitor.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
