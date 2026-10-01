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
| Recording feature | 转录（开始转录 / 停止转录） | Live transcription | `RecordingSession` |
| One saved recording | 转录记录 | Transcript | `RecordingSessionRecord` |
| Window listing transcripts | 历史记录 | History | `SessionListView` |
| Translation engine for transcription | 转录翻译引擎 | — | `ProviderCatalog` |
| Translation engine for Quick Translate | 快捷翻译引擎（可「跟随转录设置」） | — | `SelectionTranslationEngine` |
| macOS Translation framework engine | 系统翻译 | System translation | `system.translation` |
| macOS Speech framework engine | 系统语音识别 | System speech recognition | `system.speech` |
| Model download/delete UI | 模型库（设置标签页，菜单「模型库…」） | Model Library | `ModelManagementView` |
| Memory used by loaded models | 内存 | Memory | — |
| Global key bindings | 快捷键 | Shortcuts | `GlobalShortcut` |
| Status-bar icon + menu | 菜单栏 | Menu bar | `MenuBarExtra` |
| Settings tabs | 语音与引擎 · 模型库 · 语言与字幕 · 快捷翻译 · 关于 | — | `SettingsTab` |

Rules: never say plain "floating panel" / "悬浮窗" / "面板" without the
qualifier above; there is no "main window" (the app is menu-bar only);
don't use 托盘, 转写, 录音 (for the feature), 显存, 会话.
