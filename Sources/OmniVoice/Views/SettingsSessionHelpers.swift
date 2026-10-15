import OmniVoiceCore
import SwiftUI

/// Derived values shared by more than one Settings tab (通用's "启动" and
/// "新手引导" cards, 语音识别's engine cards and memory console).
extension RecordingSession {
    /// `isPreloadingModel` alongside `isSessionActive`: switching engines
    /// mid-preload would race `preloadModel()`'s in-flight `loadModel()`
    /// calls against `discardLoadedModelsIfStale()` unloading the very
    /// providers it's still awaiting.
    var isSettingsBusy: Bool {
        isSessionActive || isPreloadingModel
    }

    var settingsTranslationMemoryGB: Int {
        guard translationEngineKind == .model,
            let variant = currentTranslationModelVariant
        else { return 0 }
        return variant.recommendedMemoryGB
    }

    /// Sum of `recommendedMemoryGB` for every currently-selected `.model`
    /// engine's active variant — an estimate, not a live measurement (no
    /// API here for actual RSS/VRAM), same spirit as §4.2.2's "预计占用统一
    /// 内存：12.4 GB (R2T2: 2.4GB + T3PO: 10.0GB)" line.
    var settingsEstimatedMemoryGB: Int {
        var total = 0
        if transcriptionEngineKind == .model, let variant = currentTranscriptionModelVariant {
            total += variant.recommendedMemoryGB
        }
        if translationEngineKind == .model, let variant = currentTranslationModelVariant {
            total += variant.recommendedMemoryGB
        }
        return total
    }
}

/// One-line pointer at the top of 语音输入 / 快捷翻译: their languages are
/// set in 通用 → 语言, so link there instead of leaving the user to hunt.
struct LanguageSettingsHint: View {
    @EnvironmentObject private var navigation: SettingsNavigationState

    var body: some View {
        HStack(spacing: 4) {
            Text("语言在「通用 → 语言」中设置。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("去通用设语言") { navigation.open(.general) }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 4)
    }
}
