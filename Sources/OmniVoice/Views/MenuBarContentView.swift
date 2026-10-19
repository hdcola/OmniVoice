import AppKit
import OmniVoiceCore
import SwiftData
import SwiftUI

/// Content of the menu bar popover (`MenuBarExtra` in `.window` style) —
/// OmniVoice has no Dock icon (`LSUIElement`, see `Resources/Info.plist`),
/// so this is the app's primary entry point and, with the 字幕悬浮窗
/// hidden, the only place that shows whether transcription is running, hears
/// anything, or failed. Grouped by task: status and start/stop, the
/// languages and audio source, Quick Translate, recent transcripts, then the
/// windows.
///
/// A `.window` popover has no menu-style arrow-key navigation, so the main
/// actions carry key equivalents (⏎ start/stop, ⌘, Settings, ⌘Q quit) and
/// Esc closes it.
struct MenuBarContentView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var appDelegate: AppDelegate
    @EnvironmentObject private var settingsNavigation: SettingsNavigationState
    /// Observed (not just reached through `appDelegate`) so the key caps
    /// below pick up a shortcut re-recorded in Settings.
    @EnvironmentObject private var selectionController: SelectionTranslationController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    /// Same instance `SettingsView`/`ModelManagementView` observe — see
    /// `SettingsView`'s own `downloadManager` doc for why this is passed in
    /// explicitly rather than defaulted to `.shared`. Only used here to show
    /// download progress on the "模型库…" row (see `modelLibraryRow`) so a
    /// download started in Settings stays visible after it's closed.
    @ObservedObject private var downloadManager: ModelDownloadManager

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcriptionSection
            PopoverDivider()
            languageAndAudioSection
            PopoverDivider()
            quickTranslateSection
            if appDelegate.modelContainer != nil {
                RecentTranscriptsSection(open: openTranscript)
            }
            PopoverDivider()
            windowsSection
        }
        .padding(.vertical, 6)
        .frame(width: 320)
        // Device list can change between opens (a USB mic plugged in,
        // AirPods connected, ...) — cheap enough to refresh every time.
        // Session/panel construction itself happens in
        // `AppDelegate.applicationDidFinishLaunching`, not here — see that
        // file's doc for why.
        .onAppear { session.refreshDevices() }
        .onExitCommand { dismiss() }
    }

    // MARK: - Status and start/stop

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            ForEach(PermissionIssue.current(in: session)) { issue in
                permissionNotice(issue)
            }
            // Text that adds to the status row: an engine loading, a start
            // that failed, a model not downloaded.
            if !session.isStatusMessageRoutine {
                Text(session.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            transcriptionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// "● 转录中 ▁▃▅ 00:12:48" while running; "就绪 · 模型已就绪" at rest.
    private var statusRow: some View {
        HStack(spacing: 8) {
            if session.isStarting || session.isStopping {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(session.isRunning ? Color.red : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
            Text(statusTitle)
                .font(.system(size: 13, weight: .semibold))
            if session.isRunning && !session.isStopping {
                InputLevelBars(level: session.inputLevel)
            }
            Spacer(minLength: 0)
            if session.isRunning && !session.isStopping {
                Text(session.elapsedTimeString)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        // Stopping first: `isRunning` stays true until `stop()` has finished.
        if session.isStopping { return String(localized: "Stopping…") }
        if session.isRunning { return String(localized: "Transcribing") }
        if session.isStarting { return String(localized: "Starting…") }
        if session.isPreloadingModel { return String(localized: "Preloading…") }
        if session.usesOnDeviceModelEngine && session.hasLoadedModels {
            return String(localized: "Ready · \(session.isModelLoaded ? String(localized: "Model ready") : String(localized: "Translation model ready"))")
        }
        return String(localized: "Ready")
    }

    private func permissionNotice(_ issue: PermissionIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(.orange)
            Text(issue.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Open System Settings") {
                NSWorkspace.shared.open(issue.settingsURL)
                dismiss()
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(8)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The one prominent control: blue "开始转录" at rest, red "停止转录"
    /// while running, with the global shortcut that does the same.
    private var transcriptionButton: some View {
        Button {
            Task {
                if session.isRunning {
                    await session.stop()
                } else {
                    await session.start()
                }
            }
        } label: {
            HStack {
                Text(session.isRunning ? LocalizedStringKey("Stop Transcription") : "Start Transcription")
                Spacer(minLength: 8)
                if let shortcut = selectionController.shortcuts[.toggleTranscription] {
                    Text(shortcut.displayTokens.joined())
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.75)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(session.isRunning ? .red : .accentColor)
        .keyboardShortcut(.defaultAction)
        // `isPreloadingModel` too — `start()` itself already no-ops while a
        // preload is in flight; disabling says why nothing would happen.
        .disabled(session.isStopping || session.isStarting || session.isPreloadingModel)
    }

    // MARK: - Languages and audio source

    /// Disabled for the whole start→stop lifecycle (isSessionActive, not just
    /// isRunning): `RecordingSession.start()` reads the source language and
    /// audio settings once, at the top, to configure that recording.
    private var languageAndAudioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverSectionLabel("Language")
            LanguagePairControls(session: session)
                .font(.callout)
            PopoverSectionLabel("Audio source")
                .padding(.top, 4)
            Picker("Microphone", selection: $session.selectedDeviceID) {
                ForEach(session.inputDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .disabled(session.isSessionActive)
            // A missing Screen Recording permission (needed for this to
            // capture anything) shows as a notice in the status section above.
            Toggle(isOn: $session.includeSystemAudio) {
                Text("Include system audio")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(session.isSessionActive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Quick Translate

    /// The global shortcuts are the main way in; these tiles make the
    /// feature discoverable and show which keys to press. The panel opens as
    /// it was left rather than reading a selection — by the time a tile is
    /// clicked, the popover itself holds the focus.
    private var quickTranslateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverSectionLabel("Quick Translate")
            HStack(spacing: 8) {
                tile(String(localized: "Open Translation Panel"), shortcut: .translateSelection) {
                    selectionController.showPanel()
                }
                tile(String(localized: "Translate screenshot"), shortcut: .captureText) {
                    selectionController.perform(.captureText)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func tile(_ title: String, shortcut action: GlobalShortcutAction, perform: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            perform()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let shortcut = selectionController.shortcuts[action] {
                    KeyCap(shortcut.displayTokens.joined())
                } else {
                    KeyCap("–")
                }
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Windows

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(
                get: { appDelegate.isFloatingPanelVisible },
                set: { appDelegate.setFloatingPanelVisible($0) }
            )) {
                Text("Show Caption Panel")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)

            PopoverRow("History…") {
                // OmniVoice runs as an accessory app (`LSUIElement`, no Dock
                // icon) — opening a window without activating first creates it
                // behind whatever app currently has focus.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            }
            modelLibraryRow
            PopoverRow("Settings…", shortcut: "⌘,") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",")
            PopoverRow("Quit OmniVoice", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// "模型库…", plus an inline progress bar while a download runs —
    /// without it, closing Settings (or never having opened it) left a
    /// multi-GB download with no visible progress, easy to mistake for
    /// "stuck" (see `MenuBarLabel` for the icon-level equivalent).
    private var modelLibraryRow: some View {
        PopoverRow("Model Library…") {
            // Task 3.4 — jumps straight to Settings' "模型库" tab (see
            // `SettingsNavigationState`'s doc).
            NSApp.activate(ignoringOtherApps: true)
            settingsNavigation.openModelLibrary()
            openSettings()
        } trailing: {
            if let fraction = downloadManager.downloadProgress.values.max() {
                HStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .frame(width: 60)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .monospacedDigit()
                }
            } else if downloadManager.hasActiveDownloads {
                Text("Preparing download…")
            }
        }
    }

    private func openTranscript(_ id: UUID) {
        HistoryNavigationState.shared.requestedSessionID = id
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "history")
        dismiss()
    }
}

/// The three most recent transcripts; clicking one opens History on it.
/// Its own view so `@Query` only runs when a SwiftData container exists
/// (`SessionStore` can fail to open — see `AppDelegate.init()`).
private struct RecentTranscriptsSection: View {
    @Query(Self.descriptor) private var records: [RecordingSessionRecord]
    let open: (UUID) -> Void

    private static var descriptor: FetchDescriptor<RecordingSessionRecord> {
        var descriptor = FetchDescriptor<RecordingSessionRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 3
        return descriptor
    }

    var body: some View {
        if !records.isEmpty {
            PopoverDivider()
            VStack(alignment: .leading, spacing: 0) {
                PopoverSectionLabel("Recent transcripts")
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                ForEach(records) { record in
                    PopoverRow(verbatim: record.displayTitle()) {
                        open(record.id)
                    } trailing: {
                        Text(detail(for: record))
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// "2 hours ago · 29s" — how long only once the transcript has ended.
    private func detail(for record: RecordingSessionRecord) -> String {
        let when = record.startedAt.formatted(.relative(presentation: .named))
        guard let endedAt = record.endedAt else { return when }
        let length = Duration.seconds(max(1, endedAt.timeIntervalSince(record.startedAt)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
        return "\(when) · \(length)"
    }
}

// MARK: - Popover building blocks

private struct PopoverSectionLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct PopoverDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 2)
    }
}

/// A menu-like row: highlighted under the pointer, the action on click,
/// optional trailing detail (a shortcut, progress, a date). Closes the
/// popover first, like a menu item.
private struct PopoverRow<Trailing: View>: View {
    let title: Text
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var isHovered = false
    @Environment(\.dismiss) private var dismiss

    init(_ title: LocalizedStringKey, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.action = action
        self.trailing = trailing()
    }

    init(verbatim title: String, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: title)
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 8) {
                title
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                trailing
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.system(size: 13))
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}

extension PopoverRow where Trailing == Text {
    init(_ title: LocalizedStringKey, shortcut: String, action: @escaping () -> Void) {
        self.init(title, action: action) { Text(verbatim: shortcut) }
    }
}

extension PopoverRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(title, action: action) { EmptyView() }
    }
}

/// The menu bar's own icon — swaps `waveform` for a live download-progress
/// readout while any model is downloading, so the download stays visible
/// even with the menu closed (all `MenuBarContentView` itself can do is
/// annotate its own "模型库…" row, which is invisible until the menu is
/// opened). Kept as its own tiny view (rather than inlined into
/// `OmniVoiceApp`'s `MenuBarExtra` label closure) so it can hold its own
/// `@ObservedObject` — `OmniVoiceApp` itself isn't a `View` and can't.
struct MenuBarLabel: View {
    @ObservedObject private var downloadManager: ModelDownloadManager
    /// Not observed via `.environmentObject` — this label is `MenuBarExtra`'s
    /// `label:` closure, a sibling of (not a descendant of) the `content:`
    /// closure `MenuBarContentView`'s own `.environmentObject(session)` is
    /// attached to, so it needs its own explicit instance the same way
    /// `downloadManager` already does.
    @ObservedObject private var session: RecordingSession
    @Environment(\.openSettings) private var openSettings

    init(modelDownloadManager: ModelDownloadManager, session: RecordingSession) {
        self.downloadManager = modelDownloadManager
        self.session = session
    }

    var body: some View {
        icon
            // This label is alive for the whole app lifetime (the menu
            // content is not), so it hands the SwiftUI-only `openSettings`
            // action to code with no environment — notification clicks.
            .onAppear {
                SettingsNavigationState.shared.openSettingsWindow = { openSettings() }
            }
    }

    @ViewBuilder
    private var icon: some View {
        // Recording state wins over the download readout — otherwise a
        // download kicked off before starting to record would keep showing
        // a percentage instead of the one indicator that actually answers
        // "is this thing listening right now", which is the whole point of
        // this icon once the floating panel itself is hidden (see the
        // proposal's 3.2 "录制状态动态反馈").
        if session.isRunning {
            // `MenuBarExtra`'s label image is a template image by default
            // (`NSImage.isTemplate`), which strips `.foregroundStyle(.red)`
            // down to monochrome — `.renderingMode(.original)` opts this
            // specific image out of that so the red actually renders.
            Image(systemName: "record.circle.fill")
                .renderingMode(.original)
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: true)
        } else if let fraction = downloadManager.downloadProgress.values.max() {
            Label("\(Int((fraction * 100).rounded()))%", systemImage: "arrow.down.circle")
        } else if downloadManager.hasActiveDownloads {
            Label("Downloading", systemImage: "arrow.down.circle")
        } else {
            Image(systemName: "waveform")
        }
    }
}
