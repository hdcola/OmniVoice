import AppKit
import OmniVoiceCore
import SwiftUI

/// Content of the menu-bar dropdown — OmniVoice has no Dock icon
/// (`LSUIElement`, see `Resources/Info.plist`), so this menu is the app's
/// primary entry point for start/stop, the floating panel, history, and
/// settings.
struct MenuBarContentView: View {
    @EnvironmentObject private var session: RecordingSession
    @EnvironmentObject private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Same instance `SettingsView`/`ModelManagementView` observe — see
    /// `SettingsView`'s own `downloadManager` doc for why this is passed in
    /// explicitly rather than defaulted to `.shared`. Only used here to show
    /// download progress on the "模型管理…" row (see `modelManagementLabel`)
    /// so a download started in that window stays visible after it's closed,
    /// without needing that window open at all.
    @ObservedObject private var downloadManager: ModelDownloadManager

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        // Device list can change between menu opens (a USB mic plugged in,
        // AirPods connected, ...) — cheap enough to just refresh every time
        // the menu opens. Session/panel construction itself happens in
        // `AppDelegate.applicationDidFinishLaunching`, not here — see that
        // file's doc for why.
        Group {
            content
        }
        .onAppear {
            session.refreshDevices()
        }
    }

    @ViewBuilder
    private var content: some View {
        // Kept here alongside the floating panel's own start/stop button
        // (not removed in favor of it) — if the user has hidden the panel,
        // this is the only way to start/stop without first digging it back
        // out via "显示/隐藏悬浮窗" below.
        // The `isPreloadingModel` case matters specifically here (unlike the
        // floating panel's own start/stop button, which sits right next to
        // a "预加载模型"/"加载中…" button of its own): if the panel is
        // hidden, this dropdown is the only place the user can see *why*
        // the button below is grayed out — a plain "开始转录" that just
        // doesn't respond reads as broken, not as "busy".
        // Elapsed-time readout (proposal 3.1.E/3.2) — the floating panel
        // already shows this in its control bar, but with the panel hidden
        // this dropdown had no equivalent, even though `elapsedTimeString`'s
        // own doc says it drives both.
        if session.isRunning {
            Text(session.elapsedTimeString)
                .font(.caption.monospacedDigit())
        }

        Button(
            session.isRunning ? "停止转录"
                : (session.isStarting ? "启动中…" : (session.isPreloadingModel ? "预加载中…" : "开始转录"))
        ) {
            Task {
                if session.isRunning {
                    await session.stop()
                } else {
                    await session.start()
                }
            }
        }
        // `isPreloadingModel` too — `start()` itself already no-ops while a
        // preload is in flight (see its own guard), but without disabling
        // this button too, clicking it here felt like nothing happened
        // rather than the button visibly reflecting why.
        .disabled(session.isStopping || session.isStarting || session.isPreloadingModel)

        Button("显示/隐藏悬浮窗") {
            appDelegate.toggleFloatingPanel()
        }

        Divider()

        // Audio source — changed far less often than start/stop or the
        // language pair (which live on the floating panel instead), but
        // still frequent enough to want here rather than buried in
        // Settings. Disabled for the whole start→stop lifecycle
        // (isSessionActive, not just isRunning): `RecordingSession.start()`
        // reads these once, at the top, to configure that recording's audio
        // pipeline — changing them during setup would either race that read
        // or silently not apply to the run in progress.
        Picker("麦克风", selection: $session.selectedDeviceID) {
            ForEach(session.inputDevices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
        .disabled(session.isSessionActive)

        // A missing Screen Recording permission (needed for this toggle to
        // actually capture anything) surfaces via `session.statusMessage`
        // on the floating panel instead of a caption here — kept out of
        // this label so it doesn't wrap/get cut off, and out of this menu
        // entirely so the panel stays the one place status text lives (see
        // `FloatingTranscriptView.statusBar`).
        Toggle("包含系统声音", isOn: $session.includeSystemAudio)
            .disabled(session.isSessionActive)

        Divider()

        Button("历史记录…") {
            // OmniVoice runs as an accessory app (`LSUIElement`, no Dock
            // icon) — opening a window without activating first creates it
            // behind whatever app currently has focus, since this app never
            // becomes frontmost on its own.
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }

        Button(modelManagementLabel) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "modelManagement")
        }

        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        Button("退出 OmniVoice") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// "模型管理…", plus a live progress readout once a download is running
    /// — without this, closing that window (or never having opened it) left
    /// a multi-GB download with no visible progress anywhere in the app,
    /// easy to mistake for "stuck" (see `MenuBarLabel` for the icon-level
    /// equivalent when the menu itself isn't even open).
    private var modelManagementLabel: String {
        guard let fraction = downloadManager.downloadProgress.values.max() else {
            return downloadManager.hasActiveDownloads ? "模型管理…（准备下载…）" : "模型管理…"
        }
        return "模型管理…（下载中 \(Int((fraction * 100).rounded()))%）"
    }
}

/// The menu bar's own icon — swaps `waveform` for a live download-progress
/// readout while any model is downloading, so the download stays visible
/// even with the menu closed (all `MenuBarContentView` itself can do is
/// annotate its own "模型管理…" row, which is invisible until the menu is
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

    init(modelDownloadManager: ModelDownloadManager, session: RecordingSession) {
        self.downloadManager = modelDownloadManager
        self.session = session
    }

    var body: some View {
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
            Label("下载中", systemImage: "arrow.down.circle")
        } else {
            Image(systemName: "waveform")
        }
    }
}
