// swift-tools-version: 6.2
import PackageDescription

// OmniVoice is split into two targets:
//
// - `OmniVoiceCore`: everything UI-agnostic — the Transcription/Translation
//   provider protocols, the audio capture/mixing pipeline, the engine-agnostic
//   recording orchestrator, and SwiftData persistence. This is what a future
//   iOS/companion target (or unit tests) would link against without pulling
//   in AppKit/SwiftUI app-shell code.
// - `OmniVoice`: the menu-bar app shell (SwiftUI + AppKit for the floating
//   panel), depends on `OmniVoiceCore`.
//
// The in-process model engines (R2T2/T3PO via audio.cpp/llama.cpp's C ABI,
// see `../mac-poc-hybrid` for the validated approach) are intentionally not
// wired up yet — see `Sources/OmniVoiceCore/Providers/Model*Provider.swift`.
// Adding them means adding `CAudioCpp`/`CLlamaCpp` C target shims and linker
// flags pointing at gitignored `third_party/` checkouts, exactly as
// `mac-poc-hybrid/Package.swift` does; that's deferred until this skeleton is
// otherwise in place, so building this package doesn't require those
// checkouts to exist.
let package = Package(
    name: "OmniVoice",
    platforms: [
        // Menu bar `MenuBarExtra` scene + `Speech`/`Translation` frameworks
        // (SpeechAnalyzer/SpeechTranscriber, TranslationSession) all need
        // macOS 26+.
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "OmniVoiceCore",
            path: "Sources/OmniVoiceCore",
            swiftSettings: [
                // swift-tools-version 6.2 (needed for `.macOS(.v26)`) defaults
                // to Swift 6's strict concurrency checking. AVFoundation/
                // ScreenCaptureKit/Speech's delegate- and closure-based APIs
                // (ported from `mac-poc-hybrid`, itself on tools-version 5.10)
                // predate that and rely on manual serial-queue thread-safety
                // instead — same reasoning `mac-poc-hybrid/Package.swift`
                // documents for its own executable target.
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "OmniVoice",
            dependencies: ["OmniVoiceCore"],
            path: "Sources/OmniVoice",
            swiftSettings: [
                // Same reasoning as `OmniVoiceCore` above — `Translation`'s
                // `.translationTask` bridge (see `FloatingTranscriptView`)
                // isn't annotated for Swift 6 strict concurrency either.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "OmniVoiceCoreTests",
            dependencies: ["OmniVoiceCore"],
            path: "Tests/OmniVoiceCoreTests"
        )
    ]
)
