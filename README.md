# OmniVoice

All-in-one real-time speech transcription &amp; translation assistant for
lectures, meetings, and multilingual conversations — a macOS menu-bar app
with a floating caption panel (字幕悬浮窗) for live transcripts, and on-
device quick translate (快捷翻译): select text in any app (划词翻译, ⌥A) or
frame part of the screen (截图翻译, ⌥S) and translate it in a translation
panel (翻译面板).

**Current version: 0.5.4 — internal test build.**

### [⬇ Download OmniVoice 0.5.4 (.dmg)](https://github.com/hdcola/OmniVoice/releases/download/v0.5.4/OmniVoice-0.5.4.dmg)

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
  picked independently per component (see `Docs/MODEL_ENGINE_SETUP.md` for
  building the model engines).
- **Caption panel (字幕悬浮窗)**: shown from launch (can be turned off in Settings), semi-transparent,
  draggable/resizable, stays on top without stealing focus. Its own control
  bar has start/stop, a source/target language picker, and a close button;
  a status bar surfaces what's going on (or what went wrong).
- **Menu bar**: start/stop (works even if the panel is hidden), a
  show/hide toggle for the caption panel, microphone picker, "include system audio"
  toggle (via ScreenCaptureKit — needs Screen Recording permission), links
  to history and settings.
- **~16 quick-pick languages** (Chinese, English, Japanese, Korean, French,
  German, Spanish, Italian, Portuguese, and more) shared between the caption panel
  and Settings, plus an engine-aware "自动" (auto-detect source) option once
  a local-model ASR engine is available.
- **Quick Translate (快捷翻译): translate selection (划词翻译, ⌥A) and translate screenshot (截图翻译, ⌥S)**, modeled
  on [Cida](https://github.com/Xuanwo/cida) but fully on-device: select text
  in any app and press ⌥A, or press ⌥S and frame part of the screen (text
  recognized locally with Vision). The translation panel (翻译面板) translates it with the
  system Translation framework or HY-MT1.5 — text in "my language" goes to
  your foreign language, everything else comes into "my language". ⏎
  translates, ⇧⏎ inserts a newline, Esc hides. Shortcuts, engine and
  languages live in Settings → 通用. Reading the selection needs the
  Accessibility permission (without it, copy and paste into the translation panel);
  ⌥S needs Screen Recording.
- **History (历史记录)**: past transcripts persisted locally (SwiftData), with
  a searchable history window and Markdown export.
- **Settings persistence**: engine choice, language pair, mic device, and
  system-audio inclusion survive quits/relaunches/restarts.

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
