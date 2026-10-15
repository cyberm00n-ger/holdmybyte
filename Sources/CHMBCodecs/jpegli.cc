// holdmybyte codec bridge: in-process jpegli encoder (libjxl v0.11.2, native jpegli_* API). Owned by WP1.
//
// Settings mirror `cjpegli -d D --chroma_subsampling=420|444 -p 2` (lib/extras/enc/jpegli.cc): jpegli defaults,
// adaptive quantisation on, optimised Huffman coding, the given progressive level. Differences, on purpose:
// - input is RGBX (4 bytes per pixel, the X byte ignored) instead of packed RGB;
// - no JFIF APP0 and no Adobe APP14 are written: the output is SOI, then exactly the caller's markers in the
//   given order, then the jpegli tables and scans. The caller owns every APPn/COM segment (§3.7).
// Errors: jpegli reports through `error_exit`, which we route to a longjmp back into this function, so a
// failure is a message in `err`, never an exit() or abort(). Nothing between setjmp and longjmp owns C++ state.
#include "hmb_codecs.h"

#include <csetjmp>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "lib/jpegli/encode.h"

namespace {

struct HMBJpegError {
    jpeg_error_mgr manager;      // first member: jpegli hands us a pointer to it
    jmp_buf env;
    char message[JMSG_LENGTH_MAX];
};

void hmb_jpegli_error_exit(j_common_ptr cinfo) {
    HMBJpegError *error = reinterpret_cast<HMBJpegError *>(cinfo->err);
    (*cinfo->err->format_message)(cinfo, error->message);
    std::longjmp(error->env, 1);
}

void hmb_jpegli_output_message(j_common_ptr) {}   // warnings stay silent (no stderr noise in the app)

int fail(char *err, size_t err_len, const char *format, ...) {
    if (err != nullptr && err_len > 0) {
        va_list args;
        va_start(args, format);
        std::vsnprintf(err, err_len, format, args);
        va_end(args);
    }
    return -1;
}

}  // namespace

int hmb_jpegli_encode(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                      float distance, int subsampling_444, int progressive_level,
                      const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len) {
    if (out == nullptr) return fail(err, err_len, "hmb_jpegli_encode: out is NULL");
    out->data = nullptr;
    out->size = 0;
    if (rgba == nullptr) return fail(err, err_len, "hmb_jpegli_encode: pixels are NULL");
    if (width == 0 || height == 0 || width > 65500 || height > 65500)
        return fail(err, err_len, "hmb_jpegli_encode: unsupported size %ux%u", width, height);
    if (stride < static_cast<size_t>(width) * 4) return fail(err, err_len, "hmb_jpegli_encode: stride too small");
    if (!(distance >= 0.0f && distance <= 25.0f))
        return fail(err, err_len, "hmb_jpegli_encode: distance %g outside 0...25", static_cast<double>(distance));
    if (progressive_level < 0 || progressive_level > 2)
        return fail(err, err_len, "hmb_jpegli_encode: progressive level %d outside 0...2", progressive_level);
    for (size_t i = 0; i < marker_count; ++i) {
        const hmb_marker &m = markers[i];
        const bool app = m.code >= 0xE0 && m.code <= 0xEF;
        if (!app && m.code != 0xFE) return fail(err, err_len, "hmb_jpegli_encode: marker 0x%02X is not APPn/COM", m.code);
        if (m.payload.size > 65533) return fail(err, err_len, "hmb_jpegli_encode: marker %zu payload too large (%zu)", i, m.payload.size);
        if (m.payload.size > 0 && m.payload.data == nullptr) return fail(err, err_len, "hmb_jpegli_encode: marker %zu has no data", i);
    }

    // Everything the error path must release lives in plain (volatile) locals: longjmp skips destructors.
    jpeg_compress_struct cinfo;
    HMBJpegError error;
    // jpegli's memory destination mallocs the output and keeps `*outbuffer` pointing at the current buffer while
    // it grows; it never frees it, so the error path does. Kept in a struct whose address escapes (in memory).
    struct { unsigned char *data; unsigned long size; } output = {nullptr, 0};  // NOLINT(runtime/int)
    JSAMPROW *volatile rows = nullptr;
    volatile bool created = false;

    std::memset(&cinfo, 0, sizeof cinfo);
    cinfo.err = jpegli_std_error(&error.manager);
    error.manager.error_exit = hmb_jpegli_error_exit;
    error.manager.output_message = hmb_jpegli_output_message;
    error.message[0] = '\0';

    if (setjmp(error.env)) {
        if (created) jpegli_destroy_compress(&cinfo);
        std::free(output.data);
        std::free(rows);
        return fail(err, err_len, "jpegli: %s", error.message[0] ? error.message : "unknown error");
    }

    jpegli_create_compress(&cinfo);
    created = true;
    jpegli_mem_dest(&cinfo, &output.data, &output.size);
    cinfo.image_width = width;
    cinfo.image_height = height;
    cinfo.input_components = 4;
    cinfo.in_color_space = JCS_EXT_RGBX;
    jpegli_set_defaults(&cinfo);
    const int h = subsampling_444 ? 1 : 2;
    cinfo.comp_info[0].h_samp_factor = h;
    cinfo.comp_info[0].v_samp_factor = h;
    for (int i = 1; i < cinfo.num_components; ++i) {
        cinfo.comp_info[i].h_samp_factor = 1;
        cinfo.comp_info[i].v_samp_factor = 1;
    }
    jpegli_enable_adaptive_quantization(&cinfo, TRUE);
    jpegli_set_distance(&cinfo, distance, TRUE);
    jpegli_set_progressive_level(&cinfo, progressive_level);
    cinfo.optimize_coding = TRUE;
    cinfo.write_JFIF_header = FALSE;
    cinfo.write_Adobe_marker = FALSE;
    jpegli_set_input_format(&cinfo, JPEGLI_TYPE_UINT8, JPEGLI_NATIVE_ENDIAN);

    rows = static_cast<JSAMPROW *>(std::malloc(sizeof(JSAMPROW) * height));
    if (rows == nullptr) {
        std::snprintf(error.message, sizeof error.message, "out of memory (row table)");
        std::longjmp(error.env, 1);
    }
    for (uint32_t y = 0; y < height; ++y) rows[y] = const_cast<JSAMPROW>(rgba + static_cast<size_t>(y) * stride);

    jpegli_start_compress(&cinfo, TRUE);
    for (size_t i = 0; i < marker_count; ++i) {
        jpegli_write_marker(&cinfo, markers[i].code, markers[i].payload.data,
                            static_cast<unsigned int>(markers[i].payload.size));
    }
    while (cinfo.next_scanline < cinfo.image_height) {
        const JDIMENSION written = jpegli_write_scanlines(&cinfo, rows + cinfo.next_scanline,
                                                         cinfo.image_height - cinfo.next_scanline);
        if (written == 0) {
            std::snprintf(error.message, sizeof error.message, "jpegli_write_scanlines made no progress");
            std::longjmp(error.env, 1);
        }
    }
    jpegli_finish_compress(&cinfo);
    jpegli_destroy_compress(&cinfo);
    created = false;
    std::free(rows);
    rows = nullptr;

    if (output.data == nullptr || output.size == 0) {
        std::free(output.data);
        return fail(err, err_len, "jpegli produced no output");
    }
    out->data = output.data;      // malloc'ed by jpegli's memory destination; released by hmb_buffer_free
    out->size = output.size;
    return 0;
}
