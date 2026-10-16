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

#include "arena.h"

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

// jpegli's working memory (coefficient planes: ~140 MB at 45 MP 4:2:0, row buffers) is taken from the calling
// thread's arena scope instead of malloc, so it returns to the kernel when the encode ends instead of staying in
// malloc's large-block cache (Docs/DECISIONS.md D-ENG-10). jpegli allocates every buffer through
// `cinfo->mem->alloc_small/alloc_large` and frees by pool, so the hooks keep a list per pool; a block that does not
// fit the arena comes from jpegli's own allocator as before. Blocks are 128-byte aligned (HWY_ALIGNMENT).
struct ArenaBlock {            // sits in front of each arena allocation
    ArenaBlock *next;
    void *raw;                 // what hmb_arena::allocate returned
};
constexpr size_t kBlockAlign = 128;
constexpr int kPools = 2 * JPOOL_NUMPOOLS;   // jpegli's plain and aligned pools

struct ArenaHooks {
    void *(*alloc_small)(j_common_ptr, int, size_t);
    void *(*alloc_large)(j_common_ptr, int, size_t);
    void (*free_pool)(j_common_ptr, int);
    void (*self_destruct)(j_common_ptr);
    ArenaBlock *pools[kPools];
};

void *arena_alloc(j_common_ptr cinfo, int pool_id, size_t size, void *(*fallback)(j_common_ptr, int, size_t)) {
    ArenaHooks *hooks = static_cast<ArenaHooks *>(cinfo->client_data);
    if (pool_id >= 0 && pool_id < kPools && size < (size_t(1) << 40)) {
        if (void *raw = hmb_arena::allocate(size + kBlockAlign + sizeof(ArenaBlock))) {
            const uintptr_t start = reinterpret_cast<uintptr_t>(raw) + sizeof(ArenaBlock);
            uint8_t *user = reinterpret_cast<uint8_t *>((start + kBlockAlign - 1) & ~(uintptr_t(kBlockAlign) - 1));
            ArenaBlock *block = reinterpret_cast<ArenaBlock *>(user) - 1;
            block->raw = raw;
            block->next = hooks->pools[pool_id];
            hooks->pools[pool_id] = block;
            return user;
        }
    }
    return fallback(cinfo, pool_id, size);
}
void *arena_alloc_small(j_common_ptr cinfo, int pool_id, size_t size) {
    return arena_alloc(cinfo, pool_id, size, static_cast<ArenaHooks *>(cinfo->client_data)->alloc_small);
}
void *arena_alloc_large(j_common_ptr cinfo, int pool_id, size_t size) {
    return arena_alloc(cinfo, pool_id, size, static_cast<ArenaHooks *>(cinfo->client_data)->alloc_large);
}
void arena_release_pool(ArenaHooks *hooks, int pool_id) {
    for (ArenaBlock *block = hooks->pools[pool_id]; block != nullptr;) {
        ArenaBlock *next = block->next;
        hmb_arena::release(block->raw);
        block = next;
    }
    hooks->pools[pool_id] = nullptr;
}
void arena_free_pool(j_common_ptr cinfo, int pool_id) {
    ArenaHooks *hooks = static_cast<ArenaHooks *>(cinfo->client_data);
    if (pool_id >= 0 && pool_id < JPOOL_NUMPOOLS) {       // jpegli frees a pool together with its aligned twin
        arena_release_pool(hooks, pool_id);
        arena_release_pool(hooks, pool_id + JPOOL_NUMPOOLS);
    }
    hooks->free_pool(cinfo, pool_id);
}
void arena_self_destruct(j_common_ptr cinfo) {
    ArenaHooks *hooks = static_cast<ArenaHooks *>(cinfo->client_data);
    for (int pool = 0; pool < kPools; ++pool) arena_release_pool(hooks, pool);
    hooks->self_destruct(cinfo);
}

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
    if (progressive_level < 0 || progressive_level > HMB_JPEGLI_SCAN_PROXY)
        return fail(err, err_len, "hmb_jpegli_encode: progressive level %d outside 0...%d", progressive_level,
                    HMB_JPEGLI_SCAN_PROXY);
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
    // The arena and the hooks outlive the setjmp below (both are set up before it and live in this frame).
    hmb_arena::Scope arena;
    ArenaHooks hooks = {};

    std::memset(&cinfo, 0, sizeof cinfo);
    cinfo.err = jpegli_std_error(&error.manager);
    error.manager.error_exit = hmb_jpegli_error_exit;
    error.manager.output_message = hmb_jpegli_output_message;
    error.message[0] = '\0';

    if (setjmp(error.env)) {
        if (created) jpegli_destroy_compress(&cinfo);
        arena.discard();          // containers whose destructors the longjmp skipped are unreachable now
        std::free(output.data);
        std::free(rows);
        return fail(err, err_len, "jpegli: %s", error.message[0] ? error.message : "unknown error");
    }

    jpegli_create_compress(&cinfo);
    created = true;
    hooks.alloc_small = cinfo.mem->alloc_small;
    hooks.alloc_large = cinfo.mem->alloc_large;
    hooks.free_pool = cinfo.mem->free_pool;
    hooks.self_destruct = cinfo.mem->self_destruct;
    cinfo.client_data = &hooks;
    cinfo.mem->alloc_small = arena_alloc_small;
    cinfo.mem->alloc_large = arena_alloc_large;
    cinfo.mem->free_pool = arena_free_pool;
    cinfo.mem->self_destruct = arena_self_destruct;
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
    // The proxy script: jpegli's quantisation does not depend on the scan script (only tokenisation and the SOF
    // marker do), so these are level 2's coefficients in 4 scans instead of 15.
    jpeg_scan_info proxy_scans[1 + MAX_COMPS_IN_SCAN];
    if (progressive_level == HMB_JPEGLI_SCAN_PROXY) {
        jpegli_set_progressive_level(&cinfo, 2);
        const int components = cinfo.num_components;
        if (components < 1 || components > MAX_COMPS_IN_SCAN) {
            std::snprintf(error.message, sizeof error.message, "proxy scan script: %d components", components);
            std::longjmp(error.env, 1);
        }
        std::memset(proxy_scans, 0, sizeof proxy_scans);
        proxy_scans[0].comps_in_scan = components;       // DC of all components, interleaved
        for (int c = 0; c < components; ++c) proxy_scans[0].component_index[c] = c;
        for (int c = 0; c < components; ++c) {            // then all AC coefficients of one component per scan
            jpeg_scan_info &scan = proxy_scans[1 + c];
            scan.comps_in_scan = 1;
            scan.component_index[0] = c;
            scan.Ss = 1;
            scan.Se = DCTSIZE2 - 1;
        }
        cinfo.scan_info = proxy_scans;
        cinfo.num_scans = 1 + components;
    } else {
        jpegli_set_progressive_level(&cinfo, progressive_level);
    }
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
