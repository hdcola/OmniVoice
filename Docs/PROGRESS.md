# OmniVoice — Progress & Task Tracker

Living document — update this whenever a decision is made or a milestone
lands, so a new session (human or agent) can pick up context without
re-deriving it from chat history. Keep entries terse; link to code/PRs
instead of re-explaining them.

## What this is

macOS 26+ menu-bar app for real-time speech transcription/translation in
multilingual meetings and lectures — pick a transcription/translation
"provider" (a system framework or an in-process model), record, and browse/
search/export past sessions afterward. A floating semi-transparent panel
shows the live transcript while the user is doing something else (in a
meeting, on a call).

Reference implementation for the engine plumbing: `../mac-poc-hybrid` (a
sibling POC repo, not part of this repo) — see its README for the four
ASR×translation engine combinations it validated. This repo is a from-scratch
product build, not a fork of that POC; code is ported in piece by piece as
each area is tackled.

## Product decisions (locked)

- **Name**: OmniVoice.
- **Distribution**: direct notarized distribution, not the Mac App Store
  (needed to link self-built `audio.cpp`/`llama.cpp` dylibs and use
  ScreenCaptureKit without App Sandbox restrictions).
- **Model weights**: downloaded on first use, not bundled in the app.
- **Menu-bar-only app** (`LSUIElement`) with a floating transcript panel —
  no Dock icon.
- **MVP provider scope**: only local engines — a system framework
  (Speech/Translation) and an in-process model (R2T2/T3PO via audio.cpp/
  llama.cpp's C ABI). Third-party cloud APIs (OpenAI/Azure/Google-style) are
  an explicit non-goal for now; the provider abstraction should not need to
  change shape to add them later.
- **Model catalog**: data-driven (`ProviderCatalog`), not one `enum` case per
  model — this project is non-commercial for now; audio.cpp support for more
  community models gets tested and added to the catalog over time.
- **Persistence**: SwiftData/SQLite, local only.
- **Localization**: architecture should leave room for it (no hardcoded
  strings baked deep into logic), but no actual translation work yet —
  Chinese-only UI strings for now.
- **Deferred to "before commercial use," not before shipping non-commercially**:
  re-checking the R2T2/T3PO model licenses' terms for redistribution.

## Architecture decisions (locked)

See `Sources/OmniVoiceCore/Providers/TranscriptionProvider.swift` and
`TranslationProvider.swift` for the authoritative doc comments — summary:

- **`TranscriptionEvent`** (3 cases: `.appended` / `.revised` /
  `.segmentClosed(finalAppend:)`) normalizes two fundamentally different ASR
  engine shapes (R2T2's append-only streaming deltas vs. `SpeechTranscriber`'s
  full-replace volatile/final results) into one contract, instead of exposing
  two different callback shapes to the orchestrator.
- **`TranslationProvider`** is just `feed(_:)` + `flush()` for *every* engine,
  streaming or one-shot — a one-shot engine (`SystemTranslationProvider`)
  satisfies this by buffering in `feed` and only actually translating inside
  `flush`. Callers never branch on which kind of engine is behind the
  protocol.
- **`RecordingSession`** (`Sources/OmniVoiceCore/Session/RecordingSession.swift`)
  is the *only* place that knows how to turn a `TranscriptionEvent` into
  display text + a translation feed call — this is deliberate, see that
  file's `handle(_:)` method and its doc comment.
- Translation never runs on ASR's tentative/volatile text (`.revised`) — only
  on committed text (`.appended`/`.segmentClosed`). Rationale: translating a
  guess ASR might still rewrite wastes compute and makes the translation
  preview flicker along with ASR's own uncertainty. Trade-off accepted: the
  system-ASR + model-translation combination feels laggier (no live
  translation preview until a whole segment finalizes) than model-ASR +
  model-translation (which does get a live preview, since R2T2's deltas are
  already committed, not tentative).
- **`TranslationSession` can only be created inside a SwiftUI view** (a
  platform constraint) — bridged via `TranslationBridgeRequest` +
  `RecordingSession.translationBridgeStream()`/`resolveTranslationBridgeResult(_:)`,
  drained by `FloatingTranscriptView`'s `.translationTask` (chosen because
  that view is created once at launch and never torn down, so the bridge's
  `AsyncStream` continuation survives across stop/start recording cycles —
  see `SystemTranslationProvider`'s doc for why that continuation can't live
  on the provider itself).
