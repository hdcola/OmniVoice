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
meeting, on a call). Quick translate (快捷翻译) covers the text side: select
anything in any app (划词翻译, ⌥A) or frame part of the screen (截图翻译,
⌥S) and a second panel (翻译面板) translates it fully on-device — the
system Translation framework or HY-MT1.5, independent of the recording
pipeline (PR #40).

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
      → stop, no crash). R2T2 transcription needs an audio.cpp at or past
      the pin in `Docs/MODEL_ENGINE_SETUP.md` (the upstream stop-crash fix,
      0xShug0/audio.cpp#712); older builds SIGSEGV on stop.**
- [x] **R2T2 stop/rotate crash root-caused and fixed** (2026-09-27): a null
      dereference in audio.cpp's own
      `R2T2ASRSession::build_stream_prefix(final_flush=true)`, reproduced
      deterministically from the C API with silence alone. Originally carried as
      a local patch; now fixed upstream (0xShug0/audio.cpp#712) and picked up
      via the pin in `Docs/MODEL_ENGINE_SETUP.md` — see Open Items #1. Full
      writeup in "Known gaps" below.
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

- [x] **HY-MT1.5 wired up as a second, one-shot local translation engine**
      (2026-09-28): added `model.hymt15` alongside `model.t3po` in
      `ProviderCatalog` (two variants: HY-MT1.5-1.8B Q4_K_M ~1.06GB/Q8_0
      ~1.82GB — a genuinely low-memory option, since neither R2T2's nor
      T3PO's own HF repos carry anything smaller than what's already
      pinned). Unlike T3PO, HY-MT1.5 has no trained WAIT/TRANS control
      signal (see "Known gaps" below) — `HYMT15Translator`
      (`Sources/OmniVoiceCore/Inference/HYMT15Translator.swift`) never
      probes mid-utterance or emits a preview: `feed()` only buffers,
      `flush()` translates the whole buffer once, same cadence
      `SystemTranslationProvider` uses. Wrapped by
      `HYMT15TranslationProvider` (`TranslationProvider` conformance,
      mirrors `ModelTranslationProvider`'s shape) and dispatched from
      `RecordingSession.makeTranslationProvider(engineID:modelPath:)`,
      which now switches on `engineID` itself (not just
      `EngineDescriptor.kind`) since translation has two different
      `.model`-kind provider classes. The mechanical llama.cpp plumbing
      shared by both models (tokenize, chat-template application, the
      clear-KV-cache-and-decode loop) was extracted into
      `LlamaGenerationSupport.swift` as a pure refactor of
      `InProcessTranslator` first (verified: all 70 existing tests still
      pass, T3PO's behavior unchanged) before `HYMT15Translator` was added
      on top of it. **Mic-driven UI smoke test done** (2026-09-28, Open
      Items #7): downloaded the real HY-MT1.5-1.8B Q4_K_M weights, selected
      `model.hymt15` in Settings, recorded live mic audio, and stopped — a
      one-shot translation landed per segment as expected, no crash. HY-MT1.5's
      license is still unclear (no LICENSE file found in its HF repos),
      same "re-check before commercial use" bucket as R2T2/T3PO, arguably
      needing more attention since it doesn't even have a clear license file
      today.

- [x] **System-audio-only recording ("无" mic option)** (2026-09-28): added
      `AudioInputDevice.none`/`.noneID` as a real, always-present entry named
      "无" in the microphone picker (`RecordingSession.refreshDevices()`) —
      not "无（仅系统声音）" as an earlier version of this had it, since
      "包含系统声音" is a separate, independently-toggled setting, not implied
      by this one. For recording a meeting/lecture played through the Mac's
      own output with no one talking into a mic. Selecting it skips
      `MicrophoneCapture` entirely in `start()` and puts `AudioMixer` into a
      `micEnabled: false` mode where system audio (not the mic) drives the
      whole pipeline directly — including `UtteranceSegmenter`'s VAD, which
      previously only ever saw raw mic samples (`mic.onBuffer`), so without
      this it would never have fired a single utterance boundary with no mic
      present. `start()` fails fast with a friendly `statusMessage` if "无"
      is selected while "包含系统声音" is off (no audio source at all), and
      aborts the same way mid-`start()` if system-audio capture itself then
      fails to start (unlike the normal mic+system-audio case, there's no
      mic-only fallback to quietly continue with).
- [x] **User-configurable translation commit eagerness, for every engine**
      (2026-09-28, two iterations): `TranslationCommitEagerness`
      (`.fast`/`.balanced`/`.thorough`) is this app's own vocabulary for "how
      eagerly does T3PO commit vs. wait for more context" — threaded through
      `TranslationConfig.commitEagerness` (initial value) and
      `TranslationProvider.updateCommitEagerness(_:)` (mid-recording
      changes), exactly `updateTargetLanguage(_:)`'s existing two-path
      pattern. T3PO maps it onto its existing `TranslationLatencyMode`/`tau`
      calibration inside `ModelTranslationProvider`; only `model.t3po` has a
      WAIT/TRANS decision to bias in the first place, so `SettingsView`
      shows this picker only for that engine. HY-MT1.5/system translation —
      one-shot engines with no WAIT/TRANS concept — instead read a separate,
      directly user-configurable `RecordingSession.translationEarlyTranslateThreshold`
      (a plain character count, default 150, range 20...1000, a `Stepper` in
      `SettingsView` shown for those two engines instead of the eagerness
      picker) threaded through `TranslationConfig.earlyTranslateThreshold`/
      `TranslationProvider.updateEarlyTranslateThreshold(_:)` — a second,
      independent setting rather than a 4th case of
      `TranslationCommitEagerness`, since a one-shot engine's "how long is
      too long" has no probabilistic-bias equivalent to keep in the same
      small enum (first version of this had one-shot engines reading fixed
      per-`TranslationCommitEagerness`-case numbers instead; replaced after
      feedback that the actual thresholds should be user-adjustable, not
      just a 3-tier preset). Once the buffer crosses half that threshold,
      these engines watch for the next newly-fed delta that ends a sentence
      (`SentenceBoundary.endsSentence`) and translate as soon as one arrives,
      instead of cutting mid-sentence purely by length — same idea as T3PO's
      own `forceBreakThreshold`+`SentenceBoundary` combination; crossing the
      full threshold forces a translation regardless of punctuation, so
      continuous unpunctuated speech still can't grow the buffer without
      limit. That early translation is a "sub-commit", not a real flush:
      `HYMT15Translator.feed(sourceDelta:)` reuses `translateBufferLocked()`
      (the same primitive `flush()` calls, which only ever fires `onCommit`,
      never `onFlushBoundary`) so it appends into the segment's still-open
      translation row instead of closing it — mirroring T3PO's own
      forced-probe-vs-real-flush distinction. `SystemTranslationProvider`
      needed the same distinction plumbed through its async SwiftUI
      `.translationTask` bridge, since its actual translation happens later
      than `feed`/`flush` return: `TranslationBridgeRequest` gained an
      `isFinal` flag, `receiveResult(_:)` became `receiveResult(_:isFinal:)`,
      and `RecordingSession.resolveTranslationBridgeResult(_:)`/
      `FloatingTranscriptView`'s `.translationTask` loop now thread that flag
      through so only a final result advances `translationRowIndex`.
- [x] **0.2.0 release cut** (2026-09-29, `chore/release-0.2.0`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.2.0,
      `CFBundleVersion` 4), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.2.0]` section, `README.md`'s version/download-link references
      bumped to match. Bundles everything merged since `0.1.1`: Tencent's
      HY-MT1.5 1.8B as a second local translation engine, a "无" mic option
      for system-audio-only recording, user-configurable translation commit
      timing, several `SystemTranslationProvider`/HY-MT1.5/`llama.cpp`
      correctness fixes (PR #27), and the macOS application icon +
      packaging work (PR #28).
- [x] **0.3.0 release cut** (2026-09-29, `chore/release-0.3.0`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.3.0,
      `CFBundleVersion` 5), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.3.0]` section, `README.md`'s version/download-link references
      bumped to match. Bundles everything merged since `0.2.0`: the UI/UX
      optimization pass — history delete/rename + richer row metadata, panel
      text selection/copy, auto-hiding controls, display-mode and font-size
      presets, a live elapsed-time readout, a menu-bar recording indicator,
      and permission deep links (PR #30, including its code-review fix
      round), plus `Scripts/setup_third_party.sh` to automate the
      `third_party` clone/build setup (PR #31).
- [x] **0.3.1 release cut** (2026-09-29, `chore/release-0.3.1`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.3.1,
      `CFBundleVersion` 6), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.3.1]` section, `README.md`'s version/download-link references
      bumped to match. Bundles everything merged since `0.3.0`: the
      settings/model-management UX redesign — engine list with undownloaded
      models, rich model cards + recommended bundles with per-variant
      download speed/ETA, a unified tabbed Settings window, a first-run
      onboarding wizard with three mode choices, disk-space pre-flight and
      inline download retry, plus the model-download/bundle-status review
      fixes (PR #33, including its code-review fix rounds).
- [x] **0.4.0 release cut** (2026-09-30, `chore/release-0.4.0`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.4.0,
      `CFBundleVersion` 7), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.4.0]` section, `README.md`'s version/download-link references
      bumped to match. Bundles everything merged since `0.3.1`: local
      model translation engineering enhancements inspired by Cida
      (`EntityMasker` technical term / URL / CLI-flag masking and
      restoration, prompt contract isolation and sliding context window
      for HY-MT1.5, defensive quote/fence unwrapping fixpoint, live vs.
      committed transcript visual styling, PR #38), XCUITest test
      infrastructure and automated UI testing coverage (PR #36), and CI
      build regression workflow (PR #37).
- [x] **0.5.0 release cut** (2026-09-30, `chore/release-0.5.0`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.5.0,
      `CFBundleVersion` 8), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.5.0]` section, `README.md`'s version/download-link references
      bumped to match. Bundles everything merged since `0.4.0`: 选词翻译
      (PR #40) — ⌥A selection translation and ⌥S screenshot translation in
      a new 翻译面板 with a 选词翻译 settings tab, shared `HYMT15ModelPool`
      weights, and one-shot `HYMT15Translator.translateText` — plus floating
      panel toolbar/resize-cursor fixes (PR #41), the 启动时显示悬浮窗 toggle
      (PR #42), and the terminology unification pass (PR #43).
- [x] **0.5.3 release cut** (2026-10-01, `chore/release-0.5.3`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.5.3,
      `CFBundleVersion` 11), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.5.3]` section, `README.md`'s version/download-link references
      bumped to match. Bundles the system notification when a model download
      finishes or fails (PR #55, closes #22) and opening Settings → 模型库
      when it is clicked (PR #56).
- [x] **0.5.2 release cut** (2026-10-01, `chore/release-0.5.2`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.5.2,
      `CFBundleVersion` 10), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.5.2]` section, `README.md`'s version/download-link references
      bumped to match. Bundles launch-at-login and launch-time model
      preloading (PR #50, closes #46), the `org.omnivoice.*` →
      `org.hdcola.omnivoice.*` key rename (PR #49; saved settings reset), and
      the removal of the outdated R2T2 patch notes (PR #53).
- [x] **0.5.1 release cut** (2026-09-30, `chore/release-0.5.1`): version
      bumped in `Scripts/Info.plist` (`CFBundleShortVersionString` 0.5.1,
      `CFBundleVersion` 9), CHANGELOG's `[Unreleased]` cut into a dated
      `[0.5.1]` section, `README.md`'s version/download-link references
      bumped to match. Bundles the settings/onboarding UI redesign (PR
      #47): card-style Settings with a pill tab bar, the three engine/
      language/quick-translate tabs merged into one "通用" tab (3 tabs now),
      all permissions (麦克风 / 屏幕录制 / 辅助功能) together at the top, a
      restyled "模型库" and "关于", and a restyled first-launch window that
      now also asks for Accessibility.

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

### Code review findings, PR #27 (fixed)

Two review rounds on PR #27 (HY-MT1.5 + no-mic recording + configurable
translation timing), both fixed on `feature/hymt15-translation-engine`
before merge:

**Round 1** caught two real bugs and one repo-process gap:

- **`SystemTranslationProvider` row misalignment, take two**: the
  `earlyTranslateThreshold` feature reintroduced a version of the original
  scaffold-PR bug above — an early (non-final) bridge request drains
  `buffer`, so a `flush()` arriving before that request's async result comes
  back sees an *empty* buffer and, previously, fired `onFlushBoundary`
  immediately anyway, advancing `translationRowIndex` before the pending
  request's `onCommit` ever landed — misrouting that commit into the next
  segment's row once it finally resolved. First fix attempt used a
  `pendingBridgeRequestCount`/`pendingFlushBoundary` pair to defer the
  boundary — **round 2** found that attempt itself still broke on a second
  utterance starting before the first one's early request resolved (see
  below), so the final fix is different — see that entry.
- **`LlamaGenerationSupport.applyChatTemplate` buffer-resize retry could
  read out of bounds**: `llama_chat_apply_template`'s C++ implementation
  copies the formatted prompt via `strncpy(buf, formatted_chat.c_str(),
  length)`, which only null-terminates when `length` is *larger* than the
  source — resizing the retry buffer to exactly `n` (the reported byte
  count) left no room for a `\0` anywhere in it, so the following
  `String(cString:)` could read past the buffer hunting for one. First fix
  attempt allocated `n + 1` but left the *trigger condition* (`if n >
  bufSize`) unfixed — **round 2** caught that too (see below). Also
  hardened `LlamaGeneration.generate` alongside it: the token buffer is now
  sized from an exact `tokenCount(of:vocab:)` dry run instead of a
  `prompt.utf8.count + 16` guess (not reliably >= the real token count for
  every tokenizer/language), and generated token pieces are now accumulated
  as raw bytes and decoded to UTF-8 once at the end instead of per token —
  a byte-level BPE vocab can split one multi-byte CJK character across more
  than one token, and decoding each piece independently could hit an
  incomplete byte sequence mid-character and silently corrupt it into
  U+FFFD.
- **Missing `CHANGELOG.md` entries**: `AGENTS.md`'s "All user-facing changes
  must be recorded in `CHANGELOG.md`" wasn't followed for this PR's three
  features. Added under `[Unreleased]`.

Also added in round 1, defensively, not in response to a real bug:
`AudioMixer.submitMic` now guards `micEnabled` itself too (mirroring
`submitSystemAudio`'s existing guard) — nothing calls it in
`micEnabled: false` mode today, since `RecordingSession.start()` never
constructs a `MicrophoneCapture` in that mode, but the class's own
invariant should hold regardless of a future caller's wiring.

**Round 2** re-reviewed round 1's own fixes and caught two of them were
still wrong, plus one real UX gap and one false-positive report (kept here
for the record — it's useful to know a report was checked and rejected, not
just which ones were accepted):

- **`SystemTranslationProvider`'s round-1 fix could still permanently
  swallow a boundary**: `pendingFlushBoundary` was a single flag — it could
  only remember "one boundary is owed", not "how many". Trace: utterance 1
  sends an early request then ends (`flush()` defers, `pendingFlushBoundary
  = true`); before that request resolves, utterance 2 begins *and ends too*
  (its own `flush()` finds a non-empty buffer, sends a normal final
  request, `pendingBridgeRequestCount` now counts both). Utterance 1's
  early request finally resolves — `pendingBridgeRequestCount` drops to 1,
  not 0, so the deferred boundary still doesn't fire. Utterance 2's final
  request then resolves, firing `onFlushBoundary` *once* for what were
  really two utterances — permanently losing one boundary, merging both
  utterances' text into one row, and misaligning every row after it.
  Rewritten to a design with no separate flag/counter-threshold logic at
  all: `sendBridgeRequest(isFinal:)` now sends an empty-text, `isFinal:
  true` **sentinel** request through the same bridge instead of deferring
  internally, relying on `FloatingTranscriptView`'s `.translationTask` loop
  already consuming `translationBridgeStream()` strictly in FIFO order (one
  request fully resolved before the next is even dequeued) to guarantee the
  sentinel resolves in the correct position automatically. `receiveResult(_:isFinal:)`
  simply skips `onCommit` for an empty result and fires `onFlushBoundary`
  for every final result, sentinel or not — no bookkeeping beyond a plain
  `pendingBridgeRequestCount` (kept only so a *true* "nothing pending"
  `flush()` can still fire immediately without a round trip). Regression
  test (`twoUtterancesInFlightAtOnceEachGetTheirOwnBoundaryAndCommit`)
  reproduces the exact two-utterance trace above.
- **`LlamaGenerationSupport.applyChatTemplate`'s retry condition missed the
  exact-fit case**: `if n > bufSize` skips the resize-and-retry whenever the
  formatted prompt's length lands *exactly* on the initial 8192-byte
  buffer — `strncpy` still doesn't null-terminate in that case (per the
  round-1 finding above), so `n == bufSize` was just as unterminated as
  `n > bufSize`, silently falling through to the same out-of-bounds
  `String(cString:)` read. Fixed to `if n >= bufSize`.
- **UX gap, not a bug**: `RecordingSession.appendTranslation` concatenated
  multiple commits into one row (T3PO's mid-segment forced probes, or a
  one-shot engine's `earlyTranslateThreshold`-driven early commit) with no
  separator — fine for Chinese/Japanese (no inter-word spacing), but for a
  space-separated target language (English, Korean) two fragments joined
  mid-sentence read as "store.And bought" with no space. Fixed by inserting
  a single space between fragments for those languages, skipped if either
  side already has whitespace there.
- **False positive, checked and rejected**: the review flagged
  `RecordingSession.init()`'s restore of a persisted
  `translationEarlyTranslateThreshold` as bypassing the property's own
  `didSet` clamp (`min...max(20...1000)`), since Swift documents that
  property observers don't fire during a class's own initializer. Verified
  empirically with a throwaway test (persist `99999`, construct a fresh
  `RecordingSession`, assert the restored value): `didSet` *does* fire for
  a plain assignment written later in `init()`'s body (as opposed to a
  property's own default-value literal) — the "observers don't fire in
  init" exemption is only for that literal default, not for a subsequent
  ordinary assignment statement in the same initializer. No code change
  needed; noted here so this exact (plausible-sounding, but wrong) claim
  doesn't get "fixed" again without re-checking it.

Also added in round 2, as suggested test coverage rather than a bug fix:
`AudioMixerTests` (mic-enabled/disabled dispatch, mixing/clipping, level
calculation — this class had no dedicated tests before this PR added its
`micEnabled` mode).

**Round 3** caught one more real bug (a leftover from round 2's own fix),
one robustness gap, one documentation inaccuracy with a real behavioral
consequence, and confirmed one prior finding was already an accepted,
documented trade-off rather than something to fix:

- **`SystemTranslationProvider.start(config:)`/`stop()` never reset
  `pendingBridgeRequestCount`**: round 2's FIFO-sentinel fix added this
  counter but never cleared it — a request left unresolved from an
  interrupted prior session (the panel torn down mid-translate, or the
  recording stopped before the on-device translate call returned) would
  leak a stale positive count into the next session using the same
  instance (`.system`-kind providers are eligible for the same
  `reusingLoaded` reuse path a `.model`-kind engine's weights use), making
  that session's very first empty `flush()` wrongly believe something was
  still in flight and send a needless sentinel request. Fixed by resetting
  the count in both `start(config:)` and `stop()`.
- **`LlamaGeneration.generate`'s `llama_token_to_piece` call didn't handle
  its negative-return convention**: same "return `-size` when the buffer's
  too small" convention as `llama_tokenize`/`llama_chat_apply_template`
  (see the round-1/round-2 findings above) — the 64-byte `pieceBuf` covers
  a typical single-token piece but isn't guaranteed for every one (a long
  byte-fallback sequence or an unusual special/control token), and the code
  only checked `n > 0`, silently dropping that token's contribution to the
  output entirely on a negative return with no sign anything went wrong.
  Fixed with the same retry-with-exact-size pattern used elsewhere in this
  file.
- **`ModelLanguageMapping`'s docs claimed `LanguageCatalog` "only ever
  offers `zh`/`en`/`ja`/`ko`"** — false; it offers 16 (see
  `LanguageCatalog.common`), and `TargetLanguagePicker` doesn't filter by
  engine, unlike `SourceLanguagePicker`'s existing
  `supportsSystemASRSource` filtering. So picking most of those 16 while a
  local model engine is selected silently mistranslates into Chinese with
  no error — a real, if pre-existing (not introduced by this PR), UX gap,
  not just a wrong comment. Fixed the docs to say so accurately; the actual
  behavioral fix (extending `HYMT15TargetLanguage`/`T3POTargetLanguage`'s
  coverage, and/or gating the picker per engine) is scoped as a follow-up,
  not pulled into this PR — see "Known gaps" below.
- **Confirmed as an accepted trade-off, not a new finding**:
  `HYMT15Translator.translateBufferLocked`'s context-overflow trim drops
  from the *front of the untranslated source text itself* (unlike T3PO,
  which trims already-translated history) — permanently losing whatever
  was said first in an exceptionally long buffer, rather than gracefully
  degrading. Only reachable with an extreme `earlyTranslateThreshold`
  setting on a small context window; the code comment now says so
  explicitly instead of implying (via "same concern...documents") that
  it's exactly analogous to T3PO's safe history-trimming.

**Round 4** caught two more real bugs (one severe) and two real UX
follow-ups:

- **`SystemTranslationProvider.sendBridgeRequest(isFinal:)` cleared
  `buffer` before checking whether there was anywhere to send it**: for a
  **non-final** (early) send with no bridging view attached yet
  (`onBridgeRequest == nil`), `buffer = ""` ran unconditionally, then the
  `guard let onBridgeRequest else { ...; return }` branch returned without
  ever restoring it — silently and *permanently* dropping that text (worse
  than the accepted "lose one row's translation" trade-off for the
  **final** case, which is a deliberate segment-boundary decision, not an
  accident). Fixed by only clearing `buffer` once a send actually can
  happen, or for the already-accepted final/no-bridge case; a non-final
  send with nowhere to go now leaves `buffer` untouched so the text goes
  out whenever a bridge *does* become available. Added a regression test.
- **`LlamaGeneration.generate` used a `llama_batch` after the pointer
  backing it was only guaranteed valid for**: `llama_batch_get_one` just
  wraps whatever pointer it's given (doesn't copy the array's contents),
  and Swift's `&array`/`&scalar` pointer conversion is documented as valid
  *only during the call it's passed to* — constructing the batch in one
  statement (`let initialBatch = llama_batch_get_one(&tokens, ...)`) and
  using it in a later, separate call (`llama_decode(ctx, initialBatch)`)
  is undefined behavior even though it happens to work against the current
  toolchain. This pattern was ported unchanged from `InProcessTranslator`'s
  original (pre-this-PR) code when it was extracted into
  `LlamaGenerationSupport.generate`, not introduced by this PR — but now
  shared by both T3PO and HY-MT1.5, worth fixing here. Fixed by
  constructing and decoding each batch inside the same
  `withUnsafeMutableBufferPointer`/`withUnsafeMutablePointer` closure, so
  both stay within the pointer's one guaranteed-valid scope.
- **HY-MT1.5's `maxNewTokens = 200` risked truncating a long translation**:
  copied from T3PO's own constant, but T3PO always translates one small,
  already-committed delta at a time (short output by construction) while
  HY-MT1.5 translates a whole buffered utterance in one call — and
  `earlyTranslateThreshold` is user-configurable up to 1000 characters,
  comfortably capable of needing a translation longer than 200 tokens
  (~130-180 English words) with no indication anything was cut off. Bumped
  to 1024, well within the context-budget headroom
  `translateBufferLocked`'s own trimming already accounts for.
- **UX follow-up**: `appendTranslation`'s space-insertion fix (round 2
  above) didn't check whether the *new* fragment itself starts with
  punctuation — a translated chunk's boundary doesn't have to land on the
  same word/clause break the source text's did, so a fragment could start
  with e.g. a comma, producing "Hello , world." instead of "Hello, world."
  Fixed by also skipping the space when `text.first?.isPunctuation` is
  true.
- **UX follow-up**: a mid-recording target-language change rebuilds
  `FloatingTranscriptView`'s whole bridge stream/continuation
  (`RecordingSession.translationBridgeStream()` creates a fresh one every
  call), abandoning whatever was consuming the old one — any request
  already sent through it that hadn't resolved yet never would, leaking
  `pendingBridgeRequestCount` the same way round 3's stop/start-reuse gap
  did, just via a different trigger. Fixed by implementing
  `updateTargetLanguage(_:)` (previously the inherited no-op — this
  provider has no persistent per-session target to actually retarget, see
  that method's protocol doc) to reset the counter too. A narrow window
  where a request genuinely still resolving through the not-yet-torn-down
  old stream races this reset is accepted, not chased further — see the
  method's own doc for why (that request's translation content is already
  lost either way once its stream is abandoned; this fix is only about the
  counter, not recovering it).

**Round 5** — framed by its own review as findings/follow-up notes rather
than urgent bugs, but two were real robustness fixes worth taking anyway:

- **`earlyTranslateThreshold` is effectively inert for the system
  transcription engine, not just less useful** — confirmed by checking
  `SystemTranscriptionProvider`'s own doc: a finalized result *is* its
  segment boundary, so it never reports committed text via `.appended`
  while someone is still talking. `RecordingSession.handle(_:)`'s
  `.segmentClosed` case is the *only* time a translation provider ever sees
  that segment's text at all — one `feed(_:)` call with the whole
  utterance, immediately followed by `flush()` in the same call — so
  there's no still-talking window left for an early translation to beat.
  This is correct, expected behavior (translating still-changing volatile
  ASR text would waste compute and flicker, exactly like the existing
  "translation never runs on `.revised` text" rule this project already
  documents), not a bug — but it wasn't documented anywhere, so a user
  could reasonably expect the "长句提前翻译阈值" setting to help while using
  the system ASR engine, when it can't. Documented in
  `TranslationConfig.earlyTranslateThreshold`'s doc, and `SettingsView` now
  shows a caption under that setting when the system transcription engine
  is selected, saying so.
- **`SentenceBoundary.endsSentence`/`endsWithBreak` trimmed only
  `.whitespaces`, not `.whitespacesAndNewlines`** — an ASR delta trailing
  in a newline would leave `.last` reading the newline itself, never the
  real sentence-ending punctuation before it, silently defeating the
  check. This directly affects the `earlyTranslateThreshold` soft-break
  logic added in this PR (and, pre-existing, T3PO's own
  `forceBreakThreshold`+`SentenceBoundary` combo), so fixed rather than
  left as a documentation-only note.
- **`LlamaGenerationSupport`'s tokenize calls used `strlen(textPtr)` on a
  C string instead of the Swift string's own `utf8.count`** — functionally
  equivalent for ordinary text, but `strlen` stops at the first `\0` byte,
  silently undercounting for the (unlikely, but possible) case of an input
  containing an embedded null; `text.utf8.count` has no such blind spot
  and needs no pointer scan to get it. Fixed both call sites
  (`tokenCount(of:vocab:)` and `generate`'s own tokenize call).
- **Confirmed as already covered, not a new finding**: a translated
  fragment starting with an opening quote/paren (`isPunctuation` is also
  true for those) would skip the inter-fragment space `appendTranslation`
  inserts, same as a fragment starting with closing punctuation — e.g.
  `He said:"hello"` instead of `He said: "hello"`. Left as-is per the
  review's own conclusion: a model's sentence/clause split essentially
  never lands right before an opening quote/paren in practice, so this
  edge case isn't worth special-casing away from the general
  "`isPunctuation` means no space" rule.

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

1. ~~**Land the R2T2 fix upstream**~~ — **done** (2026-09-28): merged as
   [0xShug0/audio.cpp#712](https://github.com/0xShug0/audio.cpp/pull/712) on
   2026-09-27 (`77491a33`). `Docs/MODEL_ENGINE_SETUP.md`'s pin bumped to that
   commit, the local
   `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch`
   and its `git apply` step dropped; `Patches/audio.cpp/README.md` keeps
   `repro_r2t2_finish.c` as a standalone regression check. **Verified**
   (2026-09-28): rebuilt `third_party/audio.cpp` from a clean checkout at the
   new pin (no local patch applied), `Patches/audio.cpp/repro_r2t2_finish.c`
   prints `SURVIVED`/exit 0 against the real `r2t2-q8_0.gguf` weights (same
   deterministic repro that used to SIGSEGV), and `swift build --configuration
   release` + `swift test` (70 tests) + a packaged `build_app.sh` app
   launching and quitting cleanly all pass. **Mic-driven UI smoke test done**
   (2026-09-28): downloaded the real R2T2 weights
   (`models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf`), rebuilt/repackaged the app
   against the pinned post-fix `third_party/audio.cpp` checkout, selected
   `model.r2t2` in Settings, recorded live mic audio, and stopped — no
   crash. This item is now fully closed.
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
7. ~~**HY-MT1.5 mic smoke test**~~ — **done** (2026-09-28): downloaded the
   real `models/HY-MT1.5-GGUF/HY-MT1.5-1.8B-Q4_K_M.gguf` weights, selected
   `model.hymt15` in Settings, recorded live mic audio, stopped — a
   one-shot translation landed per segment as expected (no live preview, no
   crash, no hang). This item is now closed.

### Known gaps / things to double check when touching nearby code

- **T3PO/HY-MT1.5 silently mistranslate into Chinese for most of
  `LanguageCatalog`'s 16 target languages** — `ModelLanguageMapping`'s
  `t3poTargetLanguage(forCode:)`/`hyMT15TargetLanguage(forCode:)` only
  recognize `zh`/`en`/`ja`/`ko`; `TargetLanguagePicker` doesn't filter by
  engine the way `SourceLanguagePicker` already does for
  `supportsSystemASRSource`, so picking e.g. French while a local model
  engine is selected produces Chinese output with no error or warning.
  `SystemTranslationProvider` doesn't have this gap (`Translation` covers
  the whole catalog). HY-MT1.5's own model card documents official support
  for several of the missing languages (French/German/Spanish/...), so
  extending `HYMT15TargetLanguage` is likely the easier half of a real fix;
  gating the picker per engine (mirroring `supportsSystemASRSource`) would
  close the rest. Not fixed yet — caught in PR #27's third review round,
  scoped as a follow-up rather than pulled into that PR.
- **R2T2 (`model.r2t2`) used to SIGSEGV the whole process on audio.cpp before
  our pinned commit — root-caused, fixed upstream, and now pinned past the
  fix (no local patch needed anymore, see Open Items #1).**
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
  easiest way to reach `chunk_id_ >= 2` with an empty tail. Fixed upstream in
  [audio.cpp#712](https://github.com/0xShug0/audio.cpp/pull/712) (merged
  2026-09-27, `77491a33`) by bailing out early when `ids` is empty.
  `Docs/MODEL_ENGINE_SETUP.md`'s pin now points past that merge, so no local
  patch is needed anymore — re-verified against a freshly rebuilt checkout at
  the new pin, see Open Items #1.
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
- **HY-MT1.5 has no WAIT/TRANS control signal** — unlike T3PO (see
  `InProcessTranslator`'s class doc for that trick), Tencent's model card
  documents only a single "translate the following complete segment"
  instruction turn, with no trained behavior for "not enough context yet,
  say nothing." `HYMT15Translator` is built around that: no incremental
  probing, no preview, translation only happens once per `flush()`. If a
  future model in this same "one-shot" family *does* need mid-utterance
  probing, this class isn't the place to add it — a third
  `LocalTranslationStrategy`-shaped abstraction would be worth revisiting at
  that point instead of bolting more special cases onto either existing
  class.
- **`model.hymt15` is the first `.model`-kind engine with more than one
  catalog variant** — activates a previously-hypothetical edge case
  `RecordingSession.hasDownloadedModelVariant(engineID:)`'s doc already
  flagged: deleting the *currently-selected* variant via Model Management
  while a *different* variant of the same engine stays downloaded leaves
  the stale selection pointing at the deleted one (still handled gracefully
  via the existing "尚未下载" `statusMessage`/Settings "（未下载）" label,
  just not auto-switched to the still-downloaded sibling variant). Fine to
  leave as-is per that doc's own reasoning; would need
  `validateAndNormalizeModelVariantSelections()` to gain a "fall back to
  another downloaded variant of the same engine" case if this friction ever
  actually bothers a user.
- No handling yet for what happens if `SessionStore.init()` throws (disk
  full, schema mismatch after a future migration) beyond "history window has
  no data" — `RecordingSession` itself keeps working with `sessionStore ==
  nil` (in-memory only, nothing persisted).
