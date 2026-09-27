import AppKit
import OmniVoiceCore
import SwiftUI

/// Content of the menu-bar dropdown — OmniVoice has no Dock icon
/// (`LSUIElement`, see `Resources/Info.plist`), so this menu is the app's
/// primary entry point for start/stop, the floating panel, history, and
/// settings.
struct MenuBarContentView: View {
    @EnvironmentObject private var session: RecordingSession
    @Environment(\.openWindow) private var openWindow

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
        Button(session.isRunning ? "停止转录" : "开始转录") {
            Task {
                if session.isRunning {
                    await session.stop()
                } else {
                    await session.start()
                }
            }
        }
        .disabled(session.isStopping)

        Button("显示/隐藏悬浮窗") {
            (NSApp.delegate as? AppDelegate)?.toggleFloatingPanel()
        }

        Divider()

        Button("历史记录…") {
            openWindow(id: "history")
        }

        SettingsLink {
            Text("设置…")
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
