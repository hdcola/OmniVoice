import AppKit
import AVFoundation
import OmniVoiceCore
import SwiftUI

/// First-launch wizard ("欢迎使用 OmniVoice"), three steps: permissions and
/// switches, then the speech recognition model, then the translation model.
/// Each model step lists every choice with its memory use and download size;
/// a footer shows this Mac's memory next to the total of what is selected.
/// Styled with the same cards/capsules as Settings (`SettingsComponents`);
/// the navigation row is pinned below the scrolling content.
struct OnboardingView: View {
    /// Observed so a recording that starts while the wizard is open locks the
    /// model choice (see `isModeLocked`).
    @ObservedObject var session: RecordingSession
    let downloadManager: ModelDownloadManager
    @ObservedObject var selectionController: SelectionTranslationController
    /// Called once the user picks either bottom button — the host (see
    /// `AppDelegate`) is responsible for closing/releasing the window
    /// itself; this view has no window handle of its own to close.
    let onFinished: () -> Void

    init(
        session: RecordingSession, downloadManager: ModelDownloadManager,
        selectionController: SelectionTranslationController, onFinished: @escaping () -> Void
    ) {
        self.session = session
        self.downloadManager = downloadManager
        self.selectionController = selectionController
        self.onFinished = onFinished
        // Decided here, not in `onAppear`, so the first frame already shows
        // the right selection.
        let isRerun = UserDefaults.standard.bool(forKey: PersistedOnboardingKey.hasCompletedOnboarding)
        _isRerun = State(initialValue: isRerun)
        let initial = isRerun
            ? ModelSelectionPlan(
                transcription: session.transcriptionEngineKind == .model ? session.currentTranscriptionModelVariant : nil,
                translation: session.translationEngineKind == .model ? session.currentTranslationModelVariant : nil)
            : ModelSelectionPlan.recommended(physicalMemoryMB: Self.physicalMemoryMB)
        _plan = State(initialValue: initial)
        _preloadMode = State(initialValue: isRerun ? LaunchPreloadMode.stored : Self.defaultPreloadMode(for: initial))
    }

    private enum Step: Int, CaseIterable {
        case switches, speech, translation

        var title: String {
            switch self {
            case .switches: return String(localized: "Permissions and switches")
            case .speech: return String(localized: "Speech recognition model")
            case .translation: return String(localized: "Translation model")
            }
        }
    }

