import AppKit
import OmniVoiceCore
import SwiftUI

// Live-transcription status pieces shared by the 字幕悬浮窗 and the menu bar.

/// A permission the last start found missing, shown as an orange notice
/// with a deeplink to the System Settings pane that grants it.
enum PermissionIssue: String, Identifiable {
    case microphone
    case screenRecording

    var id: String { rawValue }

    var message: String {
        switch self {
        case .microphone: return String(localized: "Grant microphone access in System Settings")
        case .screenRecording: return String(localized: "Grant screen recording access in System Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic.slash"
        case .screenRecording: return "display"
        }
    }

    var settingsURL: URL {
        switch self {
        case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    /// What the last start found missing, in display order.
    @MainActor
    static func current(in session: RecordingSession) -> [PermissionIssue] {
        var issues: [PermissionIssue] = []
        if session.microphonePermissionNeeded { issues.append(.microphone) }
        if session.screenRecordingPermissionNeeded { issues.append(.screenRecording) }
        return issues
    }
}


/// Four small bars that rise with the microphone level — next to the timer
/// in the 字幕悬浮窗's start/stop capsule and the menu bar's status row.
/// Without it a misconfigured input device (wrong mic, muted, unplugged)
/// looked identical to a working one until text failed to show up. Scales with `level` (0...1, see `AudioMixer.onLevel`)
/// rather than toggling on/off, so it reads as a meter.
struct InputLevelBars: View {
    let level: Float
    private static let weights: [CGFloat] = [0.55, 1, 0.75, 0.9]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.green)
                    .frame(width: 2, height: 3 + CGFloat(level) * 9 * Self.weights[index])
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityLabel("Microphone is receiving audio")
    }
}

/// The language pair as one row, "[英语 ⌄] ⇄ [简体中文 ⌄]" — in the menu
/// bar popover and the 字幕悬浮窗's language chip popover. It reads left to
/// right like the chip, with the swap between the two sides it swaps. Why a
/// swap is blocked is written under the row: a tooltip never shows in the
/// 字幕悬浮窗, which is never key.
struct LanguagePairRow: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Fixed at `start()`, so not while a session is active.
                SourceLanguagePicker(
                    sourceLanguageCode: $session.sourceLanguageCode,
                    transcriptionEngineKind: session.transcriptionEngineKind,
                    transcriptionEngineID: session.transcriptionEngineID,
                    transcriptionVariantID: session.currentTranscriptionModelVariant?.id,
                    allowsAuto: session.languages.transcriptionDirection == .listenForeign,
                    showsShortName: true
                )
                .labelsHidden()
                .disabled(session.isSessionActive)
                .frame(maxWidth: .infinity)

                Button {
                    session.swapTranscriptionDirection()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!session.canSwapTranscriptionDirection)
                .help("Swap source and target languages")
                .accessibilityLabel("Swap source and target languages")

                // Editable while running: the next translated segment uses it.
                TargetLanguagePicker(
                    targetLanguageCode: $session.targetLanguageCode,
                    translationEngineID: session.translationEngineID,
                    onSwitchToSystemTranslation: { session.translationEngineID = "system.translation" },
                    isSessionActive: session.isSessionActive
                )
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            if let reason = session.swapBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
