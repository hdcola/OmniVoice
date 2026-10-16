import AppKit
import OmniVoiceCore
import SwiftUI

/// Settings window — a pill-style `SettingsTabBar` over six tabs: "通用"
/// (permissions, language, launch, notifications, floating panel), "语音识别"
/// (recognition / translation engines and memory), "语音输入", "快捷翻译",
/// "模型库" (the full model catalog — the same content that used to be the
/// standalone "模型管理" window) and "关于". Data-driven from `ProviderCatalog`
/// rather than one hand-written `case` per engine, so adding a new community
/// model audio.cpp supports later is a catalog change, not a UI change.
/// One fixed window size for every tab (capped to the screen's height); the
/// long tabs scroll inside it.
enum SettingsWindowLayout {
    static let width: CGFloat = 520

    static var height: CGFloat {
        min(620, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var navigation: SettingsNavigationState
    @EnvironmentObject private var selectionController: SelectionTranslationController
    @EnvironmentObject private var dictationController: DictationController
    @EnvironmentObject private var appDelegate: AppDelegate
    /// Passed in explicitly (not defaulted to `.shared`) and expected to be
    /// the exact same instance `RecordingSession` was itself given — see
    /// `RecordingSession.init`'s own injectable `modelDownloadManager`.
    @ObservedObject private var downloadManager: ModelDownloadManager

    init(modelDownloadManager: ModelDownloadManager) {
        self.downloadManager = modelDownloadManager
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $navigation.selectedTab)
                .padding(.top, 10)
                .padding(.bottom, 4)
            switch navigation.selectedTab {
            case .general: GeneralSettingsView()
            case .recognition: RecognitionSettingsView(modelDownloadManager: downloadManager)
            case .dictation: dictationTab
            case .quickTranslation: quickTranslationTab
            case .models: modelsTab
            case .about: aboutTab
            }
        }
        .frame(width: SettingsWindowLayout.width, height: SettingsWindowLayout.height)
        // Settings is a SwiftUI `Settings` scene (no NSWindow of ours), so
        // pick its window up here — on the root, not a per-tab child, so it
        // works whichever tab opens first — to give the app a Dock icon.
        .background(WindowReader { appDelegate.trackForDock($0, id: "settings") })
    }

    // MARK: - 语音输入 / 快捷翻译

    private var dictationTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LanguageSettingsHint()
                DictationSettingsView(controller: dictationController)
            }
            .padding(16)
        }
    }

    private var quickTranslationTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LanguageSettingsHint()
                SelectionTranslationSettingsView(
                    controller: selectionController,
                    translator: selectionController.translator,
                    speaker: selectionController.speaker,
                    downloadManager: downloadManager
                )
            }
            .padding(16)
        }
    }

    // MARK: - Tab 2: 模型库

    private var modelsTab: some View {
        ModelManagementView(modelDownloadManager: downloadManager)
    }


    // MARK: - Tab 3: 关于

    private static let repositoryURL = URL(string: "https://github.com/hdcola/OmniVoice")!

    private var aboutTab: some View {
        // The content is vertically centered in the window; `minHeight`
        // keeps it that way while still letting a short window scroll.
        GeometryReader { proxy in
            ScrollView {
                aboutContent
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private var aboutContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                Text("OmniVoice").font(.system(size: 24, weight: .bold))
                Text("v\(appVersionString)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Offline live bilingual captions, transcription, and quick translation for macOS")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)

            Link(destination: Self.repositoryURL) {
                VStack(spacing: 3) {
                    Text("⭐ Star us on GitHub").font(.system(size: 14, weight: .semibold))
                    Text("If OmniVoice helps you, give it a ⭐ on GitHub!")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.yellow.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            SettingsCard {
                aboutButton("See What's New", icon: "sparkles") { appDelegate.showAllWhatsNew() }
                SettingsDivider()
                aboutLink("GitHub", icon: "chevron.left.forwardslash.chevron.right", url: Self.repositoryURL)
                SettingsDivider()
                aboutLink("Releases", icon: "shippingbox", url: Self.repositoryURL.appendingPathComponent("releases"))
                SettingsDivider()
                aboutLink("Report an Issue", icon: "exclamationmark.bubble", url: Self.repositoryURL.appendingPathComponent("issues"))
            }

            Text("System engines use the macOS Speech / Translation frameworks; local engines use audio.cpp (R2T2) and llama.cpp (T3PO / HY-MT1.5) and run fully offline.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Text("Apache License 2.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func aboutLink(_ title: LocalizedStringKey, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func aboutButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }
}


/// Hands the hosting `NSWindow` to `onWindow` whenever the view (re)attaches
/// to one — SwiftUI offers no direct handle on a `Settings` scene's window.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowReportingView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowReportingView)?.onWindow = onWindow
    }

    private final class WindowReportingView: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}
