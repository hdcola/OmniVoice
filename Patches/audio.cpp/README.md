# audio.cpp patches

Patches applied on top of the pinned [audio.cpp](https://github.com/0xShug0/audio.cpp)
checkout (`9bdd1d908bbd128e9eb405f5a8e38d0defb84c72`, v0.8.2) before building
`libaudiocpp.dylib`. `third_party/` is gitignored and never vendored into this
repo's history (see `Docs/MODEL_ENGINE_SETUP.md`), so fixes we need there live
here as patch files instead.

Apply them from the `third_party/audio.cpp` checkout root:

```bash
git apply ../../Patches/audio.cpp/0001-r2t2-fix-null-deref-on-empty-final-flush.patch
```

Each patch should be reported upstream; drop it from here (and from
`Docs/MODEL_ENGINE_SETUP.md`) once a release that carries the fix is pinned.

## 0001 — R2T2 null deref on an empty final flush

**Status**: not yet reported upstream.

`R2T2ASRSession::build_stream_prefix(final_flush=true)`
(`src/community_models/confucius4_r2t2/session.cpp`) clamps its rollback end
index to a minimum of 1 — "never roll back past the first token" — and then
builds a `std::vector<int32_t>` from `[ids.begin(), ids.begin() + end_index)`.
When `ids` is empty there is no first token: `begin()` is null, and the range
constructor `memmove`s 4 bytes from address `0`. That is a SIGSEGV in the
*host process*, not an exception the C ABI can turn into an error status — it
takes the whole app down.

`ids` is empty whenever the session's `raw_decoded_` has decoded to `""` by
the time the stream is finished, reachable once `chunk_id_ >=
unfixed_chunk_num` (2 by default — about 640 ms at our 320 ms chunk size). A
forced request language makes it easy to hit: the "no `<asr_text>` tag yet,
nothing to commit" early-out in `decode_stream_chunk()` only applies when
`force_language_` is empty, so `chunk_id_` keeps advancing across chunks that
decode to nothing (silence, a trailing pause). Any partial chunk still in
`buffer_` then sends `finalize()` down the final-flush path.

For us that is `InProcessTranscriber.finishStream()` (Stop) and
`rotateStream()` (a VAD pause), which is why it looked like "crashes after a
longer utterance".

Reproduced deterministically against the unpatched dylib by
`repro_r2t2_finish.c` here: force a language, push four 320 ms chunks of
*silence* plus a 2000-frame partial chunk, call `audiocpp_stream_finish()` →
SIGSEGV with the same frames, the same symbol offsets, and the same
`x1=0x0`/`x2=0x4` registers as the crash reports collected from the app. No
mic and no long utterance needed. Patched, the same run finishes with an
empty transcript, and streaming `assets/resources/sample_16k.wav` through the
same session shape still returns the full transcript in both auto and
forced-language modes.

From the repo root, after `Docs/MODEL_ENGINE_SETUP.md`'s build:

```bash
AUDIOCPP_BIN=third_party/audio.cpp/build/macos-capi-metal-release/bin
clang -O0 -g -Wno-comment -I third_party/audio.cpp/include \
  Patches/audio.cpp/repro_r2t2_finish.c -o /tmp/repro_r2t2_finish \
  -L "$AUDIOCPP_BIN" -laudiocpp -Wl,-rpath,"$PWD/$AUDIOCPP_BIN"
/tmp/repro_r2t2_finish models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf
```

Prints `SURVIVED` on a patched build; exits 139 (SIGSEGV) on an unpatched
one.
