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
- [x] Floating panel redesign (PR #3): control bar (start/stop, language
      pickers, close button) + status bar moved onto the panel itself, menu
      bar gained mic/system-audio controls, Settings trimmed to just engine
      selection, settings persistence via `UserDefaults`. Several rounds of
      review caught real bugs along the way — see PR #3's description/commits
      rather than re-summarizing every one here.
- [x] **0.0.1 internal test build cut** (2026-09-27): version bumped in
      `Scripts/Info.plist` (`CFBundleShortVersionString` 0.0.1), CHANGELOG's
      `[Unreleased]` cut into a dated `[0.0.1]` section, ad-hoc signed only
      (no Developer ID/notarization yet — see Open Items #3) — see
      `Docs/RELEASE_TESTING.md` for what testers need to do/know.
- [x] **DMG packaging + Homebrew distribution** (2026-09-27, PRs #5/#6):
      `Scripts/build_dmg.sh` wraps `build_app.sh`'s output into an installable
      `.dmg` (app + `/Applications` symlink); README gained a download link
      and `brew tap hdcola/tap && brew install --cask omnivoice` instructions.
      Still ad-hoc signed — Developer ID signing/notarization/stapling remain
      open (see Open Items #3).
- [x] **Model providers wired up** (2026-09-27): `ModelTranscriptionProvider`/
      `ModelTranslationProvider` now run R2T2 (audio.cpp) / T3PO (llama.cpp)
      in-process, ported from `mac-poc-hybrid`'s validated
      `InProcessTranscriber`/`InProcessTranslator` — see
      `Sources/OmniVoiceCore/Inference/`. `Package.swift` gained `CAudioCpp`/
      `CLlamaCpp` C shim targets linking gitignored `third_party/`
      checkouts (setup recipe: `Docs/MODEL_ENGINE_SETUP.md`); building this
      package now requires those checkouts to exist, same trade-off
      `mac-poc-hybrid/Package.swift` accepted. Model weights are resolved via
      an `R2T2_MODEL_PATH`/`R2T2_T3PO_MODEL_PATH` env var or a repo-relative
      `models/` directory — a real per-user "download on first use" cache
      (`ProviderCatalog.ModelVariant.downloadURL`/`sha256`, still nil
      placeholders) is a separate follow-up, see Open Items #1.

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

1. **Model download-on-first-use**: `ModelTranscriptionProvider`/
   `ModelTranslationProvider` are wired up and working (see Done above), but
   still resolve weights via an env var / repo-relative `models/` directory,
   not a real per-user download cache. Needs a `ModelDownloadManager`
   (fetch `ProviderCatalog.ModelVariant.downloadURL`, verify `sha256`, cache
   under Application Support) and filling in the catalog's still-`nil`
   `downloadURL`/`sha256` fields.
2. **Settings UI wiring**: model-variant picker is currently `.disabled(true)`
   (`SettingsView.modelVariantPicker`) — enable once #1 lands, to show
   download state/trigger a download. (Device/language/system-audio controls
   landed in PR #3 — mic picker + system-audio toggle in the menu bar,
   language pickers shared between the floating panel and Settings via
   `SourceLanguagePicker`/`TargetLanguagePicker`.)
3. **Release pipeline**: DMG packaging + Homebrew tap are done (see Done
   above); still open — Developer ID signing + notarization + stapling
   (current `Scripts/build_app.sh`/`build_dmg.sh` output is ad-hoc-signed,
   dev-only, needs `xattr -cr` per `Docs/RELEASE_TESTING.md`), plus an update
   mechanism (Sparkle-shaped) and a real weights-hosting location for
   downloaded models.
4. **Privacy copy, crash/error log export, localization scaffolding** — all
   explicitly deferred ("搭架子" / stub first) per the product discussion;
   none of the actual placeholder work has been started yet.
5. **Model license re-check** — before any commercial use, not before this.

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
- Live mid-recording target-language switching (see PR #3) only works
  because `SystemTranslationProvider` bridges through a SwiftUI
  `.translationTask` that rebuilds its `TranslationSession.Configuration` on
  every change — `TranslationProvider`'s `start(config:)` is otherwise a
  one-shot call. A future `ModelTranslationProvider` (R2T2/T3PO) that
  initializes its target language once at `start()` won't get this for free;
  either add an explicit `updateTargetLanguage(_:)` to the protocol before
  that lands, or accept that model-engine translation can't retarget
  mid-recording.
- `RecordingSessionRecord.targetLanguageCode` is written once, at
  `createSession` (session start) — if the user switches target language
  mid-recording (see above), persisted history only ever shows the
  *original* target for that whole session, not each utterance's actual
  translated-into language. Fine for now (no UI exposes per-utterance target
  language anyway); would need per-utterance tracking if that ever surfaces.
- No handling yet for what happens if `SessionStore.init()` throws (disk
  full, schema mismatch after a future migration) beyond "history window has
  no data" — `RecordingSession` itself keeps working with `sessionStore ==
  nil` (in-memory only, nothing persisted).
