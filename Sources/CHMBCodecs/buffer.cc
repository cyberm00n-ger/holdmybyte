// WP0 stub; WP1 owns this file. hmb_codec_versions is real so the vendored archive is linked and checked.
#include "hmb_codecs.h"

#include <cstdio>
#include <cstdlib>
#include <string>

#include <jxl/encode.h>
#include <webp/encode.h>

void hmb_buffer_free(hmb_buffer *b) {
    if (b == nullptr) return;
    std::free(b->data);
    b->data = nullptr;
    b->size = 0;
}

const char *hmb_codec_versions(void) {
    static const std::string versions = [] {
        const uint32_t jxl = JxlEncoderVersion();                 // major * 1000000 + minor * 1000 + patch
        const int webp = WebPGetEncoderVersion();                  // (major << 16) | (minor << 8) | revision
        char jxlText[32];
        std::snprintf(jxlText, sizeof jxlText, "%u.%u.%u", jxl / 1000000, (jxl / 1000) % 1000, jxl % 1000);
        char webpText[32];
        std::snprintf(webpText, sizeof webpText, "%d.%d.%d", (webp >> 16) & 0xff, (webp >> 8) & 0xff, webp & 0xff);
        return std::string("libjxl ") + jxlText + " · jpegli (libjxl " + jxlText + ") · libwebp " + webpText;
    }();
    return versions.c_str();
}
