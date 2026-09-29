# OmniVoice

All-in-one real-time speech transcription &amp; translation assistant for
lectures, meetings, and multilingual conversations — a macOS menu-bar app
with a floating live-transcript panel.

**Current version: 0.3.0 — internal test build.**

### [⬇ Download OmniVoice 0.3.0 (.dmg)](https://github.com/hdcola/OmniVoice/releases/download/v0.3.0/OmniVoice-0.3.0.dmg)

Or install via [Homebrew](https://brew.sh):

```bash
brew tap hdcola/tap
brew trust hdcola/tap
brew install --cask omnivoice
```

`brew trust` (Homebrew 7+ only — older versions load third-party taps
without it) tells Homebrew this tap is fine to load; skip it and
`brew install` stops with "Refusing to load cask ... from untrusted tap".

This build is **ad-hoc signed only, not notarized** — macOS will refuse to
open it straight out of the DMG until you clear its quarantine flag. See
[`Docs/RELEASE_TESTING.md`](Docs/RELEASE_TESTING.md) for the one-line fix,
required permissions, and current feature scope, and
[`Docs/PROGRESS.md`](Docs/PROGRESS.md) for the full architecture/decision
history and open items.

## What it does today

- **Live transcription + translation**, either on macOS's built-in
  frameworks (`SpeechAnalyzer`/`SpeechTranscriber` for ASR, `Translation` for
  translation — no cloud API calls) or fully local/offline models (R2T2 for
  ASR, T3PO for translation, run in-process via `audio.cpp`/`llama.cpp`),
  picked independently per component. **R2T2 needs a one-line upstream patch
  applied to `audio.cpp` before it's safe to use — see
  `Docs/MODEL_ENGINE_SETUP.md`.**
- **Floating transcript panel**: shown from launch, semi-transparent,
  draggable/resizable, stays on top without stealing focus. Its own control
  bar has start/stop, a source/target language picker, and a close button;
  a status bar surfaces what's going on (or what went wrong).
- **Menu bar**: start/stop (works even if the panel is hidden), a
  show/hide toggle for the panel, microphone picker, "include system audio"
  toggle (via ScreenCaptureKit — needs Screen Recording permission), links
  to history and settings.
- **~16 quick-pick languages** (Chinese, English, Japanese, Korean, French,
  German, Spanish, Italian, Portuguese, and more) shared between the panel
  and Settings, plus an engine-aware "自动" (auto-detect source) option once
  a local-model ASR engine is available.
- **Session history**: past recordings persisted locally (SwiftData), with
  a searchable history window and Markdown export.
- **Settings persistence**: engine choice, language pair, mic device, and
  system-audio inclusion survive quits/relaunches/restarts.

## Known issues

- **R2T2 (识别引擎: "R2T2 模型") requires an upstream `audio.cpp` patch.**
  Unpatched, it can SIGSEGV the whole app when a recording is stopped or a
  VAD pause rotates the stream — a null-pointer dereference in `audio.cpp`'s
  own `R2T2ASRSession::build_stream_prefix()`, not in this app's code. The
  one-line fix ships here as
  `Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch`
  and is part of the build recipe in `Docs/MODEL_ENGINE_SETUP.md`; see
  `Docs/PROGRESS.md`'s Known gaps section for the root-cause writeup. T3PO
  translation and both system frameworks (`SpeechAnalyzer`/`Translation`)
  were never affected.

## Not yet implemented

- **Model weight download-on-first-use** — R2T2/T3PO are wired up and work,
  but building/running them today requires manually fetching their upstream
  engines + GGUF weights (see `Docs/MODEL_ENGINE_SETUP.md`); a real in-app
  download/cache flow is still open.
- **Localization** — UI strings are Chinese-only.
- **Release pipeline** — this build is ad-hoc signed only, not notarized;
  see `Docs/RELEASE_TESTING.md` for what that means for installing it.
- **Auto-update, crash reporting, privacy copy** — all deferred/stubbed for
  now.

## Requirements

- macOS 26 or later (uses `SpeechAnalyzer`/`SpeechTranscriber` and the
  `Translation` framework's `MenuBarExtra`/`.translationTask` APIs, all
  macOS 26+).
- A Swift 6.2+ toolchain (`swift-tools-version: 6.2` in `Package.swift`) to
  build from source.

## Building from source

```bash
swift build             # debug build
swift test              # unit tests
./Scripts/build_app.sh  # packages an ad-hoc-signed .app into build/
./Scripts/build_dmg.sh  # wraps that .app into an installable .dmg (run build_app.sh first)
```

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
