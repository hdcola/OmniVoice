# OmniVoice UI tests

SwiftPM has no notion of a "UI Testing Bundle" target — only
library/executable/plain-XCTest targets — so driving the real app with
`XCUIApplication` needs an Xcode project on top of this package. This
directory is that project, generated from `project.yml` via
[xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

It defines exactly **one** target: an *unhosted* UI Testing Bundle with no
"Target Application" of its own. Each test instead launches the real,
already-built `OmniVoice.app` bundle via `XCUIApplication(url:)` (a
macOS/Catalyst-only initializer meant exactly for testing an app that isn't
one of the project's own targets). This is deliberately the least invasive
option: `swift build`/`swift test` for the SPM package (and the existing
`OmniVoiceCoreTests` target) are completely untouched by anything in this
directory — it only ever *reads* the package's build output, it never
becomes a dependency of the package itself, so it never has to fight
`Package.swift`'s `unsafeFlags` (Xcode rejects unsafe flags on any package
dependency that isn't the directly-opened root package — exactly what
embedding this package as a normal Xcode package dependency would hit).

## Running the tests

```sh
# 1. Build the app bundle these tests launch (reuses the repo's own
#    Scripts/build_app.sh — the same relocatable, ad-hoc-signed
#    build/OmniVoice.app a real release build produces).
../Scripts/build_app.sh

# 1b. Re-sign it with the get-task-allow entitlement (Xcode adds this
#     automatically to every Debug build it signs itself; build_app.sh
#     doesn't, since it's meant to also produce real release-style builds —
#     see uitest-entitlements.plist's doc). Needed for XCUITest's automation
#     bridge to attach reliably.
codesign --force --deep --sign - --entitlements uitest-entitlements.plist ../build/OmniVoice.app

# 2. (First time only, or after editing project.yml) regenerate the project.
xcodegen generate

# 3. Run the tests.
xcodebuild -project OmniVoiceUITests.xcodeproj -scheme OmniVoiceUITests \
  -destination 'platform=macOS' test
```

Or open `OmniVoiceUITests.xcodeproj` in Xcode and run the `OmniVoiceUITests`
scheme's tests from there (⌘U) — steps 1–2 still need to have been run first.

### macOS Accessibility permission

The very first run on a machine will fail with **"Timed out while enabling
automation mode"** unless the process driving `xcodebuild`/Xcode has
Accessibility permission — this is a one-time, per-machine grant in **System
Settings → Privacy & Security → Accessibility**, adding whatever app/terminal
actually invokes the build (Xcode, Terminal, or an IDE like Orca if tests are
run from inside one). No amount of retrying or reconfiguring the project
works around this; it must be granted once, interactively, by a human.

### Known issue: intermittent hang on some hosts even with permission granted

On at least one shared/multi-user dev host, `testmanagerd`'s automation-mode
handshake with this app (`LSUIElement`/`.accessory` — menu-bar-only, no Dock
icon) sometimes never completes, even after Accessibility permission is
granted and even at a 90s wait — while the same app launched via plain `open`
always shows its onboarding window within 2-4s. The automation accessibility
connection itself stays alive and responsive throughout (confirmed via
`log show --predicate 'process contains "testmanagerd"'`), so this reads as
an app/XCUITest launch-path incompatibility specific to `.accessory`-policy
apps, not a resource/timeout issue — see `OmniVoiceUITestApp.launchFreshOnboarding(_:)`'s
doc for the full investigation (entitlements and forced `.regular` activation
policy were both tried and didn't fix it). If this whole suite times out on a
given machine, try a different one before assuming a regression.

## What each test file covers

- `SmokeTests.swift` — Phase A infra check: the app launches and its
  onboarding window is visible. Nothing behavioral.
- `OnboardingFinishFlowTests.swift` — item 1: the "跳过向导"/`.lightweight`
  happy paths for `OnboardingView.finish(startDownload:)` closing the window
  promptly. The disk-space-insufficient regression path itself (Round 1/2
  must-fix) is **not** exercised here — see that file's doc for why.
- `FloatingPanelAutoScrollTests.swift` — item 2: **only the empty-transcript
  baseline** (pinned by default, no jump button) — it does not exercise
  auto-scroll, scroll-away detection, or the jump button, the actual state
  machine this item was scoped to cover. Live transcript content needs a real
  ASR session (mic TCC permission), out of reach for a black-box UI test;
  real coverage would need either a test-injection seam for synthetic
  transcript lines, or a unit-level test in `OmniVoiceCoreTests` that drives
  `TranscriptListView`'s `@State` directly — see that file's doc.
- `SettingsDisabledStateTests.swift` — item 3: the idle-state baseline and
  the `isModelLoaded == false` half of the memory console's disabled matrix.
  The rest of the matrix needs microphone permission or a downloaded model —
  see that file's doc.
- `FloatingPanelControlBarAutoHideTests.swift` — item 4: fully covered. The
  2s auto-hide delay, re-show on hover, and drag-vs-control-click hit testing
  need neither permissions nor downloads.
- `CrossSurfaceModelStateSyncTests.swift` — item 5: Settings' memory console
  and the floating panel's status control appear and disappear together when
  an on-device engine is selected/falls back, without needing a real
  download.

See the top-level task report (or `CHANGELOG.md`'s `### Tests` entry) for the
full reasoning on what's scoped down and why.
