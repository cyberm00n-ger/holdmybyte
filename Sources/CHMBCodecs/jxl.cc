// WP0 stub; WP1 owns this file.
#include "hmb_codecs.h"
#include "stub_error.h"

#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/thread_parallel_runner.h>

int hmb_jxl_transcode_jpeg(const uint8_t *, size_t, int, hmb_buffer *out, char *err, size_t err_len) {
    if (out != nullptr) { out->data = nullptr; out->size = 0; }
    return hmb_stub_error("hmb_jxl_transcode_jpeg", err, err_len);
}

int hmb_jxl_reconstruct_jpeg(const uint8_t *, size_t, hmb_buffer *out, char *err, size_t err_len) {
    if (out != nullptr) { out->data = nullptr; out->size = 0; }
    return hmb_stub_error("hmb_jxl_reconstruct_jpeg", err, err_len);
}