    private static var physicalMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }

    @State private var step = Step.switches
    @State private var plan: ModelSelectionPlan
    /// Opened again from Settings → 新手引导 (the wizard was completed before).
    @State private var isRerun: Bool
    /// A re-run only touches the engines/downloads once the user has clicked a
    /// model: the pre-selected rows are just a reading of the current setup.
    @State private var selectionEdited = false
    @State private var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    @State private var accessibilityAuthorized = SelectedTextReader.isAccessibilityTrusted
    @State private var inputMonitoringAuthorized = DoubleCopyMonitor.hasPermission
    /// Shown via `.alert` on this view rather than silently declining the
    /// download: a user who has already closed this window by the time a
    /// failure would surface can't find out the background download never
    /// started.
    @State private var diskSpaceWarningMessage: String?
    /// Applied only on finish (not when toggled), so skipping the wizard
    /// leaves the login item and launch preload untouched.
    @State private var launchAtLogin = false
    @State private var preloadMode: LaunchPreloadMode
    /// Once the user picks a preload mode themselves, changing the models
    /// stops overriding it with the default for that choice.
    @State private var preloadModeEdited = false
    @StateObject private var loginItem = LaunchAtLoginController()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    switch step {
                    case .switches:
                        permissionsCard
                        LaunchOptionsCard(
                            title: String(localized: "Startup preferences"),
                            launchAtLogin: $launchAtLogin,
                            preloadMode: $preloadMode,
                            needsLoginApproval: loginItem.needsApproval,
                            loginError: loginItem.lastError,
                            onOpenLoginItems: { loginItem.openLoginItemsSettings() },
                            showsPreloadRow: false
                        )
                    case .speech:
                        speechCard
                    case .translation:
                        translationCard
                        if plan.hasLocalModel {
                            LaunchOptionsCard(
                                title: String(localized: "Startup preferences"),
                                launchAtLogin: $launchAtLogin,
                                preloadMode: Binding(
                                    get: { preloadMode },
                                    set: { preloadMode = $0; preloadModeEdited = true }
                                ),
                                translationOnlyAvailable: plan.translation != nil,
                                showsLoginRow: false
                            )
                        }
                    }
                }
                .padding(16)
            }
            if step != .switches { summaryFooter }
            Divider().opacity(0.5)
            actionBar
        }
        .frame(width: 520)
        .onAppear {
            launchAtLogin = loginItem.isEnabled
        }
        .onChange(of: plan) { _, plan in
            // "Translation model only" loads nothing once translation is System.
            if plan.translation == nil, preloadMode == .translationOnly {
                preloadMode = Self.defaultPreloadMode(for: plan)
            }
            guard !preloadModeEdited else { return }
            preloadMode = Self.defaultPreloadMode(for: plan)
        }
        // None of these post a notification this app can observe cheaply,
        // and the user grants them in System Settings while this window is
        // open — polling once a second keeps the rows honest.
        .task {
            while !Task.isCancelled {
                microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
                accessibilityAuthorized = SelectedTextReader.isAccessibilityTrusted
                inputMonitoringAuthorized = DoubleCopyMonitor.hasPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert(
            "Not Enough Disk Space",
            isPresented: Binding(get: { diskSpaceWarningMessage != nil }, set: { if !$0 { diskSpaceWarningMessage = nil } })
        ) {
            Button("Open Storage Management") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                diskSpaceWarningMessage = nil
            }
            Button("Got It", role: .cancel) { diskSpaceWarningMessage = nil }
        } message: {
            Text(diskSpaceWarningMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Welcome to OmniVoice").font(.system(size: 22, weight: .bold))
            Text("Offline live bilingual captions, transcription, and quick translation for macOS")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count) · \(step.title)")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 4)
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var permissionsCard: some View {
        SettingsCard(title: String(localized: "Basic system permissions"), icon: "lock.shield") {
            PermissionRow(
                icon: "mic", title: String(localized: "Microphone"), detail: PermissionCopy.microphone,
                isGranted: microphoneAuthorized, open: requestMicrophonePermission
            )
            SettingsDivider()
            PermissionRow(
                icon: "rectangle.dashed.badge.record", title: String(localized: "Screen Recording"), detail: PermissionCopy.screenRecording,
                isGranted: screenRecordingAuthorized, open: requestScreenRecordingPermission
            )
            SettingsDivider()
            PermissionRow(
                icon: "figure.wave", title: String(localized: "Accessibility"), detail: PermissionCopy.accessibility,
                isGranted: accessibilityAuthorized, open: requestAccessibilityPermission
            )
            SettingsDivider()
            // Opt-in: the system's Input Monitoring prompt reads as alarming,
            // so it only appears once the user asks for this shortcut.
            SettingsRow(
                title: String(localized: "Double ⌘C translate (optional)"),
                subtitle: String(localized: "Select text, then press ⌘C twice quickly to translate it; turning this on requires “Input Monitoring” permission, and you can turn it off later in Settings")
            ) {
                Toggle("Double ⌘C translate", isOn: $selectionController.isDoubleCopyEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if selectionController.isDoubleCopyEnabled {
                SettingsDivider()
                PermissionRow(
                    icon: "keyboard", title: String(localized: "Input Monitoring"), detail: PermissionCopy.inputMonitoring,
                    isGranted: inputMonitoringAuthorized, open: requestInputMonitoringPermission
                )
            }
        }
    }

    // MARK: - Model steps

    private var speechCard: some View {
        modelCard(
            title: String(localized: "Speech recognition model"), icon: "waveform",
            engines: ProviderCatalog.transcriptionEngines, selected: plan.transcription?.id
        ) { variant in
            plan.transcription = variant
            selectionEdited = true
        }
    }

    private var translationCard: some View {
        modelCard(
            title: String(localized: "Translation model"), icon: "character.bubble",
            engines: ProviderCatalog.translationEngines, selected: plan.translation?.id
        ) { variant in
            plan.translation = variant
            selectionEdited = true
        }
    }

    /// One radio row for the system engine (no download, no memory), then each
    /// local engine's models under the engine's name.
    private func modelCard(
        title: String, icon: String, engines: [EngineDescriptor], selected: String?,
        choose: @escaping (ModelVariant?) -> Void
    ) -> some View {
        SettingsCard(title: title, icon: icon) {
            ForEach(Array(engines.enumerated()), id: \.element.id) { index, engine in
                if index > 0 { SettingsDivider() }
                if engine.kind == .system {
                    choiceRow(
                        title: engine.displayName, detail: engine.summary, isSelected: selected == nil,
                        trailing: String(localized: "No download · no memory"), recommended: false
                    ) { choose(nil) }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.displayName).font(.system(size: 12, weight: .semibold))
                        if !engine.summary.isEmpty {
                            Text(engine.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    ForEach(ProviderCatalog.modelVariants(forEngineID: engine.id)) { variant in
                        choiceRow(
                            title: variant.displayName, detail: variant.summary, isSelected: selected == variant.id,
                            trailing: variantTrailing(variant),
                            recommended: variant.id == ModelSelectionPlan.recommended(physicalMemoryMB: Self.physicalMemoryMB).transcription?.id
                                || variant.id == ModelSelectionPlan.recommended(physicalMemoryMB: Self.physicalMemoryMB).translation?.id
                        ) { choose(variant) }
                    }
                }
            }
            if isModeLocked {
                SettingsDivider()
                SettingsNote(text: String(localized: "Transcription or model loading is in progress, so the models can't be changed right now; try again when it finishes."), tint: .orange)
            }
        }
        .disabled(isModeLocked)
    }

    private func variantTrailing(_ variant: ModelVariant) -> String {
        let memory = String(localized: "About \(MemoryFormat.text(mb: variant.estimatedMemoryMB)) memory")
        if downloadManager.isDownloaded(variant) { return "\(memory) · " + String(localized: "Downloaded") }
        return "\(memory) · " + String(localized: "\(MemoryFormat.text(mb: variant.approximateSizeMB)) download")
    }

    private func choiceRow(
        title: String, detail: String, isSelected: Bool, trailing: String, recommended: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : .clear)
                    .padding(4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// This Mac's memory beside the total of the selection, tinted by how much
    /// of it the models would take, plus anything about the pairing worth
    /// knowing before downloading.
    private var summaryFooter: some View {
        let physical = Self.physicalMemoryMB
        let pressure = plan.pressure(physicalMemoryMB: physical)
        let tint: Color = pressure == .overcommitted ? .red : (pressure == .tight ? .orange : .secondary)
        let download = plan.downloadMB(isDownloaded: downloadManager.isDownloaded)
        return VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.5)
            HStack(alignment: .firstTextBaseline) {
                Text("This Mac: \(MemoryFormat.physicalText(mb: physical)) memory")
                Spacer(minLength: 8)
                Text(memoryTotalText)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
            }
            .font(.system(size: 12))
            if download > 0 {
                Text("To download: \(MemoryFormat.text(mb: download))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if pressure == .tight {
                Text("These models would use over half of this Mac's memory; other apps may slow down.")
                    .font(.system(size: 11)).foregroundStyle(tint)
            } else if pressure == .overcommitted {
                Text("These models would use most of this Mac's memory; choose lighter ones.")
                    .font(.system(size: 11)).foregroundStyle(tint)
            }
            ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                Text(noteText(note)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var memoryTotalText: String {
        guard plan.hasLocalModel else { return String(localized: "Selected: no extra memory") }
        let total = MemoryFormat.text(mb: plan.memoryMB)
        return plan.isMemoryEstimated
            ? String(localized: "Selected: about \(total) memory (estimated)")
            : String(localized: "Selected: about \(total) memory")
    }

    private func noteText(_ note: ModelSelectionPlan.Note) -> String {
        switch note {
        case .limitedLanguages(let codes):
            let names = codes.map(LanguageCatalog.displayName(for:)).joined(separator: ", ")
            return String(localized: "This speech model recognizes only: \(names).")
        }
    }

    // MARK: - Navigation

    /// Engines can't be swapped mid-recording or while a model preloads
    /// (Settings refuses both), so a re-run's model choice is frozen then —
    /// otherwise 完成 would close the wizard having silently changed nothing.
    private var isModeLocked: Bool { isRerun && isSessionBusy }

    private var isSessionBusy: Bool { session.isSessionActive || session.isPreloadingModel }

    /// First run, or a re-run where the user picked a model: the model choice
    /// takes effect. A re-run that left it alone only reviews permissions and
    /// startup options.
    private var appliesSelection: Bool { !isRerun || selectionEdited }

    /// Whether the primary button would start any download.
    private var willDownload: Bool {
        appliesSelection && plan.downloadMB(isDownloaded: downloadManager.isDownloaded) > 0
    }

    private var isLastStep: Bool { step == Step.allCases.last }

    private var actionBar: some View {
        HStack {
            if let previous = Step(rawValue: step.rawValue - 1) {
                Button("Back") { step = previous }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                // A re-run has nothing to skip: this just closes the wizard.
                Button(isRerun ? String(localized: "Cancel") : String(localized: "Skip Setup")) { skip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let next = Step(rawValue: step.rawValue + 1) {
                PrimaryPillButton(title: String(localized: "Next")) { step = next }
            } else {
                PrimaryPillButton(title: willDownload ? String(localized: "Enable & Download") : String(localized: "Done")) {
                    finish()
                }
                .disabled(isModeLocked && selectionEdited)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func requestMicrophonePermission() {
        // `requestAccess` only prompts while the status is undetermined; once
        // the user has denied it, it returns `false` silently, so send them
        // to the System Settings pane instead (same as the "通用" tab).
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in microphoneAuthorized = granted }
        }
    }

    private func requestAccessibilityPermission() {
        // Shows the system prompt the first time; the System Settings pane
        // covers a previous denial, which macOS won't prompt about again.
        SelectedTextReader.requestAccessibilityPermission()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func requestInputMonitoringPermission() {
        DoubleCopyMonitor.requestPermission()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
    }

    private func requestScreenRecordingPermission() {
        // Prompts the system TCC dialog if not yet decided; after a denial
        // it returns `false` silently (same "ask once" semantics
        // `SystemAudioCapture` relies on elsewhere), so also open the System
        // Settings pane — same as the "通用" tab.
        screenRecordingAuthorized = CGRequestScreenCaptureAccess()
        guard !screenRecordingAuthorized else { return }
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }

    /// Marks onboarding done without touching the login item or the launch
    /// preload setting, as `launchAtLogin`'s doc promises.
    private func skip() {
        UserDefaults.standard.set(true, forKey: PersistedOnboardingKey.hasCompletedOnboarding)
        onFinished()
    }

    /// Persists completion to `UserDefaults` and applies the choices: the
    /// selected models download in the background and switch on when they
    /// land; a system-engine choice on a re-run switches back to that engine.
    /// A disk-space failure leaves the window open with its alert visible
    /// (completion is only recorded, and the window only closed, when the
    /// download started or there was nothing to do), so the wizard stays
    /// retriable instead of vanishing with the alert undelivered.
    private func finish() {
        // A re-run is the user choosing models on purpose, so it replaces the
        // engines in use; a first run only upgrades engines that are still
        // the system ones.
        let replacingEngines = isRerun
        if appliesSelection {
            guard startDownload(replacingEngines: replacingEngines) else { return }
            if isRerun { switchToSystemEngines(for: plan) }
        }
        persistLaunchOptions()
        // Both directions, so a re-run wizard can also turn it off.
        if launchAtLogin != loginItem.isEnabled { loginItem.setEnabled(launchAtLogin) }
        UserDefaults.standard.set(true, forKey: PersistedOnboardingKey.hasCompletedOnboarding)
        onFinished()
    }

    /// Nothing to load when only system engines are selected.
    private func persistLaunchOptions() {
        UserDefaults.standard.set(
            (appliesSelection && !plan.hasLocalModel ? LaunchPreloadMode.off : preloadMode).rawValue,
            forKey: PersistedLaunchKey.preloadMode
        )
    }

    /// Load both models when they fit comfortably; with only the translation
    /// model local, or a tight Mac, keep just the translator warm.
    private static func defaultPreloadMode(for plan: ModelSelectionPlan) -> LaunchPreloadMode {
        guard plan.hasLocalModel else { return .off }
        guard plan.transcription != nil else { return .translationOnly }
        guard plan.translation != nil else { return .all }
        return plan.pressure(physicalMemoryMB: physicalMemoryMB) == .comfortable ? .all : .translationOnly
    }

    /// `true` if there was nothing to download, or a download was
    /// successfully queued; `false` only when the disk-space preflight
    /// failed and `diskSpaceWarningMessage` was set instead.
    private func startDownload(replacingEngines: Bool) -> Bool {
        let variants = plan.localVariants
        let remaining = variants.filter { !downloadManager.isDownloaded($0) }
        guard !remaining.isEmpty else {
            // Already downloaded: nothing will finish later to activate/preload,
            // so do it now. The launch preload setting is written in `finish()`
            // right after this returns, so hand it over via the same defaults
            // key first.
            persistLaunchOptions()
            preloadOnceReady(variants, replacingEngines: replacingEngines)
            return true
        }

        // One preflight check against the *combined* remaining size, not each
        // model checked individually as it starts (which would let an early,
        // smaller one pass a check the batch as a whole can't satisfy).
        let totalMB = remaining.reduce(0) { $0 + $1.approximateSizeMB }
        if let warning = downloadManager.insufficientDiskSpaceWarning(forTotalMB: totalMB) {
            diskSpaceWarningMessage =
                String(localized: "Couldn’t download the selected models: \(warning.errorDescription ?? ""). Free up some disk space and try again.")
            return false
        }

        SystemNotifier.requestAuthorizationIfNeeded()
        // Two models finishing back to back can each see the set as complete
        // by the time their task resumes; notify only once.
        final class Flag { var notified = false }
        let completionNotice = Flag()
        for variant in remaining {
            Task {
                do {
                    _ = try await downloadManager.ensureDownloaded(variant)
                    activate(variant, replacingEngines: replacingEngines)
                    if !completionNotice.notified, variants.allSatisfy(downloadManager.isDownloaded) {
                        completionNotice.notified = true
                        SystemNotifier.notify(
                            title: String(localized: "Model Download Complete"),
                            body: String(localized: "The selected models were downloaded and enabled automatically"))
                    }
                    preloadOnceReady(variants, replacingEngines: replacingEngines)
                } catch is CancellationError {
                } catch {
                    SystemNotifier.notify(
                        title: String(localized: "Model Download Failed"),
                        body: String(localized: "“\(variant.displayName)”: \(error.localizedDescription). You can retry in Settings → Model Library."))
                    // Best-effort background download — a failure here still
                    // leaves this variant's own inline retry card reachable
                    // from the Model Library once the user opens Settings.
                }
            }
        }
        session.statusMessage = String(localized: "The model is downloading in the background and will be enabled automatically when it finishes")
        return true
    }

    /// Launch-time preloading couldn't run at launch (the models weren't
    /// downloaded yet), so do it as soon as every selected model has landed
    /// and its engine is active — earlier, a half-downloaded set would preload
    /// the system engine and then be discarded on the engine switch.
    private func preloadOnceReady(_ variants: [ModelVariant], replacingEngines: Bool) {
        guard variants.allSatisfy(downloadManager.isDownloaded) else { return }
        // Activate every variant first: with two downloads finishing together,
        // the first finisher would otherwise preload while the second
        // variant's engine is still the system one, then have that load
        // discarded when the second activates.
        for variant in variants { activate(variant, replacingEngines: replacingEngines) }
        guard let scope = LaunchPreloadMode.stored.effectiveScope(for: session) else { return }
        Task { await session.preloadModel(scope: scope) }
    }

    /// Switches the recognition/translation engine to `variant`'s. First run
    /// (`replacingEngines` false): only an engine still on the system one, so
    /// a choice made while the download ran isn't undone. Re-run: the wizard's
    /// choice wins, including another model of the engine already in use.
    /// Nothing changes while a session is recording or a model preloads
    /// (switching mid-recording would tear down the live provider).
    private func activate(_ variant: ModelVariant, replacingEngines: Bool) {
        guard !isSessionBusy else { return }
        if ProviderCatalog.transcriptionEngines.contains(where: { $0.id == variant.engineID }) {
            guard replacingEngines || session.transcriptionEngineKind == .system else { return }
            if session.transcriptionEngineID != variant.engineID { session.transcriptionEngineID = variant.engineID }
            if session.transcriptionModelVariantID != variant.id { session.transcriptionModelVariantID = variant.id }
        } else if ProviderCatalog.translationEngines.contains(where: { $0.id == variant.engineID }) {
            guard replacingEngines || session.translationEngineKind == .system else { return }
            if session.translationEngineID != variant.engineID { session.translationEngineID = variant.engineID }
            if session.translationModelVariantID != variant.id { session.translationModelVariantID = variant.id }
        }
    }

    /// Re-running the wizard with the system engine chosen for a side: back to
    /// that system engine.
    private func switchToSystemEngines(for plan: ModelSelectionPlan) {
        guard !isSessionBusy else { return }
        if plan.transcription == nil, let engine = ProviderCatalog.transcriptionEngines.first(where: { $0.kind == .system }) {
            session.transcriptionEngineID = engine.id
        }
        if plan.translation == nil, let engine = ProviderCatalog.translationEngines.first(where: { $0.kind == .system }) {
            session.translationEngineID = engine.id
        }
    }
}

/// Namespaced the same way `PersistedSettingsKey` (`OmniVoiceCore`) is —
/// kept separate from that enum since onboarding is purely an `OmniVoice`-
/// module UI concern, not something `RecordingSession` itself needs to know.
enum PersistedOnboardingKey {
    static let hasCompletedOnboarding = "org.hdcola.omnivoice.hasCompletedOnboarding"
}
