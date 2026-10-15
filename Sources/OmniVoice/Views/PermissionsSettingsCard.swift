import AppKit
import AVFoundation
import SwiftUI

/// What each system permission is for, worded once so Settings and the
/// onboarding wizard can't drift apart.
enum PermissionCopy {
    static let microphone = "转录你的声音（实时转录、语音输入）"
    static let screenRecording = "捕获系统声音（会议、网课）和截图翻译；截图只在本机识别，不会上传"
    static let accessibility = "读取其他应用中选中的文字，把语音输入的文字粘贴到光标处，并在语音输入时暂停、恢复音乐和视频（发送播放/暂停键）；未授权时划词可复制后在翻译面板里粘贴，也不会暂停音乐"
    static let inputMonitoring = "识别连按两次 ⌘C 和语音输入的触发键；只检测这些按键，不记录其他输入"
}

/// Every system permission the app asks for, in one card at the top of
/// Settings' "通用" tab: Microphone (live transcription, voice input),
/// Screen Recording (system audio + screenshot translation), Accessibility
/// (reading the selection, typing dictated text, pausing media) and Input
/// Monitoring (the ⌘C ⌘C shortcut and the voice-input key).
struct PermissionsSettingsCard: View {
    @ObservedObject var controller: SelectionTranslationController
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var isAccessibilityTrusted = SelectedTextReader.isAccessibilityTrusted
    @State private var hasScreenRecordingPermission = ScreenFreezer.hasPermission
    @State private var hasInputMonitoringPermission = DoubleCopyMonitor.hasPermission

    var body: some View {
        SettingsCard(title: "权限", icon: "lock.shield") {
            PermissionRow(
                icon: "mic", title: "麦克风", detail: PermissionCopy.microphone,
                isGranted: microphoneStatus == .authorized,
                open: requestMicrophone
            )
            SettingsDivider()
            PermissionRow(
                icon: "rectangle.dashed.badge.record", title: "屏幕录制",
                detail: PermissionCopy.screenRecording,
                isGranted: hasScreenRecordingPermission,
                open: {
                    ScreenFreezer.requestPermission()
                    controller.openScreenRecordingSettings()
                }
            )
            SettingsDivider()
            PermissionRow(
                icon: "figure.wave", title: "辅助功能",
                detail: PermissionCopy.accessibility,
                isGranted: isAccessibilityTrusted,
                open: controller.openAccessibilitySettings
            )
            SettingsDivider()
            PermissionRow(
                icon: "keyboard", title: "输入监控",
                detail: PermissionCopy.inputMonitoring,
                isGranted: hasInputMonitoringPermission,
                open: controller.openInputMonitoringSettings
            )
        }
        // None of these post a notification this app can observe cheaply,
        // and the user grants them in System Settings while this tab is
        // open — polling once a second keeps the rows honest.
        .task {
            while !Task.isCancelled {
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                isAccessibilityTrusted = SelectedTextReader.isAccessibilityTrusted
                hasScreenRecordingPermission = ScreenFreezer.hasPermission
                hasInputMonitoringPermission = DoubleCopyMonitor.hasPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Prompts the first time; once decided, macOS only lets the user flip
    /// the switch in System Settings themselves.
    private func requestMicrophone() {
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
        }
    }
}