- **Swift 6 strict concurrency is off** (`.swiftLanguageMode(.v5)` on both
  targets, in `Package.swift`) — same reasoning `mac-poc-hybrid` documents:
  AVFoundation/ScreenCaptureKit/Speech/Translation's delegate- and
  closure-based APIs (plus Apple's own `.translationTask` sample pattern)
  aren't annotated for it, and fighting the "sending non-Sendable value"
  checker on code that already has its own manual serial-queue thread-safety
  wasn't worth it for this stage.

## Status

### Done

- [x] Product/architecture discussion — see chat history (not re-summarized
      here beyond the "locked" sections above).
- [x] Repo scaffold on `feature/project-scaffold`:
  - `OmniVoiceCore`: provider protocols + `ProviderCatalog`, audio capture/
    mixing pipeline (ported from `mac-poc-hybrid`), `RecordingSession`
    orchestrator, SwiftData persistence (`RecordingSessionRecord`/
    `UtteranceRecord`) + `SessionStore` + Markdown export.
  - `OmniVoice`: menu-bar app shell, floating transcript panel (`NSPanel`),
    history window (`SwiftData` `@Query`), settings view.
  - `Scripts/build_app.sh` + `Scripts/Info.plist`: dev-only ad-hoc-signed
    `.app` packaging (not a release pipeline — see Open Items).
  - 3 unit tests (`SentenceBoundary`, `ProviderCatalog`).
- [x] Verified: `swift build` (debug + release), `swift test`, packaged
      `.app` launches and quits cleanly with no crash.
- [x] Manual smoke test of the running app (mic-in-hand): start/stop
      recording, floating panel show + drag, panel toggle, history window,
      settings window — full flow confirmed working end to end. Surfaced 4
      real UI bugs, all fixed on `fixbug/show-floating-panel-on-start`
      (PR #2) — see "Smoke test findings (fixed)" below.

### Code review findings (fixed)

A review of the scaffold PR caught three real bugs, all fixed on
`feature/project-scaffold` (see those commits for full reasoning):

- **Translation row misalignment**: `SystemTranslationProvider.flush()` fired
  its completion boundary synchronously, before the (async) translation
  result it was supposed to be gating on ever arrived — every row after the
  first translated one would silently shift by one. Fixed by moving the
  boundary to fire from `receiveResult(_:)` instead.
- **Floating panel/translation bridge wired up by coincidence**: setup lived
  in `MenuBarContentView.onAppear`, which only runs the first time the menu
  opens — harmless only because the menu is currently the sole entry point
  to starting a recording. Fixed by moving ownership of `RecordingSession`/
  the panel into `AppDelegate`, constructed at `applicationDidFinishLaunching`.
- **Unsynchronized audio-path state**: `SystemTranscriptionProvider.push(samples:)`
  runs on a background audio queue but mutated fields `stop()` (main actor)
  also nils out, with no lock between them — a real, silent race that Swift's
  minimal concurrency checking (Swift 5 language mode) didn't catch at
  compile time. Fixed with a private serial queue guarding every field
  `push` touches; `TranscriptionProvider.push(samples:)`/
  `notifyUtteranceBoundary()` are now `nonisolated` in the protocol to
  document that this is the hot audio-path exception to the rest of the
  protocol's `@MainActor` default.

### Smoke test findings (fixed)

Manual smoke test (`fixbug/show-floating-panel-on-start`, PR #2) caught four
real UI bugs, all fixed:

- **Floating panel never showed on "开始转录"**: its visibility was never
  wired to `RecordingSession.isRunning`, only to a manual menu toggle. Fixed
  by subscribing to `session.$isRunning` in `AppDelegate` and ordering the
  panel front as soon as it goes `true` (hiding stays manual, so the
  transcript is still reviewable after stopping).
- **Panel couldn't be dragged**: `NSHostingView` consumes `mouseDown` for its
  own SwiftUI gesture recognition and never lets it bubble to the window, so
  `isMovableByWindowBackground` silently never fired. Fixed with a
  `DraggableHostingView` subclass that falls back to `performDrag(with:)` for
  any `mouseDown` no SwiftUI control handled.
- **"显示/隐藏悬浮窗" menu toggle did nothing**: it reached `AppDelegate` via
  `NSApp.delegate as? AppDelegate`, unreliable from a `MenuBarExtra`-only (no
  primary window) app. Fixed by injecting `AppDelegate` through the SwiftUI
  environment instead, the same way `RecordingSession` already is.
- **History/settings windows opened behind other apps**: as an accessory app
  (`LSUIElement`), OmniVoice never becomes frontmost on its own. Fixed by
  calling `NSApp.activate(ignoringOtherApps: true)` before opening each
  window (and switching the settings menu item from `SettingsLink` to a
  `Button` + `openSettings`, since `SettingsLink` offers no hook to activate
  first).

### Open items / next up

Roughly in the order they'll likely get tackled — not a hard commitment.

1. **Model providers**: port `InProcessTranscriber`/`InProcessTranslator` from
   `mac-poc-hybrid` behind `ModelTranscriptionProvider`/
   `ModelTranslationProvider` — needs adding `CAudioCpp`/`CLlamaCpp` C target
   shims + `third_party/audio.cpp`+`third_party/llama.cpp` linker flags to
   `Package.swift` (see those two provider files' doc comments for the exact
   plan) and a first real download source for `ProviderCatalog`'s model
   variants (`downloadURL`/`sha256` are currently `nil` placeholders).
2. **Settings UI wiring**: model-variant picker is currently `.disabled(true)`
   (`SettingsView.modelVariantPicker`) — enable once #1 lands. Also currently
   no device picker in Settings (`RecordingSession.inputDevices` exists but
   nothing in the UI binds to it yet).
3. **Release pipeline**: Developer ID signing + notarization + stapling
   (current `Scripts/build_app.sh` is ad-hoc-signed, dev-only), plus an
   update mechanism (Sparkle-shaped) and a real weights-hosting location for
   downloaded models.
4. **Privacy copy, crash/error log export, localization scaffolding** — all
   explicitly deferred ("搭架子" / stub first) per the product discussion;
   none of the actual placeholder work has been started yet.
5. **Model license re-check** — before any commercial use, not before this.
6. **Floating panel close button**: the red traffic-light close button is
   still live despite the hidden titlebar — clicking it closes the panel
   outside the toggle's tracked `isVisible` state. Flagged during the smoke
   test, not fixed yet (low priority unless it turns out to bite).

### Known gaps / things to double check when touching nearby code

- `RecordingSession.translationBridgeStream()` assumes the SwiftUI view that
  drains it never remounts independent of the app's lifetime. If
  `FloatingTranscriptView` ever gets recreated (e.g. panel is destroyed and
  rebuilt instead of just hidden), the continuation needs re-wiring — see
  `AppDelegate.attach(session:)`'s "create once" guard, which is what
  currently guarantees this.
- `SessionDetailView`/`SessionListView` search is a naive in-memory
  `localizedCaseInsensitiveContains` scan (`SessionStore.searchSessions`) —
  fine at small history sizes, will need a real index if/when session counts
  get large.
- No handling yet for what happens if `SessionStore.init()` throws (disk
  full, schema mismatch after a future migration) beyond "history window has
  no data" — `RecordingSession` itself keeps working with `sessionStore ==
  nil` (in-memory only, nothing persisted).
