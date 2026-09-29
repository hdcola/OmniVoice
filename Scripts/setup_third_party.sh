#!/usr/bin/env bash
set -euo pipefail

# Automates the one-time third_party/{audio.cpp,llama.cpp} clone+cmake setup
# documented by hand in Docs/MODEL_ENGINE_SETUP.md — see that file for the
# "why" (pinned commits, why each cmake flag is set).
# This script is the executable form of the same steps; keep both in sync
# if either changes.
#
# Usage:
#   Scripts/setup_third_party.sh [--skip-audio] [--skip-llama] [--with-models] [--force]
#
#   --skip-audio    don't clone/build third_party/audio.cpp
#   --skip-llama    don't clone/build third_party/llama.cpp
#   --with-models   also download the R2T2/T3PO GGUF weights (~12GB total)
#   --force         rebuild even if the target already looks built (does
#                   NOT re-clone or discard an existing checkout's local
#                   changes — only re-runs cmake --build)

AUDIOCPP_COMMIT="77491a33c589c53ff18add050095cf35647c8213"   # pinned — carries
  # the R2T2 streaming-final-flush null-deref fix (0xShug0/audio.cpp#712);
  # no local patch needed as of this pin.
LLAMACPP_COMMIT="a02c7f58c1c335f5375bf81f174b9a58cce939af"   # pinned

SKIP_AUDIO=0
SKIP_LLAMA=0
WITH_MODELS=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --skip-audio) SKIP_AUDIO=1 ;;
    --skip-llama) SKIP_LLAMA=1 ;;
    --with-models) WITH_MODELS=1 ;;
    --force) FORCE=1 ;;
    *)
      echo "error: unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/third_party"
JOBS="$(sysctl -n hw.logicalcpu)"

for cmd in git cmake curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' not found on PATH" >&2; exit 1; }
done

# Clones $2 into $1 (if not already present) and checks out $3, without
# touching an existing checkout's working tree — a pre-existing clone at a
# different commit is left alone (and flagged) rather than force-reset,
# since it may be a checkout the user is intentionally testing against.
clone_and_pin() {
  local dir="$1" url="$2" commit="$3"
  if [ -d "$dir/.git" ]; then
    local current
    current="$(git -C "$dir" rev-parse HEAD)"
    if [ "$current" != "$commit" ]; then
      echo "warning: $dir is checked out at $current, not the pinned $commit — leaving it as-is" >&2
    else
      echo "==> $dir already at pinned commit"
    fi
    return
  fi
  echo "==> cloning $url"
  git clone "$url" "$dir"
  git -C "$dir" checkout "$commit"
}

mkdir -p "$THIRD_PARTY_DIR"

if [ "$SKIP_AUDIO" -eq 0 ]; then
  AUDIOCPP_DIR="$THIRD_PARTY_DIR/audio.cpp"
  AUDIOCPP_BUILD_DIR="$AUDIOCPP_DIR/build/macos-capi-metal-release"
  AUDIOCPP_LIB="$AUDIOCPP_BUILD_DIR/bin/libaudiocpp.dylib"

  clone_and_pin "$AUDIOCPP_DIR" "https://github.com/0xShug0/audio.cpp.git" "$AUDIOCPP_COMMIT"

  if [ "$FORCE" -eq 1 ] || [ ! -f "$AUDIOCPP_LIB" ]; then
    echo "==> configuring audio.cpp ($AUDIOCPP_BUILD_DIR)"
    cmake -S "$AUDIOCPP_DIR" -B "$AUDIOCPP_BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=OFF \
      -DENGINE_ENABLE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
      -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF \
      -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=confucius4_r2t2 \
      -DAUDIOCPP_BUILD_C_API=ON \
      -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF
    echo "==> building audio.cpp (target: audiocpp)"
    cmake --build "$AUDIOCPP_BUILD_DIR" --target audiocpp --parallel "$JOBS"
  else
    echo "==> audio.cpp already built: $AUDIOCPP_LIB (use --force to rebuild)"
  fi
else
  echo "==> --skip-audio: skipping audio.cpp"
fi

if [ "$SKIP_LLAMA" -eq 0 ]; then
  LLAMACPP_DIR="$THIRD_PARTY_DIR/llama.cpp"
  LLAMACPP_BUILD_DIR="$LLAMACPP_DIR/build"
  LLAMACPP_LIB="$LLAMACPP_BUILD_DIR/bin/libllama.dylib"

  clone_and_pin "$LLAMACPP_DIR" "https://github.com/ggml-org/llama.cpp.git" "$LLAMACPP_COMMIT"

  if [ "$FORCE" -eq 1 ] || [ ! -f "$LLAMACPP_LIB" ]; then
    echo "==> configuring llama.cpp ($LLAMACPP_BUILD_DIR)"
    cmake -S "$LLAMACPP_DIR" -B "$LLAMACPP_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
    echo "==> building llama.cpp (target: llama)"
    cmake --build "$LLAMACPP_BUILD_DIR" --target llama --parallel "$JOBS"
  else
    echo "==> llama.cpp already built: $LLAMACPP_LIB (use --force to rebuild)"
  fi
else
  echo "==> --skip-llama: skipping llama.cpp"
fi

if [ "$WITH_MODELS" -eq 1 ]; then
  R2T2_DIR="$ROOT_DIR/models/Confucius4-R2T2-GGUF"
  T3PO_DIR="$ROOT_DIR/models/Confucius4-T3PO-GGUF"
  R2T2_FILE="$R2T2_DIR/r2t2-q8_0.gguf"
  T3PO_FILE="$T3PO_DIR/Confucius4-T3PO-Q5_K_M.gguf"

  mkdir -p "$R2T2_DIR" "$T3PO_DIR"

  if [ -f "$R2T2_FILE" ]; then
    echo "==> R2T2 weights already present: $R2T2_FILE"
  else
    echo "==> downloading R2T2 weights (~2.5GB)"
    curl -L -o "$R2T2_FILE" \
      https://huggingface.co/davidxifeng/Confucius4-R2T2-gguf/resolve/main/r2t2-q8_0.gguf
  fi

  if [ -f "$T3PO_FILE" ]; then
    echo "==> T3PO weights already present: $T3PO_FILE"
  else
    echo "==> downloading T3PO weights (~9GB)"
    curl -L -o "$T3PO_FILE" \
      https://huggingface.co/netease-youdao/Confucius4-T3PO-GGUF/resolve/main/Confucius4-T3PO-Q5_K_M.gguf
  fi
fi

echo "==> done"
echo "Verify with: swift build && swift build --configuration release && swift test"
echo "Then: Scripts/build_app.sh && open build/OmniVoice.app"
