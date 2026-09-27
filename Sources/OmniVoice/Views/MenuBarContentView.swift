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
        Button(session.isRunning ? "停止转录" : (session.isStarting ? "启动中…" : "开始转录")) {
            Task {
                if session.isRunning {
                    await session.stop()
                } else {
                    await session.start()
                }
            }
        }
        .disabled(session.isStopping || session.isStarting)

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

        // Permission requirement is explained by the
        // `screenRecordingPermissionNeeded` caption below instead of in this
        // label — keeps the menu item itself from wrapping/getting cut off.
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

        Button("设置…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        Text(session.statusMessage)
            .font(.caption)

        if session.screenRecordingPermissionNeeded {
            Text("需要在系统设置里授权屏幕录制权限，才能捕获系统声音")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Divider()

        Button("退出 OmniVoice") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
