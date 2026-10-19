import AppKit
import AVFoundation
import SwiftUI

/// What each system permission is for, worded once so Settings and the
/// onboarding wizard can't drift apart.
enum PermissionCopy {
    static let microphone = String(localized: "Transcribes your voice (live transcription, dictation)")
    static let screenRecording = String(localized: "Captures system audio (meetings, online classes) and powers screenshot translation; screenshots are recognized on this Mac only and never uploaded")
    static let accessibility = String(localized: "Reads selected text in other apps, pastes dictated text at the cursor, and pauses and resumes music during dictation (by sending the play/pause key); without it you can copy the selection and paste it into the Translation panel, and music is only paused in Music and Spotify, if you allowed controlling them (browsers are still muted)")
    static let inputMonitoring = String(localized: "Detects the double ⌘C press and the dictation trigger key; only those keys are checked, nothing else is recorded")
}

/// Every system permission the app asks for, as the first section of
/// Settings' "通用" tab: Microphone (live transcription, dictation),
/// Screen Recording (system audio + screenshot translation), Accessibility
/// (reading the selection, typing dictated text, pausing media) and Input
/// Monitoring (the ⌘C ⌘C shortcut and the voice-input key). Once all four
/// are granted the section folds into one line, so a settled setup doesn't
/// open Settings on a wall of "已授权" rows.
struct PermissionsSettingsSection: View {
    @ObservedObject var controller: SelectionTranslationController
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var isAccessibilityTrusted = SelectedTextReader.isAccessibilityTrusted
    @State private var hasScreenRecordingPermission = ScreenFreezer.hasPermission
    @State private var hasInputMonitoringPermission = DoubleCopyMonitor.hasPermission
    @State private var showsDetails = false

    private var allGranted: Bool {
        microphoneStatus == .authorized && isAccessibilityTrusted
            && hasScreenRecordingPermission && hasInputMonitoringPermission
    }

    var body: some View {
        Section(String(localized: "Permissions")) {
            if allGranted {
                LabeledContent {
                    Button(showsDetails ? LocalizedStringKey("Hide Details") : "Show Details") { showsDetails.toggle() }
                } label: {
                    Label {
                        Text("All permissions granted")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            if !allGranted || showsDetails {
                permissionRow(
                    icon: "mic", title: "Microphone", detail: PermissionCopy.microphone,
                    isGranted: microphoneStatus == .authorized,
                    open: requestMicrophone
                )
                permissionRow(
                    icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                    detail: PermissionCopy.screenRecording,
                    isGranted: hasScreenRecordingPermission,
                    open: {
                        ScreenFreezer.requestPermission()
                        controller.openScreenRecordingSettings()
                    }
                )
                permissionRow(
                    icon: "figure.wave", title: "Accessibility",
                    detail: PermissionCopy.accessibility,
                    isGranted: isAccessibilityTrusted,
                    open: controller.openAccessibilitySettings
                )
                permissionRow(
                    icon: "keyboard", title: "Input Monitoring",
                    detail: PermissionCopy.inputMonitoring,
                    isGranted: hasInputMonitoringPermission,
                    open: controller.openInputMonitoringSettings
                )
            }
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

    /// Icon, name and purpose on the left; "已授权" or a "去授权" button on
    /// the right.
    private func permissionRow(
        icon: String, title: String, detail: String, isGranted: Bool, open: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            if isGranted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Grant", action: open)
            }
        } label: {
            Label {
                SettingsLabel(title: title, subtitle: detail)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
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
