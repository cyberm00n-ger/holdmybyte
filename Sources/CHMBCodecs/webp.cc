// holdmybyte codec bridge: libwebp 1.6.0 lossy encoder plus libwebpmux metadata chunks. Owned by WP1.
//
// `hmb_webp_prepare` imports RGBX and runs the sharp-YUV conversion once; every `hmb_webp_encode` works on a copy
// of those YUV planes (the encoder may touch its input picture), so probes of one search are independent and the
// expensive conversion is not repeated (old audit #19). Config: WEBP_PRESET_PHOTO, the given quality and method,
// use_sharp_yuv = 1 (already applied), thread_level = 0, i.e. single-threaded and deterministic.
// With ICC, EXIF or XMP the result is an extended (VP8X) file assembled by libwebpmux; without, a simple VP8 file.
#include "hmb_codecs.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <webp/encode.h>
#include <webp/mux.h>

struct hmb_webp_prepared {
    WebPPicture picture;   // YUV420, use_argb = 0
};

namespace {

int fail(char *err, size_t err_len, const char *format, ...) {
    if (err != nullptr && err_len > 0) {
        va_list args;
        va_start(args, format);
        std::vsnprintf(err, err_len, format, args);
        va_end(args);
    }
    return -1;
}

const char *encoding_error(WebPEncodingError code) {
    switch (code) {
        case VP8_ENC_OK: return "ok";
        case VP8_ENC_ERROR_OUT_OF_MEMORY: return "out of memory";
        case VP8_ENC_ERROR_BITSTREAM_OUT_OF_MEMORY: return "out of memory (bitstream)";
        case VP8_ENC_ERROR_NULL_PARAMETER: return "null parameter";
        case VP8_ENC_ERROR_INVALID_CONFIGURATION: return "invalid configuration";
        case VP8_ENC_ERROR_BAD_DIMENSION: return "bad dimension";
        case VP8_ENC_ERROR_PARTITION0_OVERFLOW: return "partition 0 overflow";
        case VP8_ENC_ERROR_PARTITION_OVERFLOW: return "partition overflow";
        case VP8_ENC_ERROR_BAD_WRITE: return "bad write";
        case VP8_ENC_ERROR_FILE_TOO_BIG: return "file too big";
        case VP8_ENC_ERROR_USER_ABORT: return "user abort";
        default: return "unknown error";
    }
}

const char *mux_error(WebPMuxError code) {
    switch (code) {
        case WEBP_MUX_OK: return "ok";
        case WEBP_MUX_NOT_FOUND: return "not found";
        case WEBP_MUX_INVALID_ARGUMENT: return "invalid argument";
        case WEBP_MUX_BAD_DATA: return "bad data";
        case WEBP_MUX_MEMORY_ERROR: return "out of memory";
        case WEBP_MUX_NOT_ENOUGH_DATA: return "not enough data";
        default: return "unknown error";
    }
}

/// Copies `size` bytes into a fresh malloc'ed hmb_buffer.
int copy_out(const uint8_t *data, size_t size, hmb_buffer *out, char *err, size_t err_len) {
    uint8_t *copy = static_cast<uint8_t *>(std::malloc(size > 0 ? size : 1));
    if (copy == nullptr) return fail(err, err_len, "webp: out of memory (%zu bytes)", size);
    if (size > 0) std::memcpy(copy, data, size);
    out->data = copy;
    out->size = size;
    return 0;
}

}  // namespace

int hmb_webp_prepare(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                     hmb_webp_prepared **out, char *err, size_t err_len) {
    if (out == nullptr) return fail(err, err_len, "hmb_webp_prepare: out is NULL");
    *out = nullptr;
    if (rgba == nullptr) return fail(err, err_len, "hmb_webp_prepare: pixels are NULL");
    if (width == 0 || height == 0 || width > WEBP_MAX_DIMENSION || height > WEBP_MAX_DIMENSION)
        return fail(err, err_len, "hmb_webp_prepare: unsupported size %ux%u (WebP allows at most %d)", width, height,
                    WEBP_MAX_DIMENSION);
    if (stride < static_cast<size_t>(width) * 4 || stride > 0x7fffffff)
        return fail(err, err_len, "hmb_webp_prepare: invalid stride %zu", stride);

    WebPPicture argb;
    if (!WebPPictureInit(&argb)) return fail(err, err_len, "hmb_webp_prepare: libwebp version mismatch");
    argb.width = static_cast<int>(width);
    argb.height = static_cast<int>(height);
    argb.use_argb = 1;
    if (!WebPPictureImportRGBX(&argb, rgba, static_cast<int>(stride))) {
        const char *message = encoding_error(argb.error_code);
        WebPPictureFree(&argb);
        return fail(err, err_len, "hmb_webp_prepare: import failed (%s)", message);
    }
    if (!WebPPictureSharpARGBToYUVA(&argb)) {
        const char *message = encoding_error(argb.error_code);
        WebPPictureFree(&argb);
        return fail(err, err_len, "hmb_webp_prepare: sharp YUV conversion failed (%s)", message);
    }

    // Keep only the YUV planes: copy (use_argb is 0 now, so only YUV is copied) and drop the ARGB original.
    hmb_webp_prepared *prepared = static_cast<hmb_webp_prepared *>(std::calloc(1, sizeof(hmb_webp_prepared)));
    if (prepared == nullptr) {
        WebPPictureFree(&argb);
        return fail(err, err_len, "hmb_webp_prepare: out of memory");
    }
    if (!WebPPictureInit(&prepared->picture) || !WebPPictureCopy(&argb, &prepared->picture)) {
        WebPPictureFree(&argb);
        WebPPictureFree(&prepared->picture);
        std::free(prepared);
        return fail(err, err_len, "hmb_webp_prepare: out of memory (YUV copy)");
    }
    WebPPictureFree(&argb);
    *out = prepared;
    return 0;
}

