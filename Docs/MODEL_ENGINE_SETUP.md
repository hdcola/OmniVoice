# Model engine setup (R2T2 / T3PO)

The `.model`-kind engines (`model.r2t2` for transcription, `model.t3po` for
translation — see `ProviderCatalog`) run in-process via
[audio.cpp](https://github.com/0xShug0/audio.cpp)'s and
[llama.cpp](https://github.com/ggml-org/llama.cpp)'s C ABIs. Both are full
upstream clones plus multi-GB GGUF weights, gitignored (`third_party/`,
`models/`) and **never** vendored into this repo's history — building
`OmniVoice`/`OmniVoiceCore` at all (even to only ever run the `.system`
engines at runtime) requires these to exist locally, since SwiftPM has no
notion of an optional/runtime-only native dependency (`Package.swift`
documents this same trade-off).

This is a one-time, per-checkout setup step — nothing here is downloaded or
built automatically.

## 1. audio.cpp (R2T2 ASR)

```bash
mkdir -p third_party && cd third_party
git clone https://github.com/0xShug0/audio.cpp.git
cd audio.cpp
git checkout 9bdd1d908bbd128e9eb405f5a8e38d0defb84c72   # v0.8.2, pinned

# Required: fixes a null-pointer deref in R2T2's streaming final flush that
# SIGSEGVs the whole host process from audiocpp_stream_finish(). See
# Patches/audio.cpp/README.md.
git apply ../../Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch

cmake -S . -B build/macos-capi-metal-release \
  -DCMAKE_BUILD_TYPE=Release \
  -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=OFF \
  -DENGINE_ENABLE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF \
  -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=confucius4_r2t2 \
  -DAUDIOCPP_BUILD_C_API=ON \
  -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF
cmake --build build/macos-capi-metal-release --target audiocpp \
  --parallel "$(sysctl -n hw.logicalcpu)"
```

Produces `third_party/audio.cpp/build/macos-capi-metal-release/bin/libaudiocpp.dylib`
— `Package.swift` links against it via `#filePath`-derived paths, so it must
land at exactly this location relative to the repo root.

## 2. llama.cpp (T3PO translation)

```bash
cd third_party
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git checkout a02c7f58c1c335f5375bf81f174b9a58cce939af   # pinned

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build build --target llama --parallel "$(sysctl -n hw.logicalcpu)"
```

Produces `third_party/llama.cpp/build/bin/libllama.dylib` (+ its `libggml-*`
dependencies in the same directory).

## 3. Model weights

```bash
mkdir -p models/Confucius4-R2T2-GGUF models/Confucius4-T3PO-GGUF

curl -L -o models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf \
  https://huggingface.co/davidxifeng/Confucius4-R2T2-gguf/resolve/main/r2t2-q8_0.gguf

curl -L -o models/Confucius4-T3PO-GGUF/Confucius4-T3PO-Q5_K_M.gguf \
  https://huggingface.co/netease-youdao/Confucius4-T3PO-GGUF/resolve/main/Confucius4-T3PO-Q5_K_M.gguf
```

~2.5GB (R2T2) + ~9GB (T3PO). `InProcessTranscriber`/`InProcessTranslator`
look for these exact paths by default; override with the `R2T2_MODEL_PATH`/
`R2T2_T3PO_MODEL_PATH` env vars if you keep weights elsewhere.

A real "download on first use" flow (fetching into a per-user cache instead
of this repo-relative `models/` convention) is a separate follow-up — see
`Docs/PROGRESS.md`.

## Verifying the setup

```bash
swift build
swift build --configuration release
swift test
```

Then, to actually exercise an engine end-to-end: `./Scripts/build_app.sh &&
open build/OmniVoice.app`, switch 识别引擎/翻译引擎 to "R2T2 模型"/"T3PO 模型"
in Settings, and start a recording.
