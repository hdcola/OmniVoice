import AppKit
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
        /// Problem 1 (round-4 user report) — the middle tier between the
        /// zero-download system engine and the full R2T2+T3PO pairing:
        /// downloads `bundle.lightweight` (R2T2 识别 + HY-MT1.5 翻译，约
        /// 3.4GB) instead. Reuses the same catalog bundle "模型库"'s own
        /// "方案 B：轻量低内存方案" card offers, rather than a second,
        /// parallel definition of the same pairing.
        case balanced
        case offlineModel
    }

    @State private var selectedMode: Mode = .offlineModel
    @State private var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    /// Review Round 1 Must-Fix 4 (首次启动向导下载大模型后无法自动激活，且缺乏磁盘
    /// 空间检查) — surfaced via `.alert` on this view rather than silently
    /// declining the download the way `try?` around `ensureDownloaded(_:)`
    /// used to (see this file's previous revision): a user who's already
    /// closed this window by the time that failure would have surfaced had
    /// no way to find out the "后台下载中" promise never actually started.
    @State private var diskSpaceWarningMessage: String?

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
                // Problem 1 (round-4 user report) — a third, middle-tier
                // card sits between the two originals. Wrapped in a
                // horizontal `ScrollView` rather than widening the window
                // (this sheet's host `NSWindow` is a fixed, non-resizable
                // 560pt — see `AppDelegate.presentOnboardingIfNeeded()`):
                // three cards' natural width comfortably exceeds the
                // content area at that fixed size, so this keeps every card
                // fully reachable (scroll to see the rest) instead of
                // clipping or force-squeezing them illegibly thin.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        modeCard(
                            mode: .lightweight, title: "极速轻量模式",
                            bullets: ["基于 macOS 自带引擎", "零磁盘占用，即开即用", "适合轻度记录与快速尝鲜"]
                        )
                        modeCard(
                            mode: .balanced, title: "均衡低内存模式",
                            bullets: [
                                "R2T2 识别 + HY-MT1.5 翻译", "混合语种自动识别，整句翻译",
                                "内存占用低，适合 8GB 设备", "约 3.4 GB，翻译无逐字预览",
                            ]
                        )
                        modeCard(
                            mode: .offlineModel, title: "高精离线大模型模式（推荐）",
                            bullets: ["基于 R2T2 + T3PO 离线大模型", "混合语种自动判别，打字机流式", "需下载约 12.4 GB 模型"]
                        )
                    }
                }
            }

            Divider()

            HStack {
                Button("跳过向导") { finish(startDownload: false) }
                Spacer()
                Button("一键开启并下载") { finish(startDownload: selectedMode != .lightweight) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert(
            "磁盘空间不足",
            isPresented: Binding(get: { diskSpaceWarningMessage != nil }, set: { if !$0 { diskSpaceWarningMessage = nil } })
        ) {
            Button("打开存储空间管理") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                diskSpaceWarningMessage = nil
            }
            Button("知道了", role: .cancel) { diskSpaceWarningMessage = nil }
        } message: {
            Text(diskSpaceWarningMessage ?? "")
        }
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

    /// Fixed `width` (not `.frame(maxWidth: .infinity)`, the original
    /// two-card layout's approach) — now that these sit inside a horizontal
    /// `ScrollView` (Problem 1), a greedy width would have each card try to
    /// claim all the scroll content's unconstrained width instead of laying
    /// out side by side.
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
            .frame(width: 220, alignment: .leading)
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
    ///
    /// Review Round 1 Must-Fix 4 — a insufficient-disk-space warning here
    /// blocks the download from starting (rather than only discovering it
    /// after `ensureDownloaded(_:)` throws, silently, behind `try?`, with
    /// this window already closed and no one left to tell); and each
    /// variant's completion now activates its engine itself, rather than
    /// relying on `ModelManagementView`'s own Task 2.1 banner logic — that
    /// view isn't guaranteed to ever be mounted for a fresh install that
    /// never opens Settings, so nothing would otherwise act on "下载完成后将
    /// 自动为您无缝启用" at all.
    ///
    /// Review Round 2 Must-Fix — `startBundleDownload()` used to be called
    /// and then unconditionally followed by marking onboarding complete and
    /// calling `onFinished()` (which `AppDelegate` wires to close/release
    /// this window). When the disk-space check above failed,
    /// `diskSpaceWarningMessage` got set but the window closed in the very
    /// same run loop turn regardless, destroying the `.alert` before SwiftUI
    /// ever got a chance to present it — the user saw the wizard just
    /// vanish with no explanation, while `hasCompletedOnboarding` was
    /// already `true`, so it would never show again. `startBundleDownload()`
    /// now reports whether it actually started something (or had nothing to
    /// do), and `finish(startDownload:)` only marks completion/closes the
    /// window when that's `true` — a disk-space failure instead leaves the
    /// window open with its alert visible and the wizard retriable.
    private func finish(startDownload: Bool) {
        if startDownload {
            guard startBundleDownload() else { return }
        }
        UserDefaults.standard.set(true, forKey: PersistedOnboardingKey.hasCompletedOnboarding)
        onFinished()
    }

    /// Which recommended bundle `.balanced`/`.offlineModel` each kick off —
    /// `nil` for `.lightweight`, which has nothing to download (Problem 1).
    private var selectedBundleID: String? {
        switch selectedMode {
        case .lightweight: return nil
        case .balanced: return "bundle.lightweight"
        case .offlineModel: return "bundle.standard-realtime"
        }
    }

    /// `true` if there was nothing to download, or a download was
    /// successfully queued; `false` only when the disk-space preflight
    /// failed and `diskSpaceWarningMessage` was set instead — see
    /// `finish(startDownload:)`'s doc for why that distinction is what
    /// keeps this window (and its alert) open on failure.
    private func startBundleDownload() -> Bool {
        guard let bundleID = selectedBundleID,
            let bundle = ProviderCatalog.bundles.first(where: { $0.id == bundleID })
        else {
            return true
        }
        let variants = bundle.status(isDownloaded: downloadManager.isDownloaded).remainingVariants
        guard !variants.isEmpty else { return true }

        // Task 4.2 — one preflight check against the *combined* remaining
        // size, not each variant checked individually as it starts (which
        // would let an early, smaller variant pass a check the batch as a
        // whole can't actually satisfy).
        let totalMB = variants.reduce(0) { $0 + $1.approximateSizeMB }
        if let warning = downloadManager.insufficientDiskSpaceWarning(forTotalMB: totalMB) {
            diskSpaceWarningMessage =
                "下载「\(bundle.displayName)」\(warning.errorDescription ?? "")。请清理磁盘空间后重试。"
            return false
        }

        for variant in variants {
            Task {
                do {
                    _ = try await downloadManager.ensureDownloaded(variant)
                    activateIfStillSystemEngine(variant)
                } catch {
                    // Best-effort background download — a failure here still
                    // leaves this variant's own inline retry card reachable
                    // from "模型库"/"语音与引擎" (Task 4.3) once the user
                    // opens Settings, so there's no separate error UI to
                    // surface from this already-dismissed onboarding window.
                }
            }
        }
        session.statusMessage = "模型正在后台下载中，下载完成后将自动为您无缝启用"
        return true
    }

    /// Mirrors `ModelManagementView.autoActivateIfSystemEngineStillSelected(_:)`
    /// (Task 2.1) — kept as its own small copy here rather than shared,
    /// since that view's version also needs to build an undo-able banner
    /// this already-dismissed onboarding window has nowhere to show.
    /// Guarded by `!session.isSessionActive` for the same reason Round 1's
    /// Must-Fix 3 added that guard there: a multi-minute download can
    /// easily span a recording started on the system engine in the
    /// meantime, and switching engines mid-recording would tear down the
    /// live provider that recording is still feeding.
    private func activateIfStillSystemEngine(_ variant: ModelVariant) {
        guard !session.isSessionActive else { return }
        if ProviderCatalog.transcriptionEngines.contains(where: { $0.id == variant.engineID }) {
            guard session.transcriptionEngineKind == .system else { return }
            session.transcriptionEngineID = variant.engineID
            session.transcriptionModelVariantID = variant.id
        } else if ProviderCatalog.translationEngines.contains(where: { $0.id == variant.engineID }) {
            guard session.translationEngineKind == .system else { return }
            session.translationEngineID = variant.engineID
            session.translationModelVariantID = variant.id
        }
    }
}

/// Namespaced the same way `PersistedSettingsKey` (`OmniVoiceCore`) is —
/// kept separate from that enum since onboarding is purely an `OmniVoice`-
/// module UI concern, not something `RecordingSession` itself needs to know.
enum PersistedOnboardingKey {
    static let hasCompletedOnboarding = "org.omnivoice.hasCompletedOnboarding"
}
