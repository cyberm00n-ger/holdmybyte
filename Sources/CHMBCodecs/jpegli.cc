// WP0 stub; WP1 owns this file. The jpegli headers are included so the vendor-include layout is compile-checked.
#include "hmb_codecs.h"
#include "stub_error.h"

#include "lib/jpegli/encode.h"

int hmb_jpegli_encode(const uint8_t *, uint32_t, uint32_t, size_t, float, int, int,
                      const hmb_marker *, size_t, hmb_buffer *out, char *err, size_t err_len) {
    if (out != nullptr) { out->data = nullptr; out->size = 0; }
    return hmb_stub_error("hmb_jpegli_encode", err, err_len);
}
