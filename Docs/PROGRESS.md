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
      `.app` launches and quits cleanly with no crash. **Not yet
      manually verified in the actual UI** — no mic-in-hand smoke test of a
      real recording session (see Open Items).

### Open items / next up

Roughly in the order they'll likely get tackled — not a hard commitment.

1. **Manual smoke test of the running app**: start a real recording with the
   system engines, confirm mic capture → transcript → translation →
   persisted history round-trip actually works end to end, not just "it
   compiles and launches."
2. **Model providers**: port `InProcessTranscriber`/`InProcessTranslator` from
   `mac-poc-hybrid` behind `ModelTranscriptionProvider`/
   `ModelTranslationProvider` — needs adding `CAudioCpp`/`CLlamaCpp` C target
   shims + `third_party/audio.cpp`+`third_party/llama.cpp` linker flags to
   `Package.swift` (see those two provider files' doc comments for the exact
   plan) and a first real download source for `ProviderCatalog`'s model
   variants (`downloadURL`/`sha256` are currently `nil` placeholders).
3. **Settings UI wiring**: model-variant picker is currently `.disabled(true)`
   (`SettingsView.modelVariantPicker`) — enable once #2 lands. Also currently
   no device picker in Settings (`RecordingSession.inputDevices` exists but
   nothing in the UI binds to it yet).
4. **Release pipeline**: Developer ID signing + notarization + stapling
   (current `Scripts/build_app.sh` is ad-hoc-signed, dev-only), plus an
   update mechanism (Sparkle-shaped) and a real weights-hosting location for
   downloaded models.
5. **Privacy copy, crash/error log export, localization scaffolding** — all
   explicitly deferred ("搭架子" / stub first) per the product discussion;
   none of the actual placeholder work has been started yet.
6. **Model license re-check** — before any commercial use, not before this.

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
