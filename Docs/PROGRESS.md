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
      **T3PO translation verified working end-to-end (mic → live translation
      → stop, no crash). R2T2 transcription needs the upstream audio.cpp
      patch in `Patches/audio.cpp/` applied to the `third_party` checkout —
      unpatched it SIGSEGVs on stop; see "Known gaps" below.**
- [x] **R2T2 stop/rotate crash root-caused and fixed** (2026-09-27): a null
      dereference in audio.cpp's own
      `R2T2ASRSession::build_stream_prefix(final_flush=true)`, reproduced
      deterministically from the C API with silence alone. Fix lives in
      `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch`
      and is a required step in `Docs/MODEL_ENGINE_SETUP.md`. Full writeup in
      "Known gaps" below.
- [x] **Floating panel UX pass: model preload, mic-level feedback, transcript
      auto-scroll** (2026-09-27, PR #10, merged to `main`): a "预加载模型"
      button on the panel's status bar loads a `.model`-kind engine's weights
      ahead of "开始转录" (`RecordingSession.preloadModel()`/`unloadModels()`/
      `isModelLoaded`), with a "释放模型" action to reclaim memory without an
      engine switch or quit; a live mic-level meter on the status bar while
      recording; the transcript now auto-scrolls to new lines, pausing (with
      a "最新内容" jump-back button) once the user scrolls up. Also fixed:
      models no longer reload from scratch on every "停止" (`stop()` used to
      unconditionally unload), an orphaned session record on app quit now
      gets finalized, mid-recording target-language switching now reaches
      `.model`-kind translation too (`TranslationProvider.updateTargetLanguage(_:)`),
      and several `InProcessTranscriber`/`InProcessTranslator` load/unload
      lifecycle bugs (partial-failure state, `llama_backend_init`/`free`
      pairing, blocking the main actor during load). See CHANGELOG's
      `[0.1.0]` section for the full per-commit list.
- [x] **0.1.0 release cut** (2026-09-28, `chore/release-0.1.0`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.1.0,
      `CFBundleVersion` 2), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.1.0]` section (a fresh empty `[Unreleased]` template above it),
      `README.md`'s version/download-link references bumped to match. Still
      ad-hoc signed only (no Developer ID/notarization yet — see Open Items
      #4) — see `Docs/RELEASE_TESTING.md` for what testers need to do/know.
      Bundles everything merged since `0.0.1`: the model download/cache
      manager + dedicated "模型管理" window (PRs #11/#12), and the Model
      Management UX + floating-panel-position/opacity follow-up (PR #13).
- [x] **0.1.1 release cut** (2026-09-28, `chore/release-0.1.1`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.1.1,
      `CFBundleVersion` 3), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.1.1]` section, `README.md`'s version/download-link references
      bumped to match. Fixes a real, user-reported crash: the 0.1.0 Homebrew
      cask's `OmniVoice.app` linked `libaudiocpp`/`libllama`/`libggml-*` via
      absolute `-rpath` entries pointing at the build machine's
      `third_party/` checkout, so every packaged build died on launch on any
      other machine with `dyld: Library not loaded: @rpath/libaudiocpp.0.dylib`
      — `Scripts/build_app.sh` now embeds those dylibs into
      `Contents/Frameworks` and rewrites rpaths to be relocatable (PRs
      #18/#20; verified end-to-end on a machine with `third_party` actually
      built — see those PRs' review comments). Still ad-hoc signed only
      (no Developer ID/notarization yet — see Open Items #4).

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

1. **Land the R2T2 fix upstream**: the crash is root-caused and fixed locally
   (see "Known gaps" below), and submitted as
   [0xShug0/audio.cpp#712](https://github.com/0xShug0/audio.cpp/pull/712)
   (verified still broken on upstream `main`, `90c56c2e`). Until that merges
   and a release carrying it is pinned, the fix lives only as
   `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch` and
   every checkout has to apply it by hand. When it lands: bump the pin, drop
   the patch, and drop the `git apply` step from
   `Docs/MODEL_ENGINE_SETUP.md`.
2. **Model download-on-first-use** (branch `feature/model-download-manager`):
   `ModelDownloadManager`
   (`Sources/OmniVoiceCore/Inference/ModelDownloadManager.swift`) downloads a
   `ModelVariant`'s weights into an Application Support cache keyed by
   `variant.id`, verifying SHA-256 before the file is considered usable, with
   progress/cancellation support. `ProviderCatalog`'s `r2t2-q8_0`/
   `t3po-q5_k_m` entries now carry real Hugging Face `downloadURL`/`sha256`
   (fixed `approximateSizeMB` too — the old 1500/1100 MB placeholders were
   roughly an order of magnitude off for T3PO: actual ~2.4GB/~9.8GB). Manually
   verified end-to-end against a real HTTPS download (not part of the
   committed test suite — a multi-GB download has no place in CI). **Now
   wired into `RecordingSession`/`SettingsView`** — see #3 below.
3. **`ModelDownloadManager` wired into `RecordingSession`; dedicated "模型管理"
   window for download/cancel/delete**: `RecordingSession` gained a
   persisted `transcriptionModelVariantID`/`translationModelVariantID`
   selection per `.model`-kind engine (mirroring `transcriptionEngineID`'s
   restore/self-heal pattern — `currentTranscriptionModelVariant`/
   `currentTranslationModelVariant` fall back to the catalog's first variant
   for an unset/stale ID). Downloading a variant's weights is never
   implicit: `resolveModelPath` (called from `preloadModel()`/`start()`)
   resolves an already-cached variant's local path, or fails fast with a
   friendly "「...」尚未下载，请先在「模型管理」中下载" `statusMessage`
   instead of silently kicking off a multi-GB transfer with no way to back
   out — the only place that ever calls
   `ModelDownloadManager.ensureDownloaded(_:progress:)`/`cancelDownload(for:)`/
   `deleteCachedModel(for:)` is the new `ModelManagementView` (opened from
   the menu bar, or a "模型管理…" button next to each engine `Picker` in
   Settings), which lists every `ProviderCatalog.modelVariants` entry with
   an explicit 下载/取消/删除 action per row (disabling "删除" while a
   recording/preload is active). `SettingsView`'s engine `Picker` only lists
   a `.model`-kind engine once something for it is downloaded, and its
   variant picker only lists downloaded variants — both keep the
   *currently-selected* engine/variant visible regardless (marked
   "（未下载）") so the `Picker`'s binding never points at a tag missing
   from its own options, which SwiftUI would otherwise render as a
   blank/no-selection control. Review also caught `loadedEngineIDs`/
   `start()`'s `reusingLoaded` only ever comparing engine IDs, not the
   selected variant — switching a `.model` engine's variant while the
   *previous* one was already loaded left `isModelLoaded` reading "still
   matches", silently running the stale variant forever; fixed by folding
   variant IDs into that comparison and having the variant properties'
   `didSet` call `discardLoadedModelsIfStale()` too. Only one variant per
   engine exists in the catalog today, so this mostly plumbs the mechanism
   through for whenever a second quantization/size is added. Known minor
   gap: if the currently-selected engine's last downloaded variant is
   deleted via Model Management while Settings isn't open, that engine's
   `Picker` row just reads "（未下载）" next time Settings opens rather than
   silently reverting to a different engine — `start()`/`preloadModel()`
   still handle it gracefully either way (the same friendly "尚未下载"
   message).
- [x] **Model Management UX follow-up** (2026-09-27, `fixbug/model-management-ux`):
   a `.model`-kind engine selection now self-heals back to its `.system`
   counterpart the instant nothing is downloaded for it
   (`RecordingSession.fallBackToSystemEngineIfModelUnavailable()` — called on
   launch, right after a delete in `ModelManagementView`, and defensively at
   the top of `preloadModel()`/`start()`), so the "尚未下载" `statusMessage`
   from the previous entry above is now effectively unreachable in normal use
   rather than something a user actually hits after deleting/never
   downloading a model. `SettingsView` also gained a hint under each engine
   picker pointing at "模型管理…" when nothing's downloaded for that
   category, and download progress is now visible outside the Model
   Management window itself — the menu bar icon and the "模型管理…" menu row
   both show a live percentage while a download is in flight
   (`ModelDownloadManager.hasActiveDownloads`). The floating panel also now
   remembers its position/size across quit/relaunch (AppKit's own frame
   autosave, `FloatingTranscriptPanel`) instead of always recentering at a
   fixed 420×280 — a brand-new panel (nothing saved yet) now opens at the
   screen's bottom-center instead, where live captions conventionally sit.
   Settings also gained a "悬浮窗" section with two independent transparency
   sliders — "背景透明度" (`RecordingSession.panelBackgroundOpacity`) and
   "内容透明度" (`panelContentOpacity`) — so the panel's background can be
   made to occlude less of whatever's behind it without also fading the
   transcript text/controls into illegibility (a first version used one
   shared `NSWindow.alphaValue`, which faded both together; a second used
   "文字透明度" for the latter, renamed to "内容透明度" since it fades every
   control, not just the transcript text). A code review pass on this whole
   follow-up also added test coverage for the new opacity properties (and
   the translation-side undownloaded-model fallback, and
   `ModelDownloadManager.hasActiveDownloads`), fixed `Int(x * 100)`
   percentage-jitter from binary floating-point rounding (now `.rounded()`,
   `SettingsView`/`MenuBarContentView`/`ModelManagementView` — a second
   review pass caught the last of the three), and simplified
   `FloatingTranscriptPanel.init`'s frame restore to a single
   `setFrameAutosaveName` call (it already restores + reports success on
   its own — a separate `setFrameUsingName` call first was redundant). That
   second pass also made `positionAtBottomCenterOfScreen()` fall back to
   `NSScreen.screens.first` before `center()` (`NSScreen.main` — the screen
   holding the key window — can read `nil` for the brief window right at
   launch before this never-key/never-main accessory app has any window the
   system considers key/main yet), and made `ModelDownloadManager`'s
   job-cleanup `defer` call `objectWillChange.send()` explicitly rather than
   relying on a `@Published` dictionary mutation to imply it.
4. **Release pipeline**: DMG packaging + Homebrew tap are done (see Done
   above); still open — Developer ID signing + notarization + stapling
   (current `Scripts/build_app.sh`/`build_dmg.sh` output is ad-hoc-signed,
   dev-only, needs `xattr -cr` per `Docs/RELEASE_TESTING.md`), plus an update
   mechanism (Sparkle-shaped) and a real weights-hosting location for
   downloaded models.
5. **Privacy copy, crash/error log export, localization scaffolding** — all
   explicitly deferred ("搭架子" / stub first) per the product discussion;
   none of the actual placeholder work has been started yet.
6. **Model license re-check** — before any commercial use, not before this.

### Known gaps / things to double check when touching nearby code

- **R2T2 (`model.r2t2`) SIGSEGVs the whole process on an unpatched
  audio.cpp — root-caused and fixed, but the fix is a local patch.**
  `audiocpp_stream_finish` — reached from `InProcessTranscriber.finishStream()`
  (Stop) or `rotateStream()` (a VAD boundary mid-recording) — crashes 3
  frames deep inside `libaudiocpp`. The earlier guess ("`reuse_graph=true`
  reacting badly to a differently-shaped final chunk") was wrong; the real
  cause is plain:

  `R2T2ASRSession::build_stream_prefix(final_flush=true)`
  (`src/community_models/confucius4_r2t2/session.cpp:304`) clamps its
  rollback end index to a minimum of 1 — "never roll back past the first
  token" — then builds a `std::vector<int32_t>` from
  `[ids.begin(), ids.begin() + end_index)`. With `ids` empty there is no
  first token: `begin()` is null and the range ctor `memmove`s 4 bytes from
  address `0` (the crash reports show exactly that — `x1=0x0`, `x2=0x4`,
  faulting in `_platform_memmove`). `ids` is empty whenever the session's
  `raw_decoded_` has decoded to `""` by finish time, reachable once
  `chunk_id_ >= unfixed_chunk_num` (2, i.e. ~640 ms at our 320 ms chunks).
  A forced request language makes it easy to hit: the "no `<asr_text>` tag
  yet, nothing to commit" early-out in `decode_stream_chunk()` only applies
  when `force_language_` is empty, so `chunk_id_` keeps advancing over chunks
  that decode to nothing (silence, a trailing pause), and any partial chunk
  left in `buffer_` then sends `finalize()` down the final-flush path.

  Reproduced deterministically against the unpatched dylib from the C API
  alone — force a language, push four 320 ms chunks of *silence* plus a
  2000-frame partial chunk, `audiocpp_stream_finish()` — matching the app's
  crash reports frame for frame, offset for offset, register for register.
  No mic, no long utterance needed; "after a longer utterance" was just the
  easiest way to reach `chunk_id_ >= 2` with an empty tail. Fixed by
  `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch`
  (bail out early when `ids` is empty). **Every `third_party/audio.cpp`
  checkout must apply that patch** — it is a step in
  `Docs/MODEL_ENGINE_SETUP.md`, and it is not upstream yet
  ([audio.cpp#712](https://github.com/0xShug0/audio.cpp/pull/712), Open
  Items #1).
  This was never a regression from porting `mac-poc-hybrid`; that reference
  has the same bug, which is consistent with its CHANGELOG admitting this
  interactive flow had never been manually run. T3PO translation
  (llama.cpp) was never affected.
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
