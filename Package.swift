// swift-tools-version: 6.2
import Foundation
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
// ported from `../mac-poc-hybrid`) link `CAudioCpp`/`CLlamaCpp` C target
// shims against gitignored `third_party/audio.cpp`/`third_party/llama.cpp`
// checkouts, built out-of-band — see `Docs/MODEL_ENGINE_SETUP.md` for the
// exact clone/cmake recipe. Same limitation `mac-poc-hybrid/Package.swift`
// documents: building this package at all (even to only ever run the
// `.system` engines at runtime) requires those checkouts to exist, since
// SwiftPM has no notion of an optional/runtime-only native dependency.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let audioCppRoot = packageDir.appendingPathComponent("third_party/audio.cpp")
let audioCppInclude = audioCppRoot.appendingPathComponent("include").path
let audioCppLibDir = audioCppRoot.appendingPathComponent("build/macos-capi-metal-release/bin").path
let llamaCppRoot = packageDir.appendingPathComponent("third_party/llama.cpp")
let llamaCppInclude = llamaCppRoot.appendingPathComponent("include").path
// llama.h includes ggml.h, which lives in a separate include tree (ggml is a
// vendored sub-project within the llama.cpp checkout, not under include/).
let ggmlInclude = llamaCppRoot.appendingPathComponent("ggml/include").path
let llamaCppLibDir = llamaCppRoot.appendingPathComponent("build/bin").path
let llamaCppIncludeFlags = ["-I", llamaCppInclude, "-I", ggmlInclude]
let llamaCppSwiftIncludeFlags = ["-Xcc", "-I", "-Xcc", llamaCppInclude, "-Xcc", "-I", "-Xcc", ggmlInclude]

// sherpa-onnx ships prebuilt macOS shared libs (headers + dylibs) — unpacked
// by `Scripts/setup_third_party.sh --sherpa` into `third_party/sherpa-onnx`.
let sherpaRoot = packageDir.appendingPathComponent("third_party/sherpa-onnx")
let sherpaInclude = sherpaRoot.appendingPathComponent("include").path
let sherpaLibDir = sherpaRoot.appendingPathComponent("lib").path

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
            name: "CAudioCpp",
            cSettings: [
                .unsafeFlags(["-I", audioCppInclude])
            ]
        ),
        .target(
            name: "CSherpaOnnx",
            cSettings: [
                .unsafeFlags(["-I", sherpaInclude])
            ]
        ),
        .target(
            name: "CLlamaCpp",
            cSettings: [
                .unsafeFlags(llamaCppIncludeFlags)
            ]
        ),
        .target(
            name: "OmniVoiceCore",
            dependencies: ["CAudioCpp", "CLlamaCpp", "CSherpaOnnx"],
            path: "Sources/OmniVoiceCore",
            cSettings: [
                .unsafeFlags(["-I", audioCppInclude, "-I", sherpaInclude] + llamaCppIncludeFlags)
            ],
            swiftSettings: [
                // swift-tools-version 6.2 (needed for `.macOS(.v26)`) defaults
                // to Swift 6's strict concurrency checking. AVFoundation/
                // ScreenCaptureKit/Speech's delegate- and closure-based APIs
                // (ported from `mac-poc-hybrid`, itself on tools-version 5.10)
                // predate that and rely on manual serial-queue thread-safety
                // instead — same reasoning `mac-poc-hybrid/Package.swift`
                // documents for its own executable target.
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I", "-Xcc", audioCppInclude, "-Xcc", "-I", "-Xcc", sherpaInclude] + llamaCppSwiftIncludeFlags)
            ],
            linkerSettings: [
                .linkedLibrary("audiocpp"),
                .linkedLibrary("llama"),
                .linkedLibrary("sherpa-onnx-c-api"),
                .unsafeFlags([
                    "-L", sherpaLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", sherpaLibDir,
                    "-L", audioCppLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", audioCppLibDir,
                    "-L", llamaCppLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", llamaCppLibDir,
                ])
            ]
        ),
        .executableTarget(
            name: "OmniVoice",
            dependencies: ["OmniVoiceCore"],
            path: "Sources/OmniVoice",
            // `cSettings`/`swiftSettings` unsafeFlags on `OmniVoiceCore`/
            // `CAudioCpp`/`CLlamaCpp` don't propagate transitively to a
            // dependent target's own explicit module build — every target
            // that (transitively) depends on the C shim targets needs these
            // same `-I` flags repeated, not just the one that first declares
            // them.
            cSettings: [
                .unsafeFlags(["-I", audioCppInclude, "-I", sherpaInclude] + llamaCppIncludeFlags)
            ],
            swiftSettings: [
                // Same reasoning as `OmniVoiceCore` above — `Translation`'s
                // `.translationTask` bridge (see `FloatingTranscriptView`)
                // isn't annotated for Swift 6 strict concurrency either.
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I", "-Xcc", audioCppInclude, "-Xcc", "-I", "-Xcc", sherpaInclude] + llamaCppSwiftIncludeFlags)
            ]
        ),
        .testTarget(
            name: "OmniVoiceCoreTests",
            dependencies: ["OmniVoiceCore"],
            path: "Tests/OmniVoiceCoreTests",
            cSettings: [
                .unsafeFlags(["-I", audioCppInclude, "-I", sherpaInclude] + llamaCppIncludeFlags)
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I", "-Xcc", audioCppInclude, "-Xcc", "-I", "-Xcc", sherpaInclude] + llamaCppSwiftIncludeFlags)
            ]
        )
    ]
)
