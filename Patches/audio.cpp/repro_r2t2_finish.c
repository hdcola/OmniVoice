// Minimal repro for the R2T2 audiocpp_stream_finish SIGSEGV.
//
// Hypothesis: R2T2ASRSession::build_stream_prefix(final_flush=true) does
//   end_index = max<int64_t>(1, ids.size() - unfixed_token_num)
// and then constructs std::vector<int32_t>(ids.begin(), ids.begin()+end_index).
// When ids is empty (raw_decoded_ decoded to "" so far) begin() is nullptr and
// the range ctor memmoves 4 bytes from NULL -> SIGSEGV. Reached only when
// chunk_id_ >= unfixed_chunk_num, which a forced language lets happen even
// while every chunk decodes to empty text (session.cpp:377 guard is skipped).
//
// So: force a language, push N > unfixed_chunk_num chunks of pure silence,
// leave a partial chunk in buffer_, then finish.
//
// usage: repro_r2t2_finish <model.gguf> [backend] [chunks] [tail_frames]

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audiocpp.h"

static void die(const char * what, audiocpp_status st) {
    fprintf(stderr, "FAIL %s: status=%d (%s)\n", what, (int)st, audiocpp_last_error());
    exit(1);
}

int main(int argc, char ** argv) {
    const char * model_path = argc > 1 ? argv[1] : "models/Confucius4-R2T2-GGUF/r2t2-q8_0.gguf";
    const char * backend_name = argc > 2 ? argv[2] : "metal";
    const int chunks = argc > 3 ? atoi(argv[3]) : 4;
    const int tail_frames = argc > 4 ? atoi(argv[4]) : 2000;

    const int sample_rate = 16000;
    const int chunk_size_ms = 320;
    const int chunk_frames = sample_rate * chunk_size_ms / 1000; // 5120

    audiocpp_status st;
    audiocpp_registry * registry = NULL;
    st = audiocpp_registry_create(NULL, &registry);
    if (st != AUDIOCPP_OK) die("registry_create", st);

    audiocpp_model_config mcfg;
    memset(&mcfg, 0, sizeof(mcfg));
    mcfg.family_hint = "confucius4_r2t2";
    audiocpp_model * model = NULL;
    fprintf(stderr, "loading %s ...\n", model_path);
    st = audiocpp_model_load(registry, model_path, &mcfg, NULL, &model);
    if (st != AUDIOCPP_OK) die("model_load", st);

    audiocpp_options * opts = audiocpp_options_create();
    audiocpp_options_set(opts, "confucius4_r2t2.chunk_size_ms", "320");
    audiocpp_options_set(opts, "confucius4_r2t2.unfixed_chunk_num", "2");
    audiocpp_options_set(opts, "confucius4_r2t2.unfixed_token_num", "5");

    audiocpp_backend_config bcfg;
    memset(&bcfg, 0, sizeof(bcfg));
    bcfg.backend = backend_name;
    bcfg.device = 0;
    bcfg.threads = 4;

    audiocpp_session * session = NULL;
    st = audiocpp_session_create(model, "asr", "streaming", &bcfg, opts, &session);
    if (st != AUDIOCPP_OK) die("session_create", st);
    audiocpp_options_free(opts);

    audiocpp_request * request = audiocpp_request_create();
    st = audiocpp_request_set_text_language(request, "Chinese");
    if (st != AUDIOCPP_OK) die("set_text_language", st);
    st = audiocpp_stream_start(session, request);
    if (st != AUDIOCPP_OK) die("stream_start", st);
    audiocpp_request_free(request);

    float * silence = (float *)calloc((size_t)chunk_frames, sizeof(float));
    int64_t offset = 0;
    for (int i = 0; i < chunks; ++i) {
        audiocpp_event * event = NULL;
        st = audiocpp_stream_push(session, silence, (size_t)chunk_frames, sample_rate, 1, offset, &event);
        if (st != AUDIOCPP_OK) die("stream_push", st);
        if (event) audiocpp_event_free(event);
        offset += chunk_frames;
        fprintf(stderr, "pushed chunk %d/%d\n", i + 1, chunks);
    }

    // Partial chunk: stays in buffer_, so finalize() takes the final-flush path.
    if (tail_frames > 0) {
        audiocpp_event * event = NULL;
        st = audiocpp_stream_push(session, silence, (size_t)tail_frames, sample_rate, 1, offset, &event);
        if (st != AUDIOCPP_OK) die("stream_push tail", st);
        if (event) audiocpp_event_free(event);
        fprintf(stderr, "pushed partial tail of %d frames\n", tail_frames);
    }

    fprintf(stderr, "calling audiocpp_stream_finish ...\n");
    audiocpp_result * result = NULL;
    st = audiocpp_stream_finish(session, &result);
    fprintf(stderr, "stream_finish returned status=%d\n", (int)st);
    if (st == AUDIOCPP_OK && result) {
        const char * text = NULL;
        const char * language = NULL;
        if (audiocpp_result_text(result, &text, &language) == AUDIOCPP_OK) {
            fprintf(stderr, "text=\"%s\" language=\"%s\"\n", text ? text : "", language ? language : "");
        }
        audiocpp_result_free(result);
    }

    free(silence);
    audiocpp_session_free(session);
    audiocpp_model_free(model);
    audiocpp_registry_free(registry);
    fprintf(stderr, "SURVIVED\n");
    return 0;
}
