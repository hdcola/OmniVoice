# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added

- feat(scaffold): initial project skeleton — `TranscriptionProvider`/`TranslationProvider` protocols, ported audio capture/mixing pipeline, SwiftData-backed session history with Markdown export, and a menu-bar app shell with a floating live-transcript panel (ee5f43d)

### Changed

### Fixed

- fix(translation): correct a race where a translation row was persisted/aligned before its translation actually committed (b0e603f)
- fix(app): construct `RecordingSession`/the floating panel at app launch instead of on first menu-open, so a future non-menu entry point can't silently skip that setup (ece1ea4)
- fix(audio): synchronize `SystemTranscriptionProvider`'s audio-path state between the background audio queue and the main actor (408b082)
- fix(app): show the floating transcript panel automatically when a recording starts — previously it was only shown/hidden by a manual menu toggle, so starting a recording gave no visible feedback at all
- fix(app): make the floating transcript panel draggable again — `NSHostingView` swallows `mouseDown` for its own SwiftUI gesture recognition, so `isMovableByWindowBackground` never actually fired; fall back to `performDrag(with:)` on any unhandled background click
- fix(app): fix the menu's "显示/隐藏悬浮窗" toggle silently doing nothing — it reached `AppDelegate` via `NSApp.delegate as? AppDelegate`, which isn't reliable from a `MenuBarExtra`-only (no primary window) SwiftUI app; inject `AppDelegate` through the SwiftUI environment instead, the same way `RecordingSession` already is
- fix(app): activate the app (`NSApp.activate(ignoringOtherApps:)`) before opening the history/settings windows — as an accessory app (`LSUIElement`), OmniVoice never becomes frontmost on its own, so those windows were opening behind whichever app already had focus

### Dependencies

### Documentation

- docs(repo): add `Docs/PROGRESS.md` tracking product/architecture decisions and open items

### Tests

- test(scaffold): unit tests for `SentenceBoundary` and `ProviderCatalog` (ee5f43d)
