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
| Translation engine for Quick Translate | 快捷翻译引擎（可「跟随语音识别设置」） | Quick Translate engine (Follow speech recognition) | `SelectionTranslationEngine` |
| Local streaming ASR engine (sherpa-onnx Zipformer) | 流式 Zipformer 模型 | Streaming Zipformer model | `model.sherpa` / `SherpaTranscriptionProvider` |
| macOS Translation framework engine | 系统翻译 | System translation | `system.translation` |
| macOS Speech framework engine | 系统语音识别 | System speech recognition | `system.speech` |
| Model download/delete UI | 模型库（设置标签页，菜单「模型库…」） | Model Library | `ModelManagementView` |
| Memory used by loaded models | 内存 | Memory | — |
| Global key bindings | 快捷键 | Shortcuts | `GlobalShortcut` |
| Status-bar icon + menu | 菜单栏 | Menu bar | `MenuBarExtra` |
| Language the app UI is shown in (Settings → General) | 界面语言（跟随系统 / English / 简体中文；重启后生效） | Interface language (Follow system) | `AppLanguage` |
| Settings tabs | 通用 · 语音识别 · 语音输入 · 快捷翻译 · 模型库 · 关于 | General · Speech Recognition · Dictation · Quick Translate · Model Library · About | `SettingsTab` |

Rules: never say plain "floating panel" / "悬浮窗" / "面板" without the
qualifier above; there is no "main window" (the app is menu-bar only);
don't use 托盘, 转写, 录音 (for the feature), 显存, 会话.
