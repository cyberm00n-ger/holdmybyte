// WP0 stub; WP1 owns this file.
#include "hmb_codecs.h"
#include "stub_error.h"

#include <webp/encode.h>
#include <webp/mux.h>

int hmb_webp_prepare(const uint8_t *, uint32_t, uint32_t, size_t, hmb_webp_prepared **out, char *err, size_t err_len) {
    if (out != nullptr) *out = nullptr;
    return hmb_stub_error("hmb_webp_prepare", err, err_len);
}

int hmb_webp_encode(const hmb_webp_prepared *, float, int, hmb_bytes, hmb_bytes, hmb_bytes,
                    hmb_buffer *out, char *err, size_t err_len) {
    if (out != nullptr) { out->data = nullptr; out->size = 0; }
    return hmb_stub_error("hmb_webp_encode", err, err_len);
}

void hmb_webp_release(hmb_webp_prepared *) {}