namespace {
int encode_with(const hmb_webp_prepared *p, const WebPConfig &config, hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp,
                hmb_buffer *out, char *err, size_t err_len);
}  // namespace

int hmb_webp_encode(const hmb_webp_prepared *p, float quality, int method,
                    hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp, hmb_buffer *out, char *err, size_t err_len) {
    hmb_webp_tuning tuning = {method, -1, -1, -1, -1, -1, -1, -1, -1};
    return hmb_webp_encode_tuned(p, quality, tuning, icc, exif, xmp, out, err, err_len);
}

int hmb_webp_encode_tuned(const hmb_webp_prepared *p, float quality, hmb_webp_tuning tuning,
                          hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp, hmb_buffer *out, char *err, size_t err_len) {
    if (out == nullptr) return fail(err, err_len, "hmb_webp_encode: out is NULL");
    out->data = nullptr;
    out->size = 0;
    if (p == nullptr) return fail(err, err_len, "hmb_webp_encode: prepared picture is NULL");
    if (!(quality >= 0.0f && quality <= 100.0f))
        return fail(err, err_len, "hmb_webp_encode: quality %g outside 0...100", static_cast<double>(quality));
    if (tuning.method < 0 || tuning.method > 6) return fail(err, err_len, "hmb_webp_encode: method %d outside 0...6", tuning.method);

    WebPConfig config;
    if (!WebPConfigPreset(&config, WEBP_PRESET_PHOTO, quality))
        return fail(err, err_len, "hmb_webp_encode: libwebp version mismatch");
    config.method = tuning.method;
    config.use_sharp_yuv = 1;
    config.thread_level = 0;
    if (tuning.sns_strength >= 0) config.sns_strength = tuning.sns_strength;
    if (tuning.filter_strength >= 0) config.filter_strength = tuning.filter_strength;
    if (tuning.filter_sharpness >= 0) config.filter_sharpness = tuning.filter_sharpness;
    if (tuning.filter_type >= 0) config.filter_type = tuning.filter_type;
    if (tuning.autofilter >= 0) config.autofilter = tuning.autofilter;
    if (tuning.segments >= 0) config.segments = tuning.segments;
    if (tuning.partition_limit >= 0) config.partition_limit = tuning.partition_limit;
    if (tuning.pass >= 0) config.pass = tuning.pass;
    if (!WebPValidateConfig(&config)) return fail(err, err_len, "hmb_webp_encode: invalid configuration");
    return encode_with(p, config, icc, exif, xmp, out, err, err_len);
}

namespace {
int encode_with(const hmb_webp_prepared *p, const WebPConfig &config, hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp,
                hmb_buffer *out, char *err, size_t err_len) {

    WebPPicture picture;
    if (!WebPPictureInit(&picture)) return fail(err, err_len, "hmb_webp_encode: libwebp version mismatch");
    if (!WebPPictureCopy(&p->picture, &picture)) {
        WebPPictureFree(&picture);
        return fail(err, err_len, "hmb_webp_encode: out of memory (picture copy)");
    }
    WebPMemoryWriter writer;
    WebPMemoryWriterInit(&writer);
    picture.writer = WebPMemoryWrite;
    picture.custom_ptr = &writer;
    const int ok = WebPEncode(&config, &picture);
    const WebPEncodingError code = picture.error_code;
    WebPPictureFree(&picture);
    if (!ok) {
        WebPMemoryWriterClear(&writer);
        return fail(err, err_len, "hmb_webp_encode: %s", encoding_error(code));
    }

    const bool has_metadata = icc.size > 0 || exif.size > 0 || xmp.size > 0;
    if (!has_metadata) {
        const int status = copy_out(writer.mem, writer.size, out, err, err_len);
        WebPMemoryWriterClear(&writer);
        return status;
    }

    WebPMux *mux = WebPMuxNew();
    if (mux == nullptr) {
        WebPMemoryWriterClear(&writer);
        return fail(err, err_len, "hmb_webp_encode: out of memory (mux)");
    }
    WebPData image = {writer.mem, writer.size};
    WebPMuxError status = WebPMuxSetImage(mux, &image, 0);
    const char *step = "image";
    if (status == WEBP_MUX_OK && icc.size > 0) {
        WebPData chunk = {icc.data, icc.size};
        status = WebPMuxSetChunk(mux, "ICCP", &chunk, 0);
        step = "ICCP";
    }
    if (status == WEBP_MUX_OK && exif.size > 0) {
        WebPData chunk = {exif.data, exif.size};
        status = WebPMuxSetChunk(mux, "EXIF", &chunk, 0);
        step = "EXIF";
    }
    if (status == WEBP_MUX_OK && xmp.size > 0) {
        WebPData chunk = {xmp.data, xmp.size};
        status = WebPMuxSetChunk(mux, "XMP ", &chunk, 0);
        step = "XMP";
    }
    WebPData assembled;
    WebPDataInit(&assembled);
    if (status == WEBP_MUX_OK) {
        status = WebPMuxAssemble(mux, &assembled);
        step = "assemble";
    }
    WebPMuxDelete(mux);
    int result;
    if (status != WEBP_MUX_OK) {
        result = fail(err, err_len, "hmb_webp_encode: mux %s failed (%s)", step, mux_error(status));
    } else {
        result = copy_out(assembled.bytes, assembled.size, out, err, err_len);
    }
    WebPDataClear(&assembled);
    WebPMemoryWriterClear(&writer);
    return result;
}
}  // namespace

void hmb_webp_release(hmb_webp_prepared *p) {
    if (p == nullptr) return;
    WebPPictureFree(&p->picture);
    std::free(p);
}
