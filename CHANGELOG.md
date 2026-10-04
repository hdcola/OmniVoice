# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added

### Changed
- perf(dictation): voice input opens the microphone as soon as the key goes down and replays the audio once the recognizer is ready, so the first words aren't lost during "正在准备识别引擎…"; the system engine also remembers its resolved locale, installed-assets check and audio format between dictations, shortening that wait

### Fixed

### Dependencies

### Documentation

### Tests

## [0.7.0] - 2026-10-03

### Added
- feat(dictation): translate what is dictated before it is typed — in 按一下开始 mode the voice input bubble shows the translation into 外语 for review (Return types it and presses Return, the trigger key only types it, Esc drops it, 输入原文 types what was said); it uses the engine chosen for selection translation, skips text already in 外语, falls back to the original when translating fails, and is switched on in Settings or with the button on the bubble; the update's 新功能 window announces it (#87)

### Changed

### Fixed
- fix(dictation): the voice-input bubble grows with what is said instead of cutting long text down to two lines — up to half the screen's height, then it shows the newest words (#86)

### Dependencies

### Documentation

### Tests
- test(dictation): cover deciding whether and into what a dictation is translated (#87)

## [0.6.3] - 2026-10-03

### Added
- feat(translation): read the source or the translation aloud with the macOS system voices — a play button beside each pane of the translation panel (the source's language is re-detected from what is in the pane), a notice with a shortcut to the system voice settings when no voice speaks the language, and, in Settings' 划词与截图翻译 card, an option to read finished translations automatically plus a speed setting; the update's 新功能 window announces it (#84)

### Changed

### Fixed

### Dependencies

### Documentation

### Tests
- test(translation): cover choosing the system voice for a language (#84)

## [0.6.2] - 2026-10-02

### Added
- feat(dictation): in 按一下开始，再按一下结束 mode, pressing Return instead of the trigger key ends the voice input, types the text and then presses Return (to send a chat message, run a prompt, …); the Return is swallowed while listening so it never reaches the app before the text does, needs the 辅助功能 permission voice input already asks for, and the other mode and a plain trigger-key tap behave as before; the update's 新功能 window announces it (#82)

### Changed

### Fixed

### Dependencies

### Documentation

### Tests

## [0.6.1] - 2026-10-02

### Added

### Changed
- refactor(panel): drop the unused full-width warning card from the target language picker — it is only used in the floating panel's control bar, where the warning is a glyph with a popover (no behavior change) (#78)
- feat(settings): 设置 now has one 语言 card — 我的语言, 外语, 转录方向 (听外语 / 说我的语言) and 自动检测外语 — replacing the separate 转录语言 and 快捷翻译语言 cards; 语音输入 gets its own 听写语言 (我的语言 / 外语 / 自动检测, the last only with a local model). In the floating panel the → between the source and target pickers is now a ⇄ button that swaps them; it is greyed out (with the reason in its tooltip) while recording and when the system recognizer can't recognize the swapped source; 自动 is kept across a swap (#77)
- refactor(settings): recording, 快捷翻译 and voice input now share one pair of languages — 我的语言 and 外语 — plus a transcript direction (听外语 / 说我的语言); the recording's source and target are derived from them, so a change in one place applies to all. Voice input gets its own language choice (我的语言 / 外语 / 自动, 自动 only with a local model). Existing settings are migrated once on first launch (快捷翻译's languages win if you customized them, otherwise the recording's target becomes 我的语言 and its source 外语; voice input keeps the language it used); the old keys are left in place. The settings and panel UI follow in a later change (#76)

### Fixed
- fix(panel): the floating panel's controls no longer fade out while one of its popovers (⇄ hint, 语言支持提示, 自动检测 explanation) is open, and fade out again after it closes if the pointer is away (#80)
- fix(panel): the ⇄ button in the floating panel now explains why it can't swap (recording, or a language the system recognizer can't take) in a popover when clicked, instead of a tooltip that this panel never shows (#79)

### Dependencies

### Documentation

### Tests
- test(settings): cover the language settings migration, direction swap and voice input language resolution

## [0.6.0] - 2026-10-02

### Added
- feat(dictation): 语音输入 — hold the right ⌥ Option key (or right ⌘ / ⌃, or tap to start and tap again to stop) in any app, speak, and the recognized text is typed at the cursor. Uses on-device system speech recognition with the language and microphone from 实时转录; a small bubble shows what it hears while you speak, and during a slow first start says what it is doing (准备识别引擎 / 下载语言识别资源 / 启动麦克风). Turning voice input on (and launching with it on, or switching the recognition language) also pre-installs the system recognizer's language assets in the background, so the first dictation doesn't wait on the download (skipped while a local model is loaded and will be borrowed instead; at launch it waits for the 启动时加载模型 preload to finish before deciding); 设置 shows the progress note meanwhile. Text goes in by pasting (the clipboard is saved and put back afterwards, and marked transient so clipboard managers skip it); with no Accessibility permission or in a secure field it stays on the clipboard with a notice. Taps under 0.3 s and ⌥ used as a modifier for another key are ignored, Esc cancels a dictation in either mode (even one still starting up), and one still running past its time limit ends by itself and types what it heard, so a lost key release can't leave the microphone open — 2 minutes by default, adjustable (1 / 2 / 5 / 10 minutes or no limit) in 设置/通用 › 语音输入 › 单次最长时长 for dictating long prompts. When 实时转录 uses a local model (R2T2) that is already loaded (e.g. via 启动时加载模型), voice input borrows that same recognizer instead of loading a second copy — more accurate, and the HUD says 本地模型 or 系统识别; with no model loaded, or while a recording is running, it uses system recognition. The 新功能 window introduces it to existing users, with a 开启 button. Off by default — turn it on in 设置/通用 › 语音输入, which asks for Input Monitoring, Accessibility and the microphone (#74)

### Changed

### Fixed
- fix(dictation): holding the left and right copy of the trigger modifier together (both ⌥) and releasing them no longer leaves voice input unable to trigger again; a missed key release is recovered from, and turning voice input off or changing its key/mode also cancels the pending time-limit timer (#74)
- fix(dictation): a system locale such as zh-Hans-CN (used when the recognition language is 自动 or unset and no local model is loaded) now maps to the recognizer's supported zh-CN instead of failing with 不支持此语言环境; the same lookup applies to 实时转录's system engine, and variants like en-AU fall back to en-US, while a Simplified-Chinese region the recognizer doesn't list (zh-Hans-SG) still gets zh-CN rather than the Traditional zh-TW (#74)
- fix(dictation): segments no longer gain a stray space before punctuation or between Chinese words when the engine pads the end of the previous one, and ’ » ” attach to the word before them (#74)

### Dependencies

### Documentation

### Tests
- test(dictation): cover the text assembler (segment joining incl. CJK), the hold/toggle trigger state machine when a loaded recognizer is lent to voice input and what is blocked meanwhile, Esc/reset in the trigger machine, and the thread-safe transcript (#74)

## [0.5.7] - 2026-10-02

### Added
- feat(settings): 设置/关于 has a 查看新功能 row that reopens the what's-new window with every note, for users who dismissed it or updated past several versions (#72)
- feat(onboarding): after an update that adds something worth opting into, the app shows a small 新功能 window once — for existing users it introduces 连按两次 ⌘C 翻译 (with a button to turn it on) and the re-runnable 新手引导; first runs and later releases without a new entry show nothing. New notes are added in `WhatsNewCatalog`; the notes carry 开启 / 重新运行 buttons, show 需要授权输入监控 when ⌘C ⌘C is on without the permission, and Esc closes the window (#70)
- feat(onboarding): 设置/通用 now has a 新手引导 card with a "重新运行" button that reopens the first-run wizard (permissions, run mode, optional ⌘C ⌘C translation) — for users who skipped it or want to revisit it after an update; clicking a run mode there now actually switches the engines (a re-run that leaves the mode alone changes no engines and downloads nothing) (lightweight → system engines, 高精/均衡 → that bundle's models); the button is disabled while recording and the button reads 完成 when nothing needs downloading (#69)
- feat(selection): pressing ⌘C twice in quick succession (within 0.35 s) in another app now translates the copied text in the quick-translate panel — it reads the pasteboard the app just filled, so it works on pages where ⌥A can't read the selection. Off by default (opt-in): turn it on in the first-run wizard or 设置/通用 › 划词与截图快捷键. Needs the Input Monitoring permission, which is only requested when you switch the option on, never silently at launch. Text a password manager marks as concealed/transient is never sent to the translator, Caps Lock doesn't stop the shortcut, any other key pressed between the two ⌘C presses cancels the pair, and a panel already open on another screen moves to the screen you are working on (#68)
- feat(models): R2T2 now offers three precisions to choose from in 设置/模型库 — Q4_K_M (1.1GB, ~1.8GB peak memory; community quantization, not an official NetEase release) for low-memory Macs, Q8_0 (default, ~3.1GB peak) and F16 (3.8GB, ~4.7GB peak) for the best quality on high-memory Macs. Both new files were downloaded, checksum-verified and run end-to-end against audio.cpp, transcribing English and Chinese test speech identically to Q8_0. The recommended bundles still use Q8_0 (#64)

### Changed

### Fixed
- fix(selection): ⌥A no longer comes up empty on large web pages (e.g. HuggingFace model pages) — when the app is too slow to answer the Accessibility selection query, the reader now falls back to copying with ⌘C instead of giving up
- fix(models): deleting the selected model variant (e.g. R2T2 Q4_K_M, or HY-MT1.5 Q8_0) while another variant of the same engine is still downloaded now switches the selection to the downloaded one, instead of leaving it on the deleted file and failing with "尚未下载" on the next preload/recording (#66)
- fix(models): the "搭配 R2T2 识别引擎" nudge shown after downloading a translation model now checks whether *any* R2T2 precision is downloaded, not just Q8_0 — so a user who picked R2T2 Q4_K_M or F16 is no longer pushed to download a 2.3GB Q8_0 on top (#64)

### Dependencies

### Documentation
- docs(release): add `Docs/RELEASING.md` describing how a version is cut, built, tagged, published and bumped in the Homebrew cask, and point to it from `AGENTS.md` (#71)

### Tests
- test(onboarding): add `WhatsNewTests` covering which what's-new entries show for a first run, a never-seen update, partly seen and fully seen users (#70)
- test(selection): add `DoubleCopyDetectorTests` covering the ⌘C ⌘C timing window, consumed pairs, reset and a backwards clock and key bounce, including a bounce right after a completed double and a continuous train of bounces (#68)
- test(models): cover `ProviderCatalog.replacementVariantID` and the session-level variant reselection after a delete / at launch (#66)
- test(models): add `R2T2VariantCatalogTests` pinning the R2T2 variant list/default order, that each has a SHA-256 + `.gguf` HF URL, size/memory ordering, and that the bundles keep Q8_0 (#64)

## [0.5.6] - 2026-10-02

### Added
- feat(history): multi-select (⌘/Shift-click, ⌘A) with batch delete via ⌫, context menu or the toolbar menu; "delete records older than 30/90 days" cleanup; in-progress recordings are always skipped (#62)

### Changed
- feat(history): history sidebar (min width 340) groups by 今天/昨天/本周/本月/month, shows the first utterance instead of a default date title, and condenses duration · languages · count into one line; sidebar width is now bounded; rows show clock time (weekday + time this week, date + time earlier); cleanup menu items disable when nothing matches and the confirmation shows the record count (#62)

### Fixed
- fix(history): ⌫/batch delete only acts on selected rows that are still visible under the current search filter (#62)
- fix(history): renaming an unnamed record pre-fills the full first sentence instead of the truncated list label, so saving no longer cuts it off; exported Markdown and the detail-page title use the full first sentence, not the truncated list label (#62)
- fix(history): recordings that captured nothing (0 句) are no longer saved; existing ones can be removed with "清理空记录" in the history toolbar menu (#62)
- fix(history): only the record being recorded (or still starting up) right now is protected from deletion; records a crash/force-quit left without an end time are shown normally and can be deleted (#62)
- fix(session): a new session's default title and start time now share one timestamp, so the history list can reliably tell a default title from a rename (#62)

### Dependencies

### Documentation

### Tests
- test(history): cover display-title fallback, including a leading empty utterance (#62)

## [0.5.5] - 2026-10-01

### Added
- feat(build): `Scripts/build_app.sh` signs with the `OmniVoice Dev Signing` certificate when it is in the keychain (override with `SIGN_IDENTITY`, `-` forces ad-hoc; falls back to ad-hoc without it), so macOS keeps mic/speech/screen-recording permissions across updates (#60)

### Documentation
- docs(repo): add `Docs/SIGNING.md` explaining why permissions reset after upgrades and how to create and back up a stable signing certificate (#60)

## [0.5.4] - 2026-10-01

### Added
- feat(settings): "断句停顿时长" (0.3–3.0s, default 0.6) and "静音电平阈值" (-70…-20 dB, default -40) sliders under 识别引擎 for model ASR engines, applied live mid-recording, to tune how easily speech is split into utterances (#58)

### Tests
- test(audio): cover `UtteranceSegmenter` default timing and the live-tunable pause/level thresholds (#58)

## [0.5.3] - 2026-10-01

### Added
- feat(notifications): clicking a model download notification opens Settings → 模型库 (#56)
- feat(notifications): send a system notification when a model download finishes or fails while the app is in the background, with a "完成时发送系统通知" toggle in Settings (#55)

## [0.5.2] - 2026-10-01

### Added
- feat(launch): new "启动" card in Settings → 通用 and the first-launch window — "开机时自动启动" (macOS login item) and "启动时加载模型" (不加载 / 仅翻译模型 / 翻译和识别模型); onboarding defaults the choice to the run mode picked (均衡 → 仅翻译, 高精 → 全部) and starts loading once the downloads finish (#50)
- feat(session): `preloadModel(scope:)` can load just the translation engine; a later recording adopts it and loads only the recognizer, and the memory status reads "仅翻译模型已载入" (#50)

### Changed
- refactor(settings): rename the `org.omnivoice.*` UserDefaults keys and dispatch queue labels to `org.hdcola.omnivoice.*`; previously saved settings (engines, languages, shortcuts, panel layout, onboarding state) are not migrated and reset to defaults

### Documentation
- docs(repo): drop the R2T2 "requires an upstream audio.cpp patch" notes from `README.md` and the code/progress docs now that the fix is merged upstream and the pinned checkout carries it

## [0.5.1] - 2026-09-30

### Added
- feat(settings): card-style Settings modelled on SnapTra Translator — a pill tab bar (⌘1–⌘3) instead of the system toolbar tabs, compact cards with their titles inside, shortcuts drawn as keycaps, "已授权" / "去授权" status pills, and a narrower 520pt window that stays the same size on every tab (#47)

### Changed
- refactor(settings): merge "语音与引擎", "语言与字幕" and "快捷翻译" into one "通用" tab (tabs are now 通用 · 模型库 · 关于) — all system permissions (麦克风 / 屏幕录制 / 辅助功能) at the top, then 快捷翻译, 实时转录 (识别引擎, 转录翻译引擎, 转录语言, 内存) and 字幕悬浮窗; the engine pickers are now labeled "识别引擎", "转录翻译引擎" and "快捷翻译引擎" (#47)
- refactor(settings): restyle "模型库" to match — recommended bundles and every model variant as divider-separated rows inside cards, status pills instead of emoji, accent capsule buttons (下载 / 取消 / 删除 / 一键下载); download, activation and failure behavior is unchanged (#47)
- refactor(settings): the "通用" tab's inline model downloads and memory console buttons use the same accent capsule as "模型库", and a disabled capsule now dims (#47)
- refactor(onboarding): restyle the first-launch window like Settings — app icon header, permission cards with status pills for 麦克风, 系统音频录制 and the newly listed 辅助功能 (refreshed live while the window is open), the three run modes as a vertical radio list with size notes instead of a horizontally scrolling card row, and an action bar pinned below the content; window is 520pt wide (#47)
- refactor(settings): redesign "关于" — centered app icon, name, version and tagline, a GitHub Star card, and a link list (GitHub / 版本发布 / 反馈问题) (#47)

### Fixed
- fix(settings): "转录语言" rows now match the other cards (title and subtitle left, picker right-aligned); the target-language warning moves into a glyph with the same "一键切换为系统翻译" popover as the floating panel (#47)
- fix(settings): cards use a faint tint in light mode (a white card disappeared on the white window) and the "关于" footer text is darker (#47)
- fix(onboarding): the microphone and system-audio rows' "去授权" now open System Settings once access has been denied, instead of silently doing nothing (#47)

### Documentation
- docs(readme): point the Quick Translate settings location at Settings → 通用 (#47)
- docs(readme): re-introduce the app in the README intro and PROGRESS's "What this is" in terms of quick translate (划词翻译 ⌥A / 截图翻译 ⌥S into the 翻译面板), not just the speech caption panel (#45)

## [0.5.0] - 2026-09-30

### Added
- feat(settings): new "启动时显示悬浮窗" toggle in "语言与悬浮窗" (default on) — turn it off to stop the live-transcript panel opening on every launch; starting a recording still shows it, and the menu bar can open it manually (#42)
- feat(selection): select text in any app and press ⌥A to translate it in a new floating panel — Cida-style: the selection is read via Accessibility (falling back to a synthetic ⌘C that restores the pasteboard), text in "my language" goes to the configured foreign language and everything else comes into "my language", ⏎ translates / ⇧⏎ inserts a newline / Esc hides, and results survive hiding the panel (#40)
- feat(selection): press ⌥S to frame a region of the screen and translate its text, recognized on-device with Vision (needs Screen Recording permission) (#40)
- feat(selection): both features run fully on-device on either the system Translation framework or HY-MT1.5; paragraphs are translated one at a time so long selections fill in progressively and keep their line breaks and list markers (#40)
- feat(settings): new "选词翻译" settings tab — recordable global shortcuts, engine (defaulting to "跟随录音设置", which uses the recording's engine and substitutes HY-MT1.5 — or the system engine if it isn't downloaded — for T3PO), my/foreign language, and Accessibility/Screen Recording permission status; the menu bar gains "打开翻译面板" and "截图翻译" (#40)
- feat(translation): `HYMT15Translator.translateText(_:targetLanguage:sourceIsChinese:)` one-shot text translation using HY-MT1.5's own model-card prompt, independent of the streaming transcript path (#40)

### Changed
- refactor(ui): unify naming — "字幕悬浮窗" (live transcript) vs "翻译面板", "快捷翻译" (formerly "选词翻译") covering "划词翻译" (⌥A) and "截图翻译" (⌥S), "模型库", "转录记录", "系统翻译", "系统语音识别", "内存" (was 显存), "跟随转录设置"; settings tab "语言与悬浮窗" is now "语言与字幕"; see Docs/GLOSSARY.md (#43)
- refactor(translation): HY-MT1.5 weights are now shared through a reference-counted `HYMT15ModelPool`, so a HY-MT1.5 recording and the selection panel use one loaded copy instead of two; the panel releases its hold after 5 idle minutes (#40)
- refactor(settings): replace the "长句提前翻译阈值" `Stepper` + three-line explanatory paragraph with a single labeled numeric `TextField` (full explanation moved to a "?" tooltip); keep the "翻译输出"/"引擎运行与显存状态" sections always present and swap only their interior content per selected engine, and animate the remaining engine-switch layout changes, instead of whole sections popping in and out (round-5 user report)

### Fixed
- fix(ui): the floating panel's top control bar now adapts to the panel width — copy/close stay pinned to the right edge (no empty gap when wide), language pickers keep their natural width instead of stretching, and when narrow the display-mode/font-size pickers fold into a menu and the language labels truncate instead of controls being clipped (#41)
- fix(ui): hovering the floating panel's edges/corners now shows the matching resize cursor, and dragging there resizes the panel — previously only a thin strip outside the visible edge resized it, with no cursor feedback, because the window server ignores cursor changes from a background app (the non-activating panel's app is never active while hovered) (#41)

### Dependencies

### Documentation
- docs(glossary): add Docs/GLOSSARY.md naming rules; refresh README and RELEASE_TESTING terminology (#43)
- docs(readme): document ⌥A selection translation and ⌥S screenshot translation (#40)

### Tests
- test(selection): `SelectionTextChunker`, `SelectionLanguageDirection`, `SelectionTranslator` (with a fake model backend), `RecognizedTextLayout`, and HY-MT1.5's text prompt (#40)

## [0.4.0] - 2026-09-30

### Added
- feat(translation): add `EntityMasker` to protect technical terms, URLs, paths, CLI flags, and code identifiers from translation distortion using `⟦n⟧` placeholders (#38)
- feat(translation): add prompt contract (data isolation, zero commentary) and sliding context window to `HYMT15Translator` inspired by Cida (#38)

### Changed
- feat(ui): visually differentiate committed transcript text from live tentative/preview text in `FloatingTranscriptView` using inline styled concatenation (#38)
- chore(ci): add a GitHub Actions workflow that builds `third_party/{audio.cpp,llama.cpp}` (cached by their pinned commits) and runs `swift build` on every push to `main` and every pull request as a compile/link regression gate; `swift test` is deliberately not run in CI yet — every Xcode 26.x on the current macOS runner image crashes compiling this package's Swift Testing suites (a runner-image toolchain bug, tests pass locally on Xcode 27), and XCUITest coverage under `UITests/` also needs a one-time interactive Accessibility-permission grant an unattended runner can't provide (#37)

### Fixed
- fix(translation): resolve duplicate identifier masking and safe budget trimming to prevent corrupted placeholders (#38)
- fix(translation): clear HY-MT1.5 context history when the target language changes, and strip echoed `Current:`/`Translation:` labels from context-prompted output (#38)
- fix(translation): only unwrap quotes that wrap the whole output, keep single-line fenced output, and count translations toward the history cap while always keeping the latest pair (#38)
- fix(translation): `EntityMasker` no longer masks ordinary prose (`e.g`, `U.S`, `Mr.Smith`, `and/or`), and restores placeholders the model garbled instead of leaving bare numbers (#38)
- fix(translation): strip a fenced code block wrapping echoed context (or just the answer after it), and drop an echoed `Current:` source line when a `Translation:` line follows it, instead of leaking either into the transcript (#38)
- fix(translation): `EntityMasker` masks `-c`/`-h`-style single-letter flags and flags with no preceding space (common in space-less CJK ASR output) without mistaking a negative number for one; masks `~/`, `./`, `../` single-segment paths and `__dunder__` identifiers; trims trailing sentence punctuation off masked URLs/paths (#38)
- perf(translation): precompile `EntityMasker`'s regular expressions once instead of on every `mask`/`restore` call (#38)
- fix(translation): `EntityMasker` no longer masks "a.m."/"p.m." as a filename (requires a 2+ character basename), masks combined short CLI flags like `-rf`/`-czvf`/`-Wall`, and keeps a balanced parenthesis inside a masked URL (e.g. a Wikipedia link) while still trimming one that only wraps the URL (#38)
- fix(translation): `cleanOutput` strips a leaked `Translation:`-style label even on a context-free turn, and recognizes the fullwidth Korean `현재：`/`번역：` label variants (#38)
- fix(translation): `EntityMasker`'s CLI-flag value no longer swallows trailing CJK text with no separating space (`--output=foo选项`), and its trailing-punctuation trim now applies to flags too (#38)
- fix(translation): `cleanOutput` strips a markdown fence that comes after a leaked `Translation:` label, not just one wrapping the whole reply or only the labelled answer; `stripContextEcho` now discards any echoed lines (e.g. a repeated `Source:`) between `Current:` and a following `Translation:` instead of leaking them; and it unwraps CJK corner brackets (`「...」`/`『...』`) the same way it already does ASCII/curly quotes (#38)
- fix(translation): `cleanOutput` now re-applies fence/label/quote stripping until stable, so a leaked `Translation:` label hidden inside wrapping quotes (`"Translation: Hello world"`) is fully unwrapped instead of surfacing the label; `EntityMasker`'s CLI-flag value now allows `:`, so a flag value that's itself a URL or host:port (`--url=https://...`, `--addr=127.0.0.1:8080`) is masked whole instead of splitting and leaving an unmasked remainder (#38)

### Dependencies

### Documentation

### Tests
- test(translation): add unit test suites `EntityMaskerTests` and `HYMT15PromptContractTests` (#38)
- test(uitests): stand up an xcodegen-generated UITest target for the SPM app with coverage for onboarding, settings, and floating window (#36)

## [0.3.1] - 2026-09-29

### Added
- feat(settings): milestone 1 of `Docs/UX-SETTINGS-MODEL-MANAGEMENT.md` — always list every ASR/translation engine (downloaded or not, labeled "（未下载 · 点击配置）", routing to "模型管理" on selection); keep "自动检测" visible-but-disabled under the system ASR engine instead of hiding it; warn (with a one-click switch to the system translation engine) when a local-model translation engine is paired with a target language `ModelLanguageMapping` would silently fall back to Chinese for; hide the "长句提前翻译阈值" stepper entirely under the system ASR engine instead of showing it disabled
- feat(models): milestone 2 of `Docs/UX-SETTINGS-MODEL-MANAGEMENT.md` — "模型管理" now auto-switches the matching engine category (ASR/translation) to a freshly-downloaded model when it's still on its system default, with an undo-able banner and a companion-model download nudge; `ModelVariant`/`EngineDescriptor` gained user-facing `summary`/`badge`/`recommendedMemoryGB` fields, rendered as rich model cards; two one-click recommended bundles (标准实时双语方案/轻量方案) sit above the model list; `ModelDownloadManager` now publishes per-variant `downloadStats` (instantaneous MB/s + ETA), shown under each downloading card's progress bar
- feat(settings): milestone 3 of `Docs/UX-SETTINGS-MODEL-MANAGEMENT.md` — `SettingsView` is now a 560×480 `TabView` ("语音与引擎"/"模型库管理"/"语言与悬浮窗"/"关于"), replacing the separate 440pt-wide "模型管理" window; selecting an undownloaded engine in "语音与引擎" shows an inline download row (percent/progress/speed/ETA) instead of bouncing to another window; a new "引擎运行与显存状态" console exposes `session.preloadModel()`/`unloadModels()` with a status light and an estimated-memory readout, alongside the floating panel's existing affordance; the menu bar's "模型管理…" now opens Settings directly on the "模型库管理" tab via a shared, `UserDefaults`-persisted `SettingsNavigationState`
- feat(onboarding): milestone 4 of `Docs/UX-SETTINGS-MODEL-MANAGEMENT.md` — a first-run "欢迎使用 OmniVoice" window (permission status, 极速轻量/高精离线大模型 mode choice, one-click start) shown once per install, persisted to `UserDefaults`; downloads in "模型库管理"/the inline "语音与引擎" row now pre-flight available disk space (`ModelDownloadManager.insufficientDiskSpaceWarning(for:)`) before starting a transfer instead of only failing partway through; a network interruption or checksum failure now renders as an inline retry card on the affected model's own row/card, with a "复制下载链接" fallback, instead of a modal alert
- feat(onboarding): add a third "均衡低内存模式" card to the first-run wizard's mode choice, between "极速轻量模式" and "高精离线大模型模式" — downloads `bundle.lightweight` (R2T2 识别 + HY-MT1.5 翻译，约 3.4GB) and auto-activates both engines on completion, reusing the same bundle-download/disk-preflight/recording-guard machinery the other two modes already use; the three cards now sit in a horizontal `ScrollView` so all of them stay reachable at the wizard's fixed window width instead of being squeezed or clipped (round-4 user report)
- feat(settings): give "长句提前翻译阈值" its own titled "翻译输出" section (with an explanatory caption of what it actually does, and a `.help` tooltip) in "语音与引擎", instead of a bare `Stepper` sitting unexplained between the translation engine's pickers; same per-engine visibility as before (hidden under T3PO or the system ASR engine) (round-4 user report)

### Changed

### Fixed
- fix(settings): "模型库管理" tab's content is now wrapped in a `ScrollView` — with both recommended-bundle cards, every ASR/translation model variant, and their download status all rendered, it routinely exceeded the Settings window's fixed 560×480 size and the bottom cards/buttons were clipped off and unreachable; every card now stays reachable by scrolling (round-4 user report)
- fix(models): audit recommended-bundle status/remaining-download logic — extracted the per-bundle download-state computation into a new, unit-tested `ModelBundle.status(isDownloaded:)` (see `ModelBundleStatusTests`), which resolves strictly against each bundle's own `variantIDs` (never a sibling quantization or another variant of the same engine family, and never a variant counted twice), so "已下载 X/Y" and "一键下载剩余组件" always refer to only that bundle's own missing components. Each bundle card also now lists its member variants individually (✅/⬜) instead of just a bare count — two recommended bundles can legitimately share a variant (both currently include R2T2 Q8_0), so downloading it via one bundle correctly, and now visibly, counts toward the other's total too, instead of reading as a contradictory "already complete" with no explanation of why (round-4 user report)
- fix(ux): address round-2 review must-fix finding — `OnboardingView.finish(startDownload:)` used to mark onboarding complete and call `onFinished()` (which closes/releases the window) unconditionally, even when `startBundleDownload()` had just set `diskSpaceWarningMessage` for an insufficient-disk-space failure; the window closed in the same run-loop turn, destroying the `.alert` before it could render and permanently skipping the wizard on future launches. `startBundleDownload()` now returns whether it actually started something (or had nothing to do), and `finish(startDownload:)` only completes/closes on success, leaving the window open with its alert visible and the wizard retriable on a disk-space failure
- fix(ux): address Docs/UX-REVIEW-ROUND-1.md's 5 must-fix findings — `TargetLanguagePicker`'s "一键切换为系统翻译引擎" button no longer fires mid-recording (was tearing down the active `translationProvider` via `discardLoadedModelsIfStale()`); the same picker now renders as a compact popover-triggered warning icon inside the floating panel's single-row control bar instead of a full multi-line card that blew its height out to 120pt+; `ModelManagementView`'s post-download auto-activation and `OnboardingView`'s post-download engine activation both now skip while a recording is active, instead of force-switching the engine an active session is using; `OnboardingView`'s "高精离线大模型模式" download now pre-flights combined disk space before starting (via `ModelDownloadManager.insufficientDiskSpaceWarning(forTotalMB:)`) and actually activates R2T2/T3PO once each finishes, instead of silently no-op'ing on either; `ModelDownloadManager.handleProgress`'s speed/ETA computation and `downloadStats` publish now happen only on throttle-surviving updates, instead of unconditionally ahead of the throttle check (which was firing `objectWillChange` hundreds of times per second on a fast connection)

### Dependencies

### Documentation

### Tests
- test(models): add `ModelBundleStatusTests`, pinning the round-4 recommended-bundle report's exact scenario (R2T2 Q8_0 downloaded, T3PO Q5_K_M not) plus sibling-quantization and full-completion cases against `ModelBundle.status(isDownloaded:)`
- test(uitests): stand up `UITests/` — an xcodegen-generated, unhosted XCUITest target that drives the real `build/OmniVoice.app` via `XCUIApplication(url:)`, with a passing smoke test confirming it launches the app and reads its onboarding window; `swift build`/`swift test` for the SPM package are untouched (see `UITests/README.md`)
- test(uitests): add XCUITest coverage for onboarding's finish/skip flow, the floating panel's control-bar auto-hide and drag-vs-control-click hit testing, the Settings disabled-state matrix's idle baseline, and the model preload control staying in sync between Settings and the floating panel — see `UITests/README.md` for what's fully covered vs. scoped down and why

## [0.3.0] - 2026-09-29

### Added

- feat(history): support deleting (swipe, context menu, or ⌫) and renaming past recordings, and show relative-time, duration, language-pair, and utterance-count tags on each row (Docs/UI_UX_DESIGN_PROPOSAL.md §3.3) (#30)
- feat(history): add "复制全文"/"仅复制译文" clipboard actions to the session detail toolbar, and enable text selection on its transcript (#30)
- feat(history): show a small relative "[mm:ss]" timestamp before each transcript line in the session detail view (§3.3.C) (#30)
- feat(panel): enable text selection on the floating panel's transcript, with a per-line hover "复制本句" button and a panel-wide "复制全文" button (§3.1.D) (#30)
- feat(panel): add a one-tap deeplink to the relevant System Settings privacy pane when microphone or screen-recording permission is missing (§3.4.C) (#30)
- feat(menubar): show a pulsing red recording indicator in the menu bar icon while a session is running, so recording state stays visible even with the floating panel hidden (§3.2) (#30)
- feat(menubar): show the live elapsed-time readout in the menu bar dropdown too, not just the floating panel (§3.1.E/3.2) (#30)
- feat(panel): add auto-hiding controls (mouse-leave fades the control/status bars after 2s), a display-mode switch (双语对照/仅译文/仅原文), font-size presets (标准/大/特大), and a live elapsed-time readout (§3.1.A–C, E) (#30)
- feat(scripts): add `Scripts/setup_third_party.sh`, automating the `third_party/{audio.cpp,llama.cpp}` clone/cmake setup documented in `Docs/MODEL_ENGINE_SETUP.md` — idempotent (safe to re-run; leaves an existing pinned checkout, an already-built target, or already-downloaded weights alone), with `--with-models`/`--force`/`--skip-audio`/`--skip-llama` flags (#31)

### Changed

### Fixed

- fix(panel): stop the auto-hide controls fade from unpinning transcript auto-scroll — toggling `controlBar`/`statusBar` in/out of the view tree shrank `TranscriptListView`'s container height without changing its content height, which `.onScrollGeometryChange` misread as the user scrolling away just from a mouse hover; both bars now stay in the hierarchy and fade via `.opacity` instead (#30)
- fix(panel): keep every control bar element visible at the panel's 380pt minimum width — the timer/display-mode/font-scale controls previously pushed its natural width past 600pt, clipping controls on a narrow panel; the display-mode/font-scale pickers now size to their content instead of a fixed 90pt/70pt frame, and the whole bar scrolls horizontally as a fallback instead of clipping (#30)
- fix(history): reset `selectedID` after deleting the currently-selected session, so the detail pane falls back to the "选择一个会话" placeholder instead of rendering blank, and a subsequent ⌫ keeps working (#30)
- fix(history): prevent deleting the still-in-progress recording from the History window — its swipe action/context-menu item/⌫ handler are now hidden/no-op while `endedAt == nil`, since that session's SwiftData model object is the same live object `RecordingSession` is still appending to (#30)
- fix(panel): schedule the elapsed-time timer on `RunLoop.Mode.common`, not just `.default` — it previously froze while the main run loop was in `.eventTracking` mode (dragging the panel, an open menu, actively interacting with a control) (#30)
- fix(panel): show a dimmed/italicized placeholder for a line whose translation hasn't arrived yet in "仅译文" display mode, instead of rendering a completely empty row (#30)
- fix(session): move `microphonePermissionNeeded`/`screenRecordingPermissionNeeded`'s reset to the very top of `start()`, before its early-return guards, so a stale permission flag from a previous failed attempt can't persist through an unrelated later failure (#30)
- fix(panel): give the microphone and screen-recording permission buttons distinct icons/tooltips instead of two identical gear icons with the same tooltip (#30)
- fix(history): fall back to showing the raw code for an unrecognized (but non-nil) `sourceLanguageCode`, instead of incorrectly showing "自动" (which should only mean auto-detect) (#30)

### Dependencies

### Documentation

### Tests

## [0.2.0] - 2026-09-29

### Added

- feat(translation): add Tencent's HY-MT1.5 1.8B as a second, one-shot in-process local translation engine (`model.hymt15`) alongside T3PO — a genuinely low-memory option (~1.06GB/~1.82GB vs. T3PO's ~9.8GB) (#27)
- feat(audio): add a "无" microphone option for system-audio-only recording (a meeting/lecture played through the Mac's own output, no one talking into a mic) (#27)
- feat(translation): make translation commit timing user-configurable — a "翻译提交策略" picker for T3PO's WAIT/TRANS bias, and a directly adjustable "长句提前翻译阈值" character count for one-shot engines (HY-MT1.5/system translation), so a single long, pause-free utterance no longer waits for the whole thing before any translation shows up (#27)
- feat(app): add macOS application icon (`AppIcon.icns`) and configure bundle packaging in `Info.plist` and `build_app.sh` (#28)

### Changed

- chore(settings): show a caption under "长句提前翻译阈值" clarifying it has no effect while the system transcription engine is selected (it only reports committed text once a segment closes, so there's no still-talking window left for an early translation to beat) (#27)

### Fixed

- fix(translation): fix `SystemTranslationProvider` misrouting/losing a translation across back-to-back utterances — an early, still-in-flight translation request could have its result committed into the wrong (following) segment's row, or a segment's row-close signal could be dropped entirely if another utterance started before that request resolved (#27)
- fix(translation): insert a space between multiple translation commits appended to the same row for a space-separated target language (English/Korean), so an early-translated fragment and the rest of the sentence don't run together with no separation (#27)
- fix(inference): avoid a potential out-of-bounds read in `LlamaGenerationSupport.applyChatTemplate`'s buffer-resize retry (missing room for the C string's null terminator, including when the formatted prompt's length exactly matched the initial buffer size) and accumulate generated tokens as raw bytes before decoding to UTF-8 once, instead of per token (which could otherwise split a multi-byte CJK character across two tokens and corrupt it) (#27)
- fix(inference): retry `llama_token_to_piece` with a larger buffer instead of silently dropping a token's contribution to the output when its piece doesn't fit the default 64-byte buffer (#27)
- fix(translation): reset `SystemTranslationProvider`'s in-flight request tracking on `start(config:)`/`stop()`/a mid-recording target-language change, so a request left unresolved by an interrupted prior recording or an abandoned bridge stream can't affect a later one reusing the same provider instance (#27)
- fix(translation): stop `SystemTranslationProvider` from permanently losing buffered text when an early translation triggers before the floating panel has finished mounting (#27)
- fix(inference): construct and decode each `llama_batch` within the scope its underlying pointer is actually valid for, instead of across two separate calls (undefined behavior per Swift's pointer-conversion rules, even though it worked in practice) (#27)
- fix(translation): raise HY-MT1.5's generation length cap from 200 to 1024 tokens, so a translation of a long buffered utterance (the early-translate threshold is user-configurable up to 1000 characters) doesn't get cut off mid-sentence (#27)
- fix(translation): don't insert a space before a translation fragment that starts with punctuation, so joined fragments read "Hello, world." not "Hello , world." (#27)
- fix(translation): trim trailing newlines (not just spaces) before checking whether an ASR delta ends a sentence, so a trailing newline no longer silently defeats the early-translate soft-break check (#27)
- fix(inference): use the Swift string's own UTF-8 byte count instead of `strlen` on the converted C string when tokenizing, so an input containing an embedded null byte can't be silently undercounted (#27)

### Dependencies

- deps(audio.cpp): bump pinned `third_party/audio.cpp` checkout to `77491a33` — carries the upstream fix for the R2T2 streaming final-flush null-deref crash ([0xShug0/audio.cpp#712](https://github.com/0xShug0/audio.cpp/pull/712), merged 2026-09-27); drops the local `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch` and its `git apply` step from `Docs/MODEL_ENGINE_SETUP.md`

### Documentation

- docs(repo): remove `CLAUDE.md` symlink to `AGENTS.md`

### Tests

## [0.1.1] - 2026-09-28

### Fixed

- fix(packaging): embed `libaudiocpp`/`libllama`/`libggml-*` dylibs into `OmniVoice.app/Contents/Frameworks` and rewrite their rpaths to `@executable_path`/`@loader_path` in `Scripts/build_app.sh` — the app previously linked those dylibs via absolute `-rpath` entries pointing at the build machine's `third_party/{audio.cpp,llama.cpp}` checkout, so any packaged build crashed on launch elsewhere with `dyld: Library not loaded: @rpath/libaudiocpp.0.dylib` (#18)
- fix(packaging): harden `Scripts/build_app.sh`'s rpath rewrite against a build path containing a space (previously word-split by `for rp in $(...)`, silently truncating `install_name_tool -delete_rpath`'s argument) and make `-add_rpath` on the main executable idempotent (it errors with "would duplicate path" on a second call) (#20)

### Documentation

- docs(repo): note Homebrew 7+'s untrusted-tap prompt (`brew trust hdcola/tap`) needed before `brew install --cask omnivoice` (#15)
- docs(repo): make `brew trust hdcola/tap` a proactive install step in `README.md`'s Homebrew snippet, instead of an "if you hit this error" footnote (#16)

## [0.1.0] - 2026-09-28

### Added

- feat(settings): add a "悬浮窗" section to Settings with two independent sliders — "背景透明度" (`RecordingSession.panelBackgroundOpacity`, `0.1...1.0`) and "内容透明度" (`panelContentOpacity`, `0.4...1.0`), both persisted, both editable at any time including mid-recording. Applied purely in SwiftUI (`FloatingTranscriptView`'s background material vs. its whole content stack), not `NSWindow.alphaValue` — an earlier version of this used one shared window-level opacity, which faded the transcript text right along with the background, making a panel transparent enough to not block the view behind it also make the text hard to read. Named "内容" ("content"), not "文字" ("text"), since it fades every control in the panel (buttons/pickers/dividers/status bar), not just the transcript text. Defaults to `0.5`/`1.0` respectively — a noticeably-more-see-through background out of the box, while the content stays at full opacity by default (#13)
- feat(panel): open a brand-new floating panel at the screen's bottom-center instead of dead center — where live captions/subtitles conventionally sit (meeting apps, system dictation, ...) and out of the way of whatever's in the middle of the screen (`FloatingTranscriptPanel.positionAtBottomCenterOfScreen()`). Only applies the first time (or after a saved frame no longer fits any connected screen) — see the frame-persistence entry below (#13)
- feat(panel): remember the floating transcript panel's position/size across quit/relaunch (`FloatingTranscriptPanel`'s `setFrameAutosaveName`, which both restores a previously-saved frame and arranges future saves in one call) — previously every launch recentered it at a fixed 420×280, discarding wherever the user had dragged/resized it last. `AppDelegate` only calls `positionAtBottomCenterOfScreen()` when nothing was restored (`didRestoreFrame == false` — a fresh install, or a saved frame that no longer fits any connected screen) (#13)
- feat(app): show live model-download progress outside the "模型管理" window — the menu bar's own icon swaps to a percentage readout (`MenuBarLabel`) while any model is downloading, and the menu's "模型管理…" row grows its own "（下载中 NN%）"/"（准备下载…）" suffix, so closing that window (or never opening it) no longer leaves a multi-GB download with no visible progress anywhere in the app (`ModelDownloadManager.hasActiveDownloads`) (#13)
- feat(settings): add a hint under each engine picker ("还没有可用的本地模型，点击上方「模型管理…」下载后即可选用") when a category has no downloaded `.model`-kind engine to offer — previously a `.model` engine simply not appearing in the list (nothing downloaded for it yet) gave no indication of why or where to go fix that (#13)
- feat(app): add a dedicated "模型管理" (Model Management) window (`ModelManagementView`, opened from the menu bar next to "历史记录…"/"设置…", and from a "模型管理…" button beside each engine `Picker` in `SettingsView`) listing every `ProviderCatalog.modelVariants` entry with an explicit 下载/取消/删除 action per row, driven directly by `ModelDownloadManager`. `SettingsView`'s engine `Picker` now only lists a `.model`-kind engine once at least one of its variants is downloaded (bootstrapping a brand-new engine always goes through this new window); its variant picker only lists downloaded variants — a not-yet-downloaded one isn't shown at all, since downloading only ever happens from "模型管理" now
- feat(providers): add `ModelDownloadManager` — downloads and caches a `.model`-kind engine's (R2T2/T3PO) weights on first use instead of requiring the dev-only `R2T2_MODEL_PATH`/`R2T2_T3PO_MODEL_PATH` env vars or a repo-relative `models/` directory. Verifies each download's SHA-256 against `ProviderCatalog.ModelVariant.sha256` before it's considered usable, so a partial/corrupted transfer never reaches `InProcessTranscriber`/`InProcessTranslator.loadModel(modelPath:)`. A whole download (network transfer + verify + move) is tracked as one task per variant, so a second `ensureDownloaded(_:)` call for the same variant joins the one already running instead of starting a redundant transfer, and cancellation reaches the verify/move phase too, not just the network one; the move into the cache is atomic (`FileManager.replaceItemAt`) regardless of a stale file already at the destination. The temp file for an in-progress download now lives inside the cache directory itself (not the system temp directory), avoiding a cross-volume move failure if the cache is pointed at a different disk; cancellation now surfaces uniformly as `CancellationError`; multiple concurrent callers' `progress` closures are all honored, not just the initiating one; and the `URLSession`/delegate no longer retains the manager for its process lifetime the moment a download starts. Progress reporting is throttled (at most ~10/sec) to avoid flooding `@Published downloadProgress` on a fast connection; a disk-space preflight check (with a 512 MB safety margin) fails fast instead of hitting `ENOSPC` partway through a multi-GB transfer; orphaned temp files from a crash/force-quit mid-download are cleaned up on init; the cache directory is excluded from Time Machine/iCloud backup; `deleteCachedModel(for:)` also cancels an in-flight download for that variant; and the network phase (success, checksum verification, HTTP errors) is now covered by tests against a mocked `URLProtocol`, not just manually against a real download. Not yet wired into `RecordingSession`/`SettingsView` — see `Docs/PROGRESS.md` (8d2f8d5, 19c39d8, 4a2881b, a1e772b, 790270a, 9fd37bb)
- feat(session): wire `ModelDownloadManager` into `RecordingSession`/`SettingsView` — added persisted `transcriptionModelVariantID`/`translationModelVariantID` selections (self-healed against `ProviderCatalog.modelVariants(forEngineID:)` on an engine switch, mirroring `transcriptionEngineID`'s own pattern) and `currentTranscriptionModelVariant`/`currentTranslationModelVariant` computed properties, resolved to an already-downloaded variant's local path by `resolveModelPath` before constructing `ModelTranscriptionProvider`/`ModelTranslationProvider` (see the dedicated Model Management window below for how a variant actually gets downloaded) (#12)
- feat(providers): fill in real Hugging Face `downloadURL`/`sha256` for the `r2t2-q8_0`/`t3po-q5_k_m` catalog entries (sha256 cross-checked against HF's LFS blob metadata), and correct `approximateSizeMB` — the previous placeholders (1500/1100 MB) were off by roughly an order of magnitude for T3PO (actual: ~2.4GB / ~9.8GB) (8d2f8d5)
- feat(panel): add a model-status control to the floating panel's status bar (bottom-right corner) — a "预加载模型" button (with a loading spinner) so a `.model`-kind (R2T2/T3PO) engine's weight load can happen before the user asks to record instead of during the first "开始", turning into a "模型已就绪" indicator plus a "释放模型" button once loaded, for reclaiming that memory/VRAM on a memory-constrained machine without waiting for an engine switch or app quit — `RecordingSession.preloadModel()`/`unloadModels()`/`isModelLoaded`. (Placement went through two earlier iterations: first as a button next to start/stop in the top control bar, then a "释放模型" *context menu* on a status label — settled on a plain always-visible button in the corner as more discoverable than either, and to keep it out of the way of the controls used on every recording) (#10)
- feat(panel): show a live mic-level indicator on the floating panel's status bar while recording, driven by the existing `RecordingSession.inputLevel` meter — previously nothing on the panel distinguished "recording with a working mic" from "recording but the selected input is silent/muted" (#10)
- feat(panel): auto-scroll the transcript to the latest line as new content arrives, but stop the moment the user scrolls up to read earlier lines — a "最新内容" button then appears to jump back to the bottom and resume auto-scroll. Previously new lines silently pushed the transcript further down with no way to keep reading older text without it fighting you (#10)
- feat(providers): wire up the R2T2 (ASR) and T3PO (translation) in-process model engines via `audio.cpp`/`llama.cpp`'s C ABIs, ported from `mac-poc-hybrid`'s validated `InProcessTranscriber`/`InProcessTranslator` — `ModelTranscriptionProvider`/`ModelTranslationProvider` are no longer placeholders. See `Docs/MODEL_ENGINE_SETUP.md` for the required local `third_party`/`models` setup. T3PO translation is verified working end-to-end; R2T2 transcription additionally needs the `Patches/audio.cpp/` patch applied to the `third_party` checkout — see Fixed below and `Docs/PROGRESS.md`.

### Changed

- refactor(session): `.model`-kind engine selections now self-heal back to their `.system` counterpart the moment nothing is downloaded for them (`RecordingSession.fallBackToSystemEngineIfModelUnavailable()`) — called on launch (a fresh install, or a variant deleted since the last run), right after a delete in `ModelManagementView`, and defensively at the top of `preloadModel()`/`start()`. Previously the selection itself could keep pointing at an undownloaded model indefinitely, so the first "开始转录"/"预加载模型" after deleting (or never downloading) a model always failed with a "尚未下载" `statusMessage` instead of just quietly using the system engine (#13)
- refactor(app): `isEngineAvailable(_:)` in `SettingsView` now takes the relevant selection's engine ID explicitly (`currentID:`) rather than checking both `transcriptionEngineID`/`translationEngineID` from inside a single shared helper — the two selections are otherwise unrelated, so that was cross-selection coupling with no real effect (engine IDs never collide across the two dimensions) rather than a deliberate design choice
- refactor(app): give the Model Management `Window` `.windowResizability(.contentSize)` — without it, the window's default frame was larger than `ModelManagementView`'s own content, leaving draggable empty space instead of staying sized to exactly what it shows
- refactor(app): the "准备下载…" (no-progress-yet) state in Model Management now uses `.progressViewStyle(.linear)` instead of the default circular spinner, so it visually continues into the determinate linear bar the same row switches to once real progress arrives, instead of a jarring shape change
- refactor(menu): drop the duplicate `statusMessage` line, and the separate screen-recording permission hint, from the menu-bar dropdown — both already show live on the floating panel's own status bar (`session.statusMessage` embeds the permission hint text on that failure), so the menu now only ever repeats an actionable item, never a status line (#10)
- refactor(panel): pull the transcript list out into its own `TranscriptListView`, taking `lines`/`isRunning` as plain values (and `.equatable()` at the call site) instead of observing `RecordingSession` directly — without this, the high-frequency `inputLevel` meter update (~10-15×/sec while recording, unrelated to the transcript itself) forced a full re-diff of the whole transcript (potentially hundreds of rows) every tick (#10)

### Fixed

- fix(session): `panelBackgroundOpacity`/`panelContentOpacity`'s `didSet` no longer skips persisting a clamped out-of-range assignment — reassigning `self` from inside its own `didSet` does *not* re-trigger `didSet` (verified empirically), so an earlier version's `return` right after that reassignment silently skipped the `Self.defaults.set(...)` call below it for every out-of-range value ever assigned; now reads the local `clamped` value and always persists it (#13)
- fix(app): fix `Int(fraction * 100)` percentage-jitter in `ModelManagementView`'s "下载中… NN%" row — a second review pass caught this instance after the same fix already landed in `SettingsView`/`MenuBarContentView`; same binary-floating-point-rounding cause (`.rounded()` now, everywhere a download/opacity fraction is rendered as a percentage) (#13)
- fix(panel): `FloatingTranscriptPanel.positionAtBottomCenterOfScreen()` now falls back to `NSScreen.screens.first` before `center()` — `NSScreen.main` (the screen holding the key window) can read `nil` in the brief window right at launch, before this never-key/never-main accessory app (`canBecomeKey`/`canBecomeMain` are both `false`) has any window the system considers key/main yet, which would otherwise silently skip bottom-center placement for a fresh install (#13)
- fix(providers): `ModelDownloadManager`'s job-cleanup `defer` now calls `objectWillChange.send()` explicitly, matching the explicit call already made at job start — previously it relied on `downloadProgress[variant.id] = nil` (a `@Published` mutation) to imply the notification, which does still fire even for a key that was never populated, but `jobs`/`hasActiveDownloads` need their own regardless, since neither is itself `@Published` (#13)
- fix(session): compare model-variant selection, not just engine ID, in `loadedEngineIDs`/`reusingLoaded` — switching a `.model` engine's selected variant while the *previous* variant's weights were already loaded previously left `isModelLoaded` reading "still matches" (engine ID alone hadn't changed), so `start()`/`preloadModel()` silently kept running the stale variant forever instead of downloading/loading the newly-selected one; `transcriptionModelVariantID`/`translationModelVariantID`'s `didSet` now also calls `discardLoadedModelsIfStale()` (#12)
- fix(providers): declare `ModelDownloadManager.ensureDownloaded(_:progress:)`'s `progress` parameter `@MainActor @Sendable` instead of plain `@Sendable` — every actual call already lands on the main actor, so callers previously had to add their own per-callback `Task { @MainActor in ... }` hop (RecordingSession's live download-progress `statusMessage` updates included) just to satisfy the type checker, for what can be several thousand callbacks on a fast connection (#12)
- fix(settings): a `.disabled(false)` on `SettingsView`'s "模型管理…" button never actually overrode the form's `.disabled(isBusy)` — SwiftUI's `isEnabled` environment value only ever goes *more* disabled going down the view tree, so a descendant can't re-enable itself once an ancestor already disabled it. `.disabled(isBusy)` now applies to each engine `Picker`/variant `Picker`/language `Section` individually, leaving the two "模型管理…" buttons (which don't touch engine/model selection, so have no race to guard against) genuinely enabled during an active recording/preload
- fix(providers): `ModelDownloadManager.deleteCachedModel(for:)`/`ensureDownloaded(_:progress:)` now call `objectWillChange.send()` explicitly — neither `jobs` nor `isDownloaded(_:)`'s underlying file-existence check is `@Published`, so a SwiftUI observer had nothing telling it to re-render the instant a delete completed or a download's job actually started (well before the first `downloadProgress` tick), leaving a stale "已下载" row after a delete or the "下载" button showing during Model Management's "准备下载…" gap instead of reflecting it
- fix(app): deleting a variant in Model Management now also unloads it from `RecordingSession` if it's the one currently resident in memory (`isModelLoaded` + matching `currentTranscriptionModelVariant`/`currentTranslationModelVariant`) — otherwise the file was gone from disk while a preloaded/left-resident instance (`stop()` deliberately doesn't unload) kept running, with `start()`'s `reusingLoaded` happily reusing it while Settings/Model Management both showed "未下载"
- fix(app): open the Model Management window as a `Window` scene, not `WindowGroup` — a `WindowGroup` opens a brand new window instance on every `openWindow(id:)` call (it's designed for multi-document windows), so repeated clicks on "模型管理…" were stacking up duplicate windows instead of refocusing the one already open. Also added a "模型管理…" button to `SettingsView` itself — it had no way to reach the new window otherwise
- fix(session): `resolveModelPath` fails fast with a friendly "「...」尚未下载，请先在「模型管理」中下载" `statusMessage` if a `.model`-kind engine's selected variant isn't downloaded yet, rather than downloading it — the new Model Management window is the only place `ModelDownloadManager.ensureDownloaded(_:progress:)` is ever called now. Typed as `throws(ModelNotDownloadedError)`, not plain `throws`, since it can genuinely never throw anything else, so its 4 call sites (`preloadModel()`/`start()`, ×2 each) need no generic fallback `catch`
- fix(app): don't surface a "下载失败" alert when the user taps "取消" mid-download in Model Management — `cancelDownload(for:)` makes the job throw `CancellationError`, which `download(_:)`'s `catch` previously treated like any other failure; it's now ignored. The alert's title also now reflects which operation actually failed ("下载失败"/"删除失败"), instead of always reading "下载失败" even for a failed deletion
- fix(app): show "准备下载…" the instant "下载" is tapped in Model Management, using `ModelDownloadManager.isDownloading(_:)` rather than waiting for `downloadProgress` to report its first value — that gap (DNS/TLS/redirect before the first network chunk) previously left the button still reading "下载", inviting a second tap. Also drop the redundant `· quantization` suffix from each row's label — `ModelVariant.displayName` already includes it (e.g. "R2T2 (Q8_0)"), so it was rendering as "R2T2 (Q8_0) · Q8_0"
- fix(app): disable Model Management's "删除" button while a recording/preload is active — deleting a `.model`-kind engine's cached weights out from under it left the next preload/start attempt failing confusingly instead of with the same clear "尚未下载" message a deliberate re-download produces
- fix(settings): keep the currently-selected engine/variant visible in `SettingsView`'s pickers (marked "（未下载）") even once nothing is downloaded for it — e.g. its variant was deleted via Model Management, or a synced `UserDefaults` value names an engine this machine hasn't downloaded yet. Filtering it out of the `Picker`'s options entirely left the binding pointing at a tag no longer present, which SwiftUI renders as a blank/no-selection control instead of showing what's actually selected
- fix(session): finalize an in-progress recording's persisted history record before the app quits — `applicationWillTerminate` now calls the new `RecordingSession.finalizeActiveSessionBeforeQuit()` alongside `unloadModelsBeforeQuit()`; previously quitting mid-recording (Cmd+Q, system shutdown, ...) left that session's record with no `endedAt`, showing up in history as one that never properly ended (#10)
- fix(session): call `transcription.unload()` too (not just `translation.unload()`) in `preloadModel()`'s and `start()`'s translation-failure catch blocks, for symmetry with the transcription-failure catch just below them — currently a no-op either way (that provider's own `loadModel()` was never reached), but keeps `unload()` calls paired to whatever got instantiated regardless of future engine implementations allocating anything eagerly at construction (#10)
- fix(providers): pair every `InProcessTranslator` `llama_backend_init()` with a matching `llama_backend_free()` on that same load attempt's failure paths (previously missing — a failed `llama_model_load_from_file`/`llama_init_from_model` left backend state initialized with no `model`/`ctx` to ever pair it with a later free), and guard `unload()` itself against calling `llama_backend_free()` when `model`/`ctx` are both still `nil` — every caller already calls `unload()` unconditionally on any `loadModel()` failure, including one (`TranslatorError.modelMissing`) that throws *before* `llama_backend_init()` is ever reached, which previously freed global backend state that was never initialized (#10)
- fix(session): guard `unloadModels()` against racing `preloadModel()`'s in-flight `loadModel()` calls too, not just `isSessionActive` — without also checking `isPreloadingModel`, calling it mid-preload nil'd the provider ivars right before `preloadModel()` resumed and unconditionally set `isModelLoaded = true`, leaving `isModelLoaded == true` (and the panel reading "模型已就绪") with both providers actually `nil` (#10)
- fix(session): reset `isModelLoaded`/`loadedEngineIDs` (not just the provider ivars) on a genuine `start()` load/start failure — previously only the ivars were nil'd, so `isModelLoaded` could stay `true` with nothing actually loaded if it had been `true` going in (#10)
- fix(panel): give `jumpToLatestButton`'s `isProgrammaticScrollInFlight` guard a ~350ms timeout fallback — if its scroll animation is interrupted (a hard scroll-wheel swipe mid-flight) or never quite lands within the bottom tolerance, `isAtBottom` never fires and the flag could otherwise get stuck `true` forever, permanently disabling real "user scrolled away" detection (#10)
- fix(panel): give `modelStatusControl` `.layoutPriority(1)` in the status bar — a long `statusMessage` could otherwise compress it down to nothing at a narrow panel width instead of truncating further itself (#10)
- fix(providers): fix `InProcessTranscriber`/`InProcessTranslator.loadModelLocked` assigning `registry`/`model` (transcriber) or `model` (translator) to the stored property *before* the remaining load steps had actually succeeded — a later step failing left that property non-`nil` while the load as a whole hadn't completed: for the transcriber, past the `guard model == nil` retry check, orphaning the registry on a retry; for the translator, wedging every future `feed`/`flush` call (which require `ctx != nil`) silently, with no error and no recovery short of `unload()`. Both now only commit to the stored properties once every step has succeeded, freeing the intermediate handle otherwise (#10)
- fix(providers): apply a mid-recording target-language change to `.model`-kind translation (T3PO) — `TargetLanguagePicker` is deliberately left editable while running (unlike source language), which already worked for `SystemTranslationProvider` via its `.translationTask` rebuild, but `ModelTranslationProvider` only ever read the target language once, at `start(config:)`, and silently kept translating into the old language for the rest of the recording. Added `TranslationProvider.updateTargetLanguage(_:)` (default no-op; `ModelTranslationProvider` overrides it to call through to `InProcessTranslator.setTargetLanguage`), called from `RecordingSession.targetLanguageCode`'s `didSet` (#10)
- fix(providers): guard `InProcessTranscriber`/`InProcessTranslator.loadModelLocked` against an unexpected duplicate `loadModel()` call (without an intervening `unload()`) overwriting `registry`/`model`/`ctx` with fresh handles while leaking the old ones — every current caller already pairs the two correctly, so this is a defensive guard, not a fix for an observed leak (#10)
- fix(session): fold `transcriptionProvider`/`translationProvider` non-nil checks directly into `start()`'s `reusingLoaded` computation — previously an edge case where `isModelLoaded` was true but a provider ivar was `nil` fell into the "create fresh" branch while `reusingLoaded` itself stayed `true`, skipping `loadModel()` for a provider that was never actually loaded and failing at `startStream()` with `TranscriberError.notLoaded` (#10)
- fix(session): reset `statusMessage` back to "未启动" in `discardLoadedModelsIfStale()` when it's still showing "模型已预加载" — switching engines right after a successful preload previously left the panel's status bar reporting a model as loaded that had just been unloaded (#10)
- fix(menu): show "预加载中…" on the menu-bar dropdown's start/stop button while `isPreloadingModel`, not just a grayed-out "开始转录" — with the floating panel hidden, a disabled button with no label change gave no indication of *why* it wasn't responding (#10)
- fix(panel): stop a `jumpToLatestButton` tap's own 0.2s scroll animation from getting undone mid-flight — `.onScrollGeometryChange` saw several intermediate frames where the offset had moved but not yet reached the bottom tolerance, indistinguishable by that check alone from a genuine user drag away, and flipped `isPinnedToBottom` back to `false` before the animation landed (#10)
- fix(providers): add a defensive `deinit` to `InProcessTranscriber`/`InProcessTranslator` that releases the underlying C handles if some future caller ever drops an instance without going through the explicit `unload()` every current caller already uses — guards against silently leaking (or, for the Metal-backed resources, crashing ggml's exit-time assert on) a never-unloaded instance (#10)
- fix(session): stop unconditionally discarding an already-loaded model on a same-value engine-ID re-assignment — `discardLoadedModelsIfStale()` fired on every `didSet`, including one that re-set the *same* id a Picker already had selected, and unloaded a perfectly good, still-matching load (#10)
- fix(session): wire `preloadModel()`'s providers into `transcriptionProvider`/`translationProvider` before either `loadModel()` call resolves, not after both succeed — quitting mid-preload previously left those ivars `nil` the whole time, so `unloadModelsBeforeQuit()` had nothing to reach and skipped cleanup entirely, risking the exact ggml Metal exit-time assert it exists to prevent (#10)
- fix(menu): disable the menu-bar dropdown's start/stop button while `isPreloadingModel` too, matching the floating panel's own button — `start()` itself already no-ops during a preload, but the menu-bar button didn't reflect that, so clicking it felt like nothing happened (#10)
- fix(panel): fix the transcript auto-scroll never actually auto-scrolling — `.onScrollGeometryChange` computed "at the bottom" purely from the live `contentOffset`/`contentSize`, but new content growing `contentSize` *before* the offset catches up already reads as "not at the bottom", so the very first append after a pinned state permanently unpinned it with no user scroll involved. Now compares old vs. new geometry and only unpins when the offset actually moved away from the bottom while content size stayed put — a size-driven "not at bottom" reading no longer counts as the user scrolling away (#10)
- fix(providers): stop freezing the whole app UI while R2T2/T3PO's weights load — `InProcessTranscriber`/`InProcessTranslator.loadModel(modelPath:)` ran their (multi-second) load synchronously via `queue.sync`, and since every caller is `@MainActor`-isolated (`ModelTranscriptionProvider`/`ModelTranslationProvider`), that blocked the whole main actor — the window looked hung, not just busy, and no loading spinner could animate through it. Both now dispatch the load onto their serial queue asynchronously instead, keeping the main actor free; the floating panel's "预加载模型"/"开始" buttons now show a spinner (`ProgressView`) for the whole load, which actually animates since the UI thread stays responsive (#10)
- fix(providers): stop unloading R2T2/T3PO's weights on every "停止" — `ModelTranscriptionProvider`/`ModelTranslationProvider.stop()` used to call `unload()` unconditionally, so every recording silently reloaded the model from scratch (a multi-second stall) even without the preload button, and the "预加载模型" button always reappeared after a stop. `stop()` now only ends the recording's stream/session (`InProcessTranscriber.finishStream()`, a new `InProcessTranslator.resetSession()`); `RecordingSession` owns the model's loaded lifetime independently of any one recording (`isModelLoaded` survives `stop()`), unloading only on an engine switch or app quit (`applicationWillTerminate` now actually calls `unloadModelsBeforeQuit()`, fulfilling a long-standing TODO) (#10)
- fix(providers): fix the R2T2 crash on stop / VAD pause — a null-pointer dereference in `audio.cpp`'s own `R2T2ASRSession::build_stream_prefix(final_flush=true)`, which builds a one-element vector from an empty token list whenever the session's decoded text is empty at finish time. Ships as `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch`, now a required step in `Docs/MODEL_ENGINE_SETUP.md`; reproduced deterministically from the C API (silence only, no mic) and verified against the patched dylib. Submitted upstream as [audio.cpp#712](https://github.com/0xShug0/audio.cpp/pull/712).

### Documentation

- docs(repo): add Homebrew install instructions to `README.md` (`brew tap hdcola/tap && brew install --cask omnivoice`)
- docs(repo): record DMG packaging + Homebrew distribution as done, and update the release-pipeline open item to reflect remaining notarization work in `Docs/PROGRESS.md`
- docs(repo): add `Docs/MODEL_ENGINE_SETUP.md` (clone/build/weights recipe for the R2T2/T3PO model engines) and update `README.md`/`Docs/PROGRESS.md` to reflect the model providers landing
- docs(repo): document a known R2T2 crash bug (SIGSEGV inside `audio.cpp`'s `R2T2ASRSession::finalize()` after a longer buffered utterance) in `README.md`/`Docs/PROGRESS.md` — confirmed reproducible in the unmodified upstream `mac-poc-hybrid` reference too, not a regression from this port; no mitigation found at the C API level
- docs(repo): replace that writeup with the root cause and the fix across `README.md`/`Docs/PROGRESS.md`/`Docs/MODEL_ENGINE_SETUP.md`, and add `Patches/audio.cpp/README.md` describing how patches against the pinned `audio.cpp` checkout are carried and when to drop them

### Tests

- test(session): cover `panelBackgroundOpacity`/`panelContentOpacity`'s defaults, `UserDefaults` restore, and clamp-on-assignment behavior (including that the clamped value itself gets persisted, not just held in memory); cover `translationEngineID`'s undownloaded-model fallback (transcription-side already had it, both at restore time and inside `preloadModel()`); add `ModelDownloadManager.hasActiveDownloads` coverage (false with nothing in flight, true for the duration of a mocked in-flight download, false again once it finishes) — none of this had coverage yet despite the rest of this area's consistently thorough suite (#13)
- test(session): cover the new `transcriptionModelVariantID`/`translationModelVariantID` persistence, its default-to-first-catalog-variant fallback, its self-heal on an engine switch, and the `loadedEngineIDs` variant-comparison fix (a variant switch now discards a model loaded under a different variant, but not a reassignment to the same resolved one) (#12)
- test(providers): add `ModelLanguageMappingTests` covering the BCP-47 → R2T2/T3PO language mapping helpers
- test(session): cover `preloadModel()`'s state machine (including its no-op-once-loaded guard) and its discard-on-engine-switch guard, plus the new `usesOnDeviceModelEngine` flag (#10)
- test(session): cover `TranscriptLine`'s new `Equatable` conformance (#10)
- test(session): cover that a same-value engine-ID re-assignment keeps a loaded model, and that switching engines resets the stale "模型已预加载" `statusMessage` (#10)
- test(session): cover `unloadModels()` releasing a preloaded model, and its no-op guards while a recording is active or a preload is in flight (#10)
- test(session): cover `finalizeActiveSessionBeforeQuit()`'s no-op guard with no active session (#10)
- test(providers): cover `ModelTranslationProvider.updateTargetLanguage(_:)` not requiring a loaded model — the actual retargeting-takes-effect path needs T3PO's real (gitignored) weights, not committed here (#10)

## [0.0.1] - 2026-09-27

Internal test build — ad-hoc signed, not notarized (see `Docs/RELEASE_TESTING.md`
for how testers install and run it).

### Added

- feat(scaffold): initial project skeleton — `TranscriptionProvider`/`TranslationProvider` protocols, ported audio capture/mixing pipeline, SwiftData-backed session history with Markdown export, and a menu-bar app shell with a floating live-transcript panel (ee5f43d)
- feat(app): move the most-frequently-adjusted controls onto the floating panel and menu bar, out of the Settings window — the panel now shows from launch and hosts a start/stop button plus source/target language pickers (target stays editable mid-recording, source doesn't — see its doc comment for why), and the menu bar gained a microphone picker and a "包含系统声音" toggle (#3)
- feat(app): custom themed close button on the floating panel (semi-transparent circular ✕, brightens on hover), replacing the native traffic light — matches the panel's borderless/titlebar-hidden look (#3)
- feat(session): persist engine choice, language pair, mic device, and system-audio inclusion across quits/relaunches (and system restarts) via `UserDefaults` — previously every one of these silently reset to hardcoded defaults on every launch (#3)
- feat(app): Settings' language section uses the same `SourceLanguagePicker`/`TargetLanguagePicker` the floating panel does — the two can't offer different language sets by construction (#3)
- build(release): `Scripts/build_dmg.sh` — wraps `Scripts/build_app.sh`'s output into an installable `.dmg` (app + `/Applications` symlink), for handing testers a single downloadable file instead of a bare `.app`

### Changed

### Fixed

- fix(translation): correct a race where a translation row was persisted/aligned before its translation actually committed (b0e603f)
- fix(app): construct `RecordingSession`/the floating panel at app launch instead of on first menu-open, so a future non-menu entry point can't silently skip that setup (ece1ea4)
- fix(audio): synchronize `SystemTranscriptionProvider`'s audio-path state between the background audio queue and the main actor (408b082)
- fix(app): show the floating transcript panel automatically when a recording starts — previously it was only shown/hidden by a manual menu toggle, so starting a recording gave no visible feedback at all (#3)
- fix(app): make the floating transcript panel draggable again — `NSHostingView` swallows `mouseDown` for its own SwiftUI gesture recognition, so `isMovableByWindowBackground` never actually fired; fall back to `performDrag(with:)` on any unhandled background click (#3)
- fix(app): fix the menu's "显示/隐藏悬浮窗" toggle silently doing nothing — it reached `AppDelegate` via `NSApp.delegate as? AppDelegate`, which isn't reliable from a `MenuBarExtra`-only (no primary window) SwiftUI app; inject `AppDelegate` through the SwiftUI environment instead, the same way `RecordingSession` already is (#3)
- fix(app): activate the app (`NSApp.activate(ignoringOtherApps:)`) before opening the history/settings windows — as an accessory app (`LSUIElement`), OmniVoice never becomes frontmost on its own, so those windows were opening behind whichever app already had focus (#3)
- fix(app): restore a menu-bar start/stop button — removing it in favor of the floating panel's own button left no way to start/stop while the panel is hidden (#3)
- fix(session): guard `RecordingSession.start()` against reentrancy — `isRunning` only flips `true` after `start()`'s (possibly slow) async setup finishes, so a fast double-click could pass the existing guard twice and create duplicate providers/capture; added an `isStarting` flag covering that whole window (#3)
- fix(app): shorten the menu bar's "包含系统声音" toggle label — the permission caveat is already covered by the `screenRecordingPermissionNeeded` caption below it (#3)
- fix(session): disable engine/language/mic/system-audio controls for the whole start→stop lifecycle (new `isSessionActive`), not just while `isRunning` — they were still editable during `isStarting`/`isStopping`, racing the in-flight setup or silently not applying to the run in progress (#3)
- fix(app): only offer "自动" (nil source language) in the floating panel's picker while a `.model`-kind ASR engine is selected — the only ASR engine implemented so far (`SystemTranscriptionProvider`) requires a concrete locale and throws `.localeNotSupported` for `nil`; also self-heals `sourceLanguageCode` back to a concrete value if the engine is switched back to `.system` while it's still `nil` (#3)
- fix(app): show a "(自定义)"-suffixed entry in the floating panel's language pickers for a code set via Settings' advanced free-text field but not in `LanguageCatalog.common` — otherwise the picker showed a blank/mismatched selection and picking anything from the list silently discarded the custom value (#3)
- fix(app): make the floating panel's SwiftUI content actually resize with the window — its `.frame` was a fixed 420×280 despite the panel's `.resizable` style mask, leaving blank space when dragged larger; now `minWidth`/`minHeight` with `.infinity` max, plus a matching `NSPanel.minSize` (#3)
- fix(app): filter `ru-RU`/`ar-SA`/`vi-VN`/`th-TH` out of the source-language picker while the `.system` ASR engine is selected — confirmed `TranslationSession` targets, but not supported as a `SpeechTranscriber` source, so picking one there threw at `start()` with 100% certainty; `LanguageOption.supportsSystemASRSource` now drives the filter (still offered as translation targets), and the engine-switch self-heal covers this case too, not just the "自动"/nil one (#3)
- fix(app): re-show the floating panel when a recording starts even if it was previously hidden — removing the old `isRunningCancellable` auto-show subscription (in favor of "always shown from launch") meant starting a recording from the menu bar after manually hiding the panel gave no visual feedback at all (#3)
- fix(session): re-validate the "system engine ⇒ usable source language" invariant once at the end of `restorePersistedSettings()`, not only inside `transcriptionEngineID`'s own `didSet` — restoring `transcriptionEngineID` from `UserDefaults` runs that `didSet` *before* `sourceLanguageCode` is restored, so it could validate against the still-default value and miss an invalid combination that only exists once both are loaded (#3)
- fix(session): validate a persisted `transcriptionEngineID`/`translationEngineID` against `ProviderCatalog` before restoring it — an ID from a build where an engine was since renamed/removed would otherwise silently make `transcriptionEngineKind` return `nil`, breaking every `.system`/`.model` check that depends on it (#3)
- fix(session): stop `refreshDevices()`'s automatic fallback (when the persisted mic isn't currently connected) from overwriting the persisted device preference in `UserDefaults` — previously, opening the menu with a USB mic unplugged (or Bluetooth earbuds not connected) permanently forgot that device as the preference, even after reconnecting it (#3)
- fix(session): delete the orphaned `RecordingSessionRecord` `start()` creates upfront if translation/transcription/mic setup then fails and returns early — previously left a permanent `endedAt`-less, utterance-less row in history, and the *next* successful `start()` would silently orphan it further by overwriting `activeSessionRecord` (#3)
- fix(session): `refreshDevices()` now re-checks the *persisted* device preference (not just whether the current in-memory selection is still valid) — previously, once a disconnected mic's fallback landed on `.systemDefault` (which is always "valid"), reconnecting that mic later could never switch back to it in the running app, since the current-selection check alone never re-triggered (#3)
- fix(session): guard `targetLanguageCode`'s restore against a stray/legacy empty string in `UserDefaults` — unlike `sourceLanguageCode`, `""` was never a meaningful sentinel for `targetLanguageCode`, so restoring it verbatim left `targetLanguageCode == ""`, which `TranslationSession` can't resolve (#3)
- fix(app): reset `lines` back to empty when `start()` fails partway through — `lines` is seeded with one placeholder row before translation/transcription/mic setup can fail, so a failed start (or a stop before anyone said anything) left the panel's transcript area looking blank with no "等待开始…" placeholder and no other indication anything was wrong (#3)
- fix(app): show `RecordingSession.statusMessage` on the floating panel itself (new status bar under the transcript) — previously it only ever appeared in the menu bar dropdown, so a failed `start()` gave no visible feedback on the panel at all (#3)
- fix(app): enlarge the floating panel's close button hit target (24×24 with `contentShape`, up from an 18×18 visual-only frame) and add `.accessibilityLabel("隐藏悬浮窗")` — it's the panel's only close affordance (no titlebar), so a target as small as the visible circle was easy to miss and land on the draggable background instead (#3)
- fix(session): `refreshDevices()` no longer reconciles `selectedDeviceID` while `isSessionActive` — a running recording's `MicrophoneCapture` is already bound to whatever device `start()` handed it and can't hot-swap mid-recording, so switching `selectedDeviceID` out from under it (e.g. because the preferred mic got reconnected) only desynced the UI from what was actually being captured; the device list itself still refreshes (#3)
- fix(session): trim whitespace before checking `sourceLanguageCode`/`targetLanguageCode` restore values for emptiness — a whitespace-only persisted string (e.g. `"   "`) passed the existing `.isEmpty` check and would have restored verbatim (#3)
- fix(app): add `.help(session.statusMessage)` to the floating panel's status bar — a longer message (a localized error appended to a permission hint, say) gets cut off by the bar's `.lineLimit(1)` at the panel's default width, and the tooltip keeps the full text reachable without needing to widen the panel (#3)

### Dependencies

### Documentation

- docs(repo): add `Docs/PROGRESS.md` tracking product/architecture decisions and open items
- docs(repo): add `Docs/RELEASE_TESTING.md` for internal testers (install/permissions/scope/bug-report checklist), and rewrite `README.md` to describe 0.0.1's actual feature scope instead of the one-line placeholder it had (#4)

### Tests

- test(scaffold): unit tests for `SentenceBoundary` and `ProviderCatalog` (ee5f43d)
- test(session): `RecordingSessionSettingsTests` covering `RecordingSession`'s settings self-heal contracts — unrecognized persisted engine IDs falling back to the catalog default, the system-engine/source-language invariant re-validating after a full settings restore (not just on a live engine switch), `includeSystemAudio`/`targetLanguageCode` persistence (including the empty- and whitespace-only-string guards), a disconnected mic's fallback not clobbering the persisted device preference, `refreshDevices()` leaving `selectedDeviceID` alone while a recording is active, and `isSessionActive` reflecting `isRunning`/`isStarting`/`isStopping` (#3)
