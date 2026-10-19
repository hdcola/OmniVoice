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

/// Source and target pickers, the ⇄ swap and why a swap is blocked — the
/// 字幕悬浮窗's language chip popover and the menu bar's language row show
/// the same controls.
struct LanguagePairControls: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Source language")
                        .foregroundStyle(.secondary)
                        // The pickers give way instead: a squeezed label
                        // wrapped to "源\n语言".
                        .fixedSize()
                    // Disabled for the whole start→stop lifecycle
                    // (isSessionActive, not just isRunning): it's only read
                    // once, at the top of `start()`, to configure the ASR
                    // engine for that recording (`SpeechAnalyzer`'s locale
                    // can't change mid-session).
                    SourceLanguagePicker(
                        sourceLanguageCode: $session.sourceLanguageCode,
                        transcriptionEngineKind: session.transcriptionEngineKind,
                        transcriptionEngineID: session.transcriptionEngineID,
                        transcriptionVariantID: session.currentTranscriptionModelVariant?.id,
                        allowsAuto: session.languages.transcriptionDirection == .listenForeign
                    )
                    .labelsHidden()
                    .disabled(session.isSessionActive)
                    // Fills the column rather than its widest option's width,
                    // which overflowed the popover.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Target language")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    // Target stays editable while running: unlike source, it
                    // isn't baked into a provider at `start()` — the
                    // `.translationTask` above rebuilds
                    // `translationConfiguration` on every change, so
                    // switching it mid-recording retargets the next
                    // translated segment.
                    TargetLanguagePicker(
                        targetLanguageCode: $session.targetLanguageCode,
                        translationEngineID: session.translationEngineID,
                        onSwitchToSystemTranslation: { session.translationEngineID = "system.translation" },
                        isSessionActive: session.isSessionActive
                    )
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Swaps source and target (听外语 ⇄ 说我的语言). Not while a
            // recording runs (the source is fixed at `start()`). "自动" survives
            // a swap — it comes back when swapping back. The reason it's
            // blocked is written right under it: a tooltip never shows in
            // this panel, which is never key.
            Button {
                session.swapTranscriptionDirection()
            } label: {
                Label("Swap source and target languages", systemImage: "arrow.left.arrow.right")
            }
            .disabled(!session.canSwapTranscriptionDirection)
            if let reason = session.swapBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
