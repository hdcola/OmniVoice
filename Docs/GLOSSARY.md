# Glossary (命名规范)

Use these names in UI copy, docs, CHANGELOG and PRs. Code identifiers are
intentionally unchanged (renaming them would break persisted settings).

| Concept | 中文 (UI) | English | Code |
|---|---|---|---|
| Live-transcript window | 字幕悬浮窗 | Caption panel | `FloatingTranscriptPanel` |
| Quick Translate window | 翻译面板 | Translation panel | `SelectionTranslationPanel` |
| Selection + screenshot translation, as a whole | 快捷翻译 | Quick Translate | `SelectionTranslation*` |
| ⌥A action | 划词翻译 | Translate selection | `translateSelection` |
| ⌥S action | 截图翻译 | Translate screenshot | `captureText` |
| Recording feature | 转录（开始转录 / 停止转录；进行中显示「转录中」） | Live transcription (Start Transcription / Stop Transcription; Transcribing) | `RecordingSession` |
| Voice-to-text typing at the cursor | 语音输入 | Dictation (never "Voice input") | `DictationController` |
| One saved recording | 转录记录 | Transcript | `RecordingSessionRecord` |
| Window listing transcripts | 历史记录 | History | `SessionListView` |
| Translation engine for transcription | 转录翻译引擎 | Transcription translation engine | `ProviderCatalog` |
| Translation engine for Quick Translate | 快捷翻译引擎（系统翻译 / 跟随转录翻译引擎） | Quick Translate engine (System translation / Follow transcription translation engine) | `SelectionTranslationEngine` |
| Local ASR engine on audio.cpp (large models, now R2T2) | audio.cpp 本地引擎 | audio.cpp local engine | `model.r2t2` / `ModelTranscriptionProvider` |
| Local ASR engine on sherpa-onnx (small streaming models) | sherpa-onnx 本地引擎 | sherpa-onnx local engine | `model.sherpa` / `SherpaTranscriptionProvider` |
| First-run wizard (also re-run from Settings) | 新手引导（三步：权限与开关 → 识别模型 → 翻译模型） | Onboarding (Permissions and switches → Speech recognition model → Translation model) | `OnboardingView` |
| macOS Translation framework engine | 系统翻译 | System translation | `system.translation` |
| macOS Speech framework engine | 系统语音识别 | System speech recognition | `system.speech` |
| Model download/delete UI | 模型库（设置标签页，菜单「模型库…」） | Model Library | `ModelManagementView` |
| Memory used by loaded models | 内存 | Memory | — |
| Global key bindings, all set in one section (Settings → General → Shortcuts, with double ⌘C and the Dictation trigger key) | 快捷键（设置「通用」中的分组） | Shortcuts | `GlobalShortcut`, `ShortcutsSettingsSection` |
| Key held or pressed to dictate | 语音输入触发键 | Dictation trigger key | `DictationTriggerKey` |
| Status-bar icon + the popover it opens | 菜单栏 | Menu bar | `MenuBarExtra`, `MenuBarContentView` |
| ⌥R action (global shortcut) | 开始/停止转录 | Start/Stop Transcription | `toggleTranscription` |
| Language the app UI is shown in (Settings → General) | 界面语言（跟随系统 / English / 简体中文；重启后生效） | Interface language (Follow system) | `AppLanguage` |
| Settings row granting Automation access to Music/Spotify for pausing during dictation | 直接控制 Music 和 Spotify | Control Music and Spotify directly | `PlayerAccessRow`, `AppleEventPlayerController` |
| Labeling who said each row of a live transcription (switch in the Caption panel, the menu bar popover and Settings → Speech Recognition) | 区分说话人 | Identify speakers | `SpeakerTagger` |
| A person told apart by voice, shown as a label on a row | 说话人（未命名时显示“说话人 A”“说话人 B”） | Speaker (“Speaker A”, “Speaker B” until named) | `TranscriptLine.speaker`, `UtteranceRecord.speaker` |
| A speaker's voice and name kept for future transcriptions | 已记住的声音 | Remembered voices | `SpeakerProfile`, `SpeakerProfileStore` |
| Reviewing remembered voices for mixed-up samples and look-alike names, with merge / split (Settings → Speech Recognition → Remembered voices) | 整理已记住的声音 | Tidy Up Remembered Voices | `SpeakerOrganizerView`, `SpeakerProfileIssue` |
| Settings tabs (toolbar tabs; the Caption panel's settings are on Speech Recognition) | 通用 · 语音识别 · 语音输入 · 快捷翻译 · 模型库 · 关于 | General · Speech Recognition · Dictation · Quick Translate · Model Library · About | `SettingsTab` |

Rules: never say plain "floating panel" / "悬浮窗" / "面板" without the
qualifier above; there is no "main window" (the app is menu-bar only);
don't use 托盘, 转写, 录音 (for the feature), 显存, 会话.
Engines are named after their runtime (audio.cpp / sherpa-onnx local engine);
R2T2, T3PO, Zipformer, Paraformer etc. are models, so never call them an
"engine" or use a model name as an engine name.
