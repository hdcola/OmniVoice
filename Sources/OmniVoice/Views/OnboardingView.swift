import AVFoundation
import OmniVoiceCore
import SwiftUI

/// Task 4.1 (首次启动向导 Quick Setup Sheet) —
/// Docs/UX-SETTINGS-MODEL-MANAGEMENT.md §4.7's 3-step "欢迎使用 OmniVoice"
/// card: permission status, a lightweight-vs-offline-model mode choice, and
/// a launch action. Rendered as one scrollable page (not a paginated
/// wizard) — the design doc's own mockup lays out all three steps on a
/// single sheet rather than click-through pages, and nothing here actually
/// depends on a previous step's answer the way a true wizard would.
struct OnboardingView: View {
    let session: RecordingSession
    let downloadManager: ModelDownloadManager
    /// Called once the user picks either bottom button — the host (see
    /// `AppDelegate`) is responsible for closing/releasing the window
    /// itself; this view has no window handle of its own to close.
    let onFinished: () -> Void

    private enum Mode {
        case lightweight
        case offlineModel
    }

    @State private var selectedMode: Mode = .offlineModel
    @State private var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenRecordingAuthorized = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 4) {
                Text("欢迎使用 OmniVoice").font(.title2.bold())
                Text("macOS 离线实时双语字幕与转录工具")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Step 1：基础系统授权").font(.headline)
                permissionRow(
                    title: "麦克风权限", isAuthorized: microphoneAuthorized,
                    requestAction: requestMicrophonePermission
                )
                permissionRow(
                    title: "系统音频录制（用于会议/网课声音捕获）", isAuthorized: screenRecordingAuthorized,
                    requestAction: requestScreenRecordingPermission
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Step 2：选择适合您的运行模式").font(.headline)
                HStack(spacing: 12) {
                    modeCard(
                        mode: .lightweight, title: "极速轻量模式",
                        bullets: ["基于 macOS 自带引擎", "零磁盘占用，即开即用", "适合轻度记录与快速尝鲜"]
                    )
                    modeCard(
                        mode: .offlineModel, title: "高精离线大模型模式（推荐）",
                        bullets: ["基于 R2T2 + T3PO 离线大模型", "混合语种自动判别，打字机流式", "需下载约 12.4 GB 模型"]
                    )
                }
            }

            Divider()

            HStack {
                Button("跳过向导") { finish(startDownload: false) }
                Spacer()
                Button("一键开启并下载") { finish(startDownload: selectedMode == .offlineModel) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func permissionRow(title: String, isAuthorized: Bool, requestAction: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isAuthorized {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("立即授权", action: requestAction)
                    .font(.caption)
            }
        }
    }

    private func modeCard(mode: Mode, title: String, bullets: [String]) -> some View {
        Button {
            selectedMode = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: selectedMode == mode ? "largecircle.fill.circle" : "circle")
                    Text(title).font(.callout.bold())
                }
                ForEach(bullets, id: \.self) { bullet in
                    Text("· \(bullet)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (selectedMode == mode ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in microphoneAuthorized = granted }
        }
    }

    private func requestScreenRecordingPermission() {
        // Prompts the system TCC dialog if not yet decided; a no-op if
        // already granted/denied (same "ask once" semantics `SystemAudioCapture`
        // relies on elsewhere in the app).
        screenRecordingAuthorized = CGRequestScreenCaptureAccess()
    }

    /// Persists the chosen mode/completion to `UserDefaults` — see
    /// `PersistedSettingsKey.hasCompletedOnboarding`'s doc — and, for the
    /// "高精离线大模型模式" path, kicks off the standard realtime bundle
    /// (R2T2 + T3PO) download in the background per §4.7's "点击‘高精离线大
    /// 模型模式’：后台自动将 R2T2 与 T3PO 加入下载队列...转入正常主界面" rule.
    /// Deliberately does *not* switch `session.transcriptionEngineID`/
    /// `translationEngineID` itself — `ModelManagementView`'s existing Task
    /// 2.1 auto-activation banner already does that the moment each model
    /// finishes downloading, so this stays a single code path instead of a
    /// second, separate "switch engine" implementation here.
    private func finish(startDownload: Bool) {
        UserDefaults.standard.set(true, forKey: PersistedOnboardingKey.hasCompletedOnboarding)
        if startDownload {
            for bundle in ProviderCatalog.bundles where bundle.id == "bundle.standard-realtime" {
                for variantID in bundle.variantIDs {
                    guard let variant = ProviderCatalog.variant(forID: variantID),
                          !downloadManager.isDownloaded(variant)
                    else { continue }
                    Task { _ = try? await downloadManager.ensureDownloaded(variant) }
                }
            }
            session.statusMessage = "模型正在后台下载中，下载完成后将自动为您无缝启用"
        }
        onFinished()
    }
}

/// Namespaced the same way `PersistedSettingsKey` (`OmniVoiceCore`) is —
/// kept separate from that enum since onboarding is purely an `OmniVoice`-
/// module UI concern, not something `RecordingSession` itself needs to know.
enum PersistedOnboardingKey {
    static let hasCompletedOnboarding = "org.omnivoice.hasCompletedOnboarding"
}
