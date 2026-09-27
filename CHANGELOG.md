# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added

- feat(scaffold): initial project skeleton — `TranscriptionProvider`/`TranslationProvider` protocols, ported audio capture/mixing pipeline, SwiftData-backed session history with Markdown export, and a menu-bar app shell with a floating live-transcript panel (ee5f43d)
- feat(app): move the most-frequently-adjusted controls onto the floating panel and menu bar, out of the Settings window — the panel now shows from launch and hosts a start/stop button plus source/target language pickers (target stays editable mid-recording, source doesn't — see its doc comment for why), and the menu bar gained a microphone picker and a "包含系统声音" toggle; Settings keeps just engine selection plus an advanced free-text BCP-47 entry for languages outside the new shared `LanguageCatalog`'s quick-pick list
- feat(app): custom themed close button on the floating panel (semi-transparent circular ✕, brightens on hover), replacing the native traffic light — matches the panel's borderless/titlebar-hidden look
- feat(session): persist engine choice, language pair, mic device, and system-audio inclusion across quits/relaunches (and system restarts) via `UserDefaults` — previously every one of these silently reset to hardcoded defaults on every launch

### Changed

### Fixed

- fix(translation): correct a race where a translation row was persisted/aligned before its translation actually committed (b0e603f)
- fix(app): construct `RecordingSession`/the floating panel at app launch instead of on first menu-open, so a future non-menu entry point can't silently skip that setup (ece1ea4)
- fix(audio): synchronize `SystemTranscriptionProvider`'s audio-path state between the background audio queue and the main actor (408b082)
- fix(app): show the floating transcript panel automatically when a recording starts — previously it was only shown/hidden by a manual menu toggle, so starting a recording gave no visible feedback at all
- fix(app): make the floating transcript panel draggable again — `NSHostingView` swallows `mouseDown` for its own SwiftUI gesture recognition, so `isMovableByWindowBackground` never actually fired; fall back to `performDrag(with:)` on any unhandled background click
- fix(app): fix the menu's "显示/隐藏悬浮窗" toggle silently doing nothing — it reached `AppDelegate` via `NSApp.delegate as? AppDelegate`, which isn't reliable from a `MenuBarExtra`-only (no primary window) SwiftUI app; inject `AppDelegate` through the SwiftUI environment instead, the same way `RecordingSession` already is
- fix(app): activate the app (`NSApp.activate(ignoringOtherApps:)`) before opening the history/settings windows — as an accessory app (`LSUIElement`), OmniVoice never becomes frontmost on its own, so those windows were opening behind whichever app already had focus
- fix(app): restore a menu-bar start/stop button (code review on #3) — removing it in favor of the floating panel's own button left no way to start/stop while the panel is hidden
- fix(session): guard `RecordingSession.start()` against reentrancy (code review on #3) — `isRunning` only flips `true` after `start()`'s (possibly slow) async setup finishes, so a fast double-click could pass the existing guard twice and create duplicate providers/capture; added an `isStarting` flag covering that whole window
- fix(app): shorten the menu bar's "包含系统声音" toggle label — the permission caveat is already covered by the `screenRecordingPermissionNeeded` caption below it
- fix(session): disable engine/language/mic/system-audio controls for the whole start→stop lifecycle (new `isSessionActive`), not just while `isRunning` — they were still editable during `isStarting`/`isStopping`, racing the in-flight setup or silently not applying to the run in progress
- fix(app): only offer "自动" (nil source language) in the floating panel's picker while a `.model`-kind ASR engine is selected — the only ASR engine implemented so far (`SystemTranscriptionProvider`) requires a concrete locale and throws `.localeNotSupported` for `nil`; also self-heals `sourceLanguageCode` back to a concrete value if the engine is switched back to `.system` while it's still `nil`
- fix(app): show a "(自定义)"-suffixed entry in the floating panel's language pickers for a code set via Settings' advanced free-text field but not in `LanguageCatalog.common` — otherwise the picker showed a blank/mismatched selection and picking anything from the list silently discarded the custom value
- fix(app): make the floating panel's SwiftUI content actually resize with the window — its `.frame` was a fixed 420×280 despite the panel's `.resizable` style mask, leaving blank space when dragged larger; now `minWidth`/`minHeight` with `.infinity` max, plus a matching `NSPanel.minSize`
- fix(app): filter `ru-RU`/`ar-SA`/`vi-VN`/`th-TH` out of the source-language picker while the `.system` ASR engine is selected — confirmed `TranslationSession` targets, but not supported as a `SpeechTranscriber` source, so picking one there threw at `start()` with 100% certainty; `LanguageOption.supportsSystemASRSource` now drives the filter (still offered as translation targets), and the engine-switch self-heal covers this case too, not just the "自动"/nil one
- fix(app): re-show the floating panel when a recording starts even if it was previously hidden — removing the old `isRunningCancellable` auto-show subscription (in favor of "always shown from launch") meant starting a recording from the menu bar after manually hiding the panel gave no visual feedback at all
- feat(app): Settings' language section now uses the same `SourceLanguagePicker`/`TargetLanguagePicker` the floating panel does, instead of a separate free-text BCP-47 entry — the two could never offer different language sets by construction now

### Dependencies

### Documentation

- docs(repo): add `Docs/PROGRESS.md` tracking product/architecture decisions and open items

### Tests

- test(scaffold): unit tests for `SentenceBoundary` and `ProviderCatalog` (ee5f43d)
