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

#include <algorithm>
#include <csetjmp>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#include "lib/jpegli/decode.h"
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


// Scan scripts of the post-pass (defined below).
constexpr int kMaxScans = 3 + 3 * 4;
int build_script(bool interleave_dc, const int choice[3], jpeg_scan_info *scans);
bool valid_choice(const int *choice);

}  // namespace

int hmb_jpegli_encode(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                      float distance, int subsampling_444, int progressive_level,
                      const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len) {
    return hmb_jpegli_encode_scans(rgba, width, height, stride, distance, subsampling_444, progressive_level, nullptr,
                                   markers, marker_count, out, err, err_len);
}

int hmb_jpegli_encode_scans(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                            float distance, int subsampling_444, int progressive_level, const int *scan_choice,
                            const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len) {
    hmb_jpegli_options options;
    std::memset(&options, 0, sizeof options);
    options.distance = distance;
    options.chroma_distance = distance;
    options.sampling = subsampling_444 ? 1 : 0;
    options.adaptive_quantization = 1;
    options.progressive_level = progressive_level;
    options.dc_ratio = 1;
    options.scan_choice = scan_choice;
    return hmb_jpegli_encode_opts(rgba, width, height, stride, &options, markers, marker_count, out, err, err_len);
}

int hmb_jpegli_encode_opts(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                           const hmb_jpegli_options *options,
                           const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len) {
    if (options == nullptr) return fail(err, err_len, "hmb_jpegli_encode: options are NULL");
    const float distance = options->distance;
    const float chroma_distance = options->chroma_distance > 0 ? options->chroma_distance : distance;
    const int sampling = options->sampling;
    const int progressive_level = options->progressive_level;
    const int *scan_choice = options->scan_choice;
    if (out == nullptr) return fail(err, err_len, "hmb_jpegli_encode: out is NULL");
    out->data = nullptr;
    out->size = 0;
    if (rgba == nullptr) return fail(err, err_len, "hmb_jpegli_encode: pixels are NULL");
    if (width == 0 || height == 0 || width > 65500 || height > 65500)
        return fail(err, err_len, "hmb_jpegli_encode: unsupported size %ux%u", width, height);
    if (stride < static_cast<size_t>(width) * 4) return fail(err, err_len, "hmb_jpegli_encode: stride too small");
    if (!(distance >= 0.0f && distance <= 25.0f))
        return fail(err, err_len, "hmb_jpegli_encode: distance %g outside 0...25", static_cast<double>(distance));
    if (!(chroma_distance >= 0.0f && chroma_distance <= 25.0f))
        return fail(err, err_len, "hmb_jpegli_encode: chroma distance %g outside 0...25", static_cast<double>(chroma_distance));
    if (sampling < 0 || sampling > 2) return fail(err, err_len, "hmb_jpegli_encode: sampling %d outside 0...2", sampling);
    if (progressive_level < 0 || progressive_level > HMB_JPEGLI_SCAN_PROXY)
        return fail(err, err_len, "hmb_jpegli_encode: progressive level %d outside 0...%d", progressive_level,
                    HMB_JPEGLI_SCAN_PROXY);
    if (scan_choice != nullptr && !valid_choice(scan_choice))
        return fail(err, err_len, "hmb_jpegli_encode: invalid scan choice");
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
    cinfo.comp_info[0].h_samp_factor = sampling == 1 ? 1 : 2;
    cinfo.comp_info[0].v_samp_factor = sampling == 0 ? 2 : 1;
    for (int i = 1; i < cinfo.num_components; ++i) {
        cinfo.comp_info[i].h_samp_factor = 1;
        cinfo.comp_info[i].v_samp_factor = 1;
    }
    jpegli_enable_adaptive_quantization(&cinfo, options->adaptive_quantization ? TRUE : FALSE);
    // jpegli derives its three tables (Y, Cb, Cr) from one distance. A separate chroma distance takes the Cb/Cr tables
    // jpegli makes at that distance (same base matrices, same 4:2:0 rescale) and the luma table at `distance`; a DC
    // ratio takes each table's DC entry from the distance × dc_ratio. jpegli's quantiser reads everything else (zero
    // bias, adaptive quantisation) from the tables. With all ratios at 1 this is exactly jpegli_set_distance.
    const float dc_ratio = options->dc_ratio > 0 ? options->dc_ratio : 1.0f;
    if (chroma_distance != distance || dc_ratio != 1.0f) {
        UINT16 tables[3][DCTSIZE2];
        auto take = [&](float d, int first, int last, bool dc) {
            jpegli_set_distance(&cinfo, d, TRUE);
            for (int t = first; t <= last; ++t) {
                if (dc) tables[t][0] = cinfo.quant_tbl_ptrs[t]->quantval[0];
                else std::memcpy(tables[t], cinfo.quant_tbl_ptrs[t]->quantval, sizeof tables[t]);
            }
        };
        take(distance, 0, 0, false);
        take(chroma_distance, 1, 2, false);
        if (dc_ratio != 1.0f) {
            take(std::min(25.0f, distance * dc_ratio), 0, 0, true);
            take(std::min(25.0f, chroma_distance * dc_ratio), 1, 2, true);
        }
        jpegli_set_distance(&cinfo, distance, TRUE);
        for (int t = 0; t < 3; ++t) std::memcpy(cinfo.quant_tbl_ptrs[t]->quantval, tables[t], sizeof tables[t]);
    } else {
        jpegli_set_distance(&cinfo, distance, TRUE);
    }
    for (int t = 0; t < 3; ++t) {
        const float tilt = t == 0 ? options->luma_tilt : options->chroma_tilt;
        if (tilt == 0.0f || cinfo.quant_tbl_ptrs[t] == nullptr) continue;
        for (int k = 1; k < DCTSIZE2; ++k) {          // natural order: row k / 8, column k % 8
            const int f = k / 8 + k % 8;
            if (f < 4) continue;
            const float q = std::round(cinfo.quant_tbl_ptrs[t]->quantval[k] * std::exp(tilt * (f - 3) / 11.0f));
            cinfo.quant_tbl_ptrs[t]->quantval[k] = static_cast<UINT16>(q < 1 ? 1 : q > 255 ? 255 : q);
        }
    }
    // The proxy script: jpegli's quantisation does not depend on the scan script (only tokenisation and the SOF
    // marker do), so these are level 2's coefficients in 4 scans instead of 15.
    jpeg_scan_info proxy_scans[1 + MAX_COMPS_IN_SCAN];
    jpeg_scan_info scans[kMaxScans];
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
        if (valid_choice(scan_choice) && progressive_level > 0) {    // explicit per-component AC script (post-pass)
            cinfo.scan_info = scans;
            cinfo.num_scans = build_script(sampling == 1, scan_choice, scans);
        }
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

// MARK: - Lossless post-pass (variant "postpass"): progressive scan script chosen per component
//
// jpegli's progressive level 2 uses one AC script for every component: 1-2, then 3-63 by successive approximation
// (Al 2 → 1 → 0). Which split is cheapest depends on the photo and the component (holdout, brute force over 10
// scripts: Y prefers 3-63 in one scan, or with one or two refinement steps; chroma mostly 3-63 in one scan).
// `hmb_jpeg_optimize_scans` reads the coefficients of a jpegli output, estimates the Huffman-coded size of each
// candidate AC script per component from the coefficients (the libjpeg progressive token rules, optimal
// length-limited codes per scan), and rewrites the entropy-coded data with the cheapest script per component.
// Quantised coefficients, quantisation tables, sampling factors and every APPn/COM segment (copied byte for byte)
// are unchanged, so every decoder produces identical pixels. A result that is not smaller is not returned.
namespace {

constexpr int kZigzag[64] = {0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
                             12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
                             35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
                             58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

int bit_length(unsigned v) { return v == 0 ? 0 : 32 - __builtin_clz(v); }

// One AC scan's statistics: symbol counts and the raw (appended) bits.
struct ScanStats {
    uint64_t freq[256] = {};
    uint64_t raw = 0;
    void eob(unsigned run) {        // EOBn symbol for a run of `run` blocks
        const int n = bit_length(run) - 1;
        ++freq[n << 4];
        raw += static_cast<uint64_t>(n);
    }
};

// Bits of the optimal length-limited (16-bit) Huffman code for `freq` (libjpeg's jpeg_gen_optimal_table), plus the
// DHT entry (17 + number of symbols bytes).
uint64_t huffman_bits(const uint64_t *freq_in) {
    uint64_t freq[257];
    int codesize[257] = {}, others[257];
    int used = 0;
    for (int i = 0; i < 256; ++i) { freq[i] = freq_in[i]; used += freq[i] > 0; }
    if (used == 0) return 0;
    freq[256] = 1;                  // reserved code point (no all-ones code)
    for (int i = 0; i < 257; ++i) others[i] = -1;
    for (;;) {
        int c1 = -1, c2 = -1;
        uint64_t v1 = UINT64_MAX, v2 = UINT64_MAX;
        for (int i = 0; i <= 256; ++i) {
            if (freq[i] && freq[i] <= v1) { v2 = v1; c2 = c1; v1 = freq[i]; c1 = i; }
            else if (freq[i] && freq[i] <= v2) { v2 = freq[i]; c2 = i; }
        }
        if (c2 < 0) break;
        freq[c1] += freq[c2];
        freq[c2] = 0;
        ++codesize[c1];
        while (others[c1] >= 0) { c1 = others[c1]; ++codesize[c1]; }
        others[c1] = c2;
        ++codesize[c2];
        while (others[c2] >= 0) { c2 = others[c2]; ++codesize[c2]; }
    }
    int bits[64] = {};
    for (int i = 0; i <= 256; ++i) if (codesize[i]) ++bits[std::min(codesize[i], 63)];
    for (int i = 63; i > 16; --i) {   // limit to 16 bits (JPEG Annex K.3)
        while (bits[i] > 0) {
            int j = i - 2;
            while (bits[j] == 0) --j;
            bits[i] -= 2; ++bits[i - 1]; bits[j + 1] += 2; --bits[j];
        }
    }
    int i = 16;
    while (bits[i] == 0) --i;
    --bits[i];                        // drop the reserved code point
    // Assign lengths to symbols by decreasing frequency, as the canonical table does.
    int order[256], n = 0;
    for (int s = 0; s < 256; ++s) if (freq_in[s]) order[n++] = s;
    std::sort(order, order + n, [&](int a, int b) { return freq_in[a] != freq_in[b] ? freq_in[a] > freq_in[b] : a < b; });
    uint64_t total = 0;
    int k = 0;
    for (int len = 1; len <= 16; ++len)
        for (int c = 0; c < bits[len] && k < n; ++c) total += freq_in[order[k++]] * static_cast<uint64_t>(len);
    return total + 8ull * (17 + static_cast<uint64_t>(used));
}

uint64_t scan_bits(const ScanStats &s) { return huffman_bits(s.freq) + s.raw; }

// Running state of one AC first scan (Ah = 0) over the blocks of one component, libjpeg's encode_mcu_AC_first.
struct FirstScan {
    int Ss, Se, Al;
    ScanStats s;
    unsigned eobrun = 0;
    // `a`: absolute coefficients in zigzag order; `last`: the last k in Ss..Se with (a[k] >> Al) != 0, else Ss − 1.
    void block(const unsigned *a, int last) {
        int r = 0;
        for (int k = Ss; k <= last; ++k) {
            const unsigned v = a[k] >> Al;
            if (v == 0) { ++r; continue; }
            if (eobrun) { s.eob(eobrun); eobrun = 0; }
            while (r > 15) { ++s.freq[0xF0]; r -= 16; }
            const int nbits = bit_length(v);
            ++s.freq[(r << 4) + nbits];
            s.raw += static_cast<uint64_t>(nbits);
            r = 0;
        }
        if (last < Se && ++eobrun == 0x7FFF) { s.eob(eobrun); eobrun = 0; }
    }
    uint64_t bits() { if (eobrun) { s.eob(eobrun); eobrun = 0; } return scan_bits(s); }
};

// Running state of one AC refinement scan (Ah = Al + 1), libjpeg's encode_mcu_AC_refine.
struct RefineScan {
    int Ss, Se, Al;
    ScanStats s;
    unsigned eobrun = 0;
    uint64_t be = 0;                  // correction bits buffered with the pending EOB run
    void flush() {
        if (eobrun) { s.eob(eobrun); eobrun = 0; }
        s.raw += be;
        be = 0;
    }
    // `last`: the last k in Ss..Se with (a[k] >> Al) != 0, else Ss − 1.
    void block(const unsigned *a, int last) {
        int eob = 0;                  // last newly non-zero coefficient
        for (int k = Ss; k <= last; ++k) if ((a[k] >> Al) == 1) eob = k;
        int r = 0;
        uint64_t br = 0;
        for (int k = Ss; k <= last; ++k) {
            const unsigned t = a[k] >> Al;
            if (t == 0) { ++r; continue; }
            while (r > 15 && k <= eob) {
                flush();
                ++s.freq[0xF0];
                r -= 16;
                s.raw += br;
                br = 0;
            }
            if (t > 1) { ++br; continue; }
            flush();
            ++s.freq[(r << 4) + 1];
            s.raw += 1 + br;
            br = 0;
            r = 0;
        }
        if (last < Se || r > 0 || br > 0) {
            ++eobrun;
            be += br;
            if (eobrun == 0x7FFF || be > 1000 - 64 + 1) flush();
        }
    }
    uint64_t bits() { flush(); return scan_bits(s); }
};

struct AcScan { int Ss, Se, Ah, Al; };
struct AcOption { const char *name; int count; AcScan scans[4]; };
// Candidate AC scripts per component (the jpegli level-2 script is "s2sa2").
constexpr AcOption kAcOptions[] = {
    {"s2sa2", 4, {{1, 2, 0, 0}, {3, 63, 0, 2}, {3, 63, 2, 1}, {3, 63, 1, 0}}},
    {"s2sa1", 3, {{1, 2, 0, 0}, {3, 63, 0, 1}, {3, 63, 1, 0}, {}}},
    {"s2", 2, {{1, 2, 0, 0}, {3, 63, 0, 0}, {}, {}}},
    {"full", 1, {{1, 63, 0, 0}, {}, {}, {}}},
};
constexpr int kAcOptionCount = sizeof kAcOptions / sizeof kAcOptions[0];

// Estimated bits of each option for one component: the seven distinct scans of the options are run side by side
// over the blocks (one zigzag gather per block; loops end at the last coefficient that is non-zero at the scan's
// point transform).
void estimate_options(const JBLOCK *const *rows, int nrows, int ncols, uint64_t out[kAcOptionCount]) {
    FirstScan f12{1, 2, 0}, f30{3, 63, 0}, f31{3, 63, 1}, f32{3, 63, 2}, f10{1, 63, 0};
    RefineScan r31{3, 63, 1}, r30{3, 63, 0};
    unsigned a[64];
    for (int y = 0; y < nrows; ++y) {
        for (int x = 0; x < ncols; ++x) {
            const JCOEF *b = rows[y][x];
            int last0 = 0, last1 = 0, last2 = 0;          // last zigzag k ≥ 1 with a ≥ 1, ≥ 2, ≥ 4 (0: none)
            for (int k = 1; k < 64; ++k) {
                const int v = b[kZigzag[k]];
                const unsigned m = static_cast<unsigned>(v < 0 ? -v : v);
                a[k] = m;
                if (m) { last0 = k; if (m >= 2) { last1 = k; if (m >= 4) last2 = k; } }
            }
            const int l12 = a[2] ? 2 : (a[1] ? 1 : 0);
            f12.block(a, l12);
            f10.block(a, last0);
            f30.block(a, last0 >= 3 ? last0 : 2);
            f31.block(a, last1 >= 3 ? last1 : 2);
            f32.block(a, last2 >= 3 ? last2 : 2);
            r31.block(a, last1 >= 3 ? last1 : 2);
            r30.block(a, last0 >= 3 ? last0 : 2);
        }
    }
    const uint64_t b12 = f12.bits(), b30r = r30.bits();
    out[0] = b12 + f32.bits() + r31.bits() + b30r;
    out[1] = b12 + f31.bits() + b30r;
    out[2] = b12 + f30.bits();
    out[3] = f10.bits();
}

// Length of the leading APPn/COM run after SOI, and whether any APPn/COM segment follows later (then the
// post-pass declines: it only re-emits the leading run).
bool leading_markers(const uint8_t *p, size_t n, size_t *end) {
    if (n < 4 || p[0] != 0xFF || p[1] != 0xD8) return false;
    size_t i = 2;
    while (i + 4 <= n && p[i] == 0xFF && ((p[i + 1] >= 0xE0 && p[i + 1] <= 0xEF) || p[i + 1] == 0xFE)) {
        i += 2 + ((static_cast<size_t>(p[i + 2]) << 8) | p[i + 3]);
    }
    if (i > n) return false;
    *end = i;
    // Walk the remaining header segments up to the first SOS: no APPn/COM may follow.
    size_t j = i;
    while (j + 4 <= n && p[j] == 0xFF) {
        const uint8_t m = p[j + 1];
        if (m == 0xDA) return true;
        if ((m >= 0xE0 && m <= 0xEF) || m == 0xFE) return false;
        j += 2 + ((static_cast<size_t>(p[j + 2]) << 8) | p[j + 3]);
    }
    return false;
}

// Lossy rewrite option (re-scored by the caller): zero isolated ±1 AC coefficients at zigzag index ≥ min_k whose zero runs
// before and after are both ≥ min_run (after: up to the next non-zero or the block end).
void zero_isolated_ones(JBLOCKROW *rows, int nrows, int ncols, int min_k, int min_run) {
    for (int y = 0; y < nrows; ++y) {
        for (int x = 0; x < ncols; ++x) {
            JCOEF *b = rows[y][x];
            int last = 0;                         // zigzag index of the previous non-zero (DC counts)
            for (int k = 1; k < 64; ++k) {
                const int v = b[kZigzag[k]];
                if (v == 0) continue;
                if (k >= min_k && (v == 1 || v == -1) && k - last - 1 >= min_run) {
                    int next = 64;
                    for (int j = k + 1; j < 64; ++j) if (b[kZigzag[j]] != 0) { next = j; break; }
                    if (next - k - 1 >= min_run || next == 64) { b[kZigzag[k]] = 0; continue; }
                }
                last = k;
            }
        }
    }
}

// The scan script for a per-component AC choice: DC as jpegli writes it (interleaved only without subsampling), then
// the AC scans step by step across the components (with choice {0,0,0} exactly jpegli's level-2 script).
int build_script(bool interleave_dc, const int choice[3], jpeg_scan_info *scans) {
    int n = 0;
    if (interleave_dc) {
        scans[n] = {};
        scans[n].comps_in_scan = 3;
        for (int c = 0; c < 3; ++c) scans[n].component_index[c] = c;
        ++n;
    } else {
        for (int c = 0; c < 3; ++c) { scans[n] = {}; scans[n].comps_in_scan = 1; scans[n].component_index[0] = c; ++n; }
    }
    for (int step = 0; step < 4; ++step) {
        for (int c = 0; c < 3; ++c) {
            const AcOption &o = kAcOptions[choice[c]];
            if (step >= o.count) continue;
            scans[n] = {};
            scans[n].comps_in_scan = 1;
            scans[n].component_index[0] = c;
            scans[n].Ss = o.scans[step].Ss; scans[n].Se = o.scans[step].Se;
            scans[n].Ah = o.scans[step].Ah; scans[n].Al = o.scans[step].Al;
            ++n;
        }
    }
    return n;
}
bool valid_choice(const int *choice) {
    if (choice == nullptr) return false;
    for (int c = 0; c < 3; ++c) if (choice[c] < 0 || choice[c] >= kAcOptionCount) return false;
    return true;
}

// Reads the coefficients of `jpeg` and, unless `chosen_only`, rewrites them with the per-component script `forced`
// (or the estimated cheapest one). `chosen` receives the choice. Lab options may zero coefficients first.
int rewrite(const uint8_t *jpeg, size_t size, const hmb_jpeg_rewrite_options *lab, const int *forced, int *chosen,
            bool chosen_only, hmb_buffer *out, char *err, size_t err_len);

}  // namespace

int hmb_jpeg_optimize_scans(const uint8_t *jpeg, size_t size, hmb_buffer *out, char *err, size_t err_len) {
    int chosen[3];
    return rewrite(jpeg, size, nullptr, nullptr, chosen, false, out, err, err_len);
}

int hmb_jpeg_choose_scans(const uint8_t *jpeg, size_t size, int choice[3], char *err, size_t err_len) {
    if (choice == nullptr) return fail(err, err_len, "hmb_jpeg_choose_scans: choice is NULL");
    choice[0] = choice[1] = choice[2] = 0;
    hmb_buffer unused = {nullptr, 0};
    return rewrite(jpeg, size, nullptr, nullptr, choice, true, &unused, err, err_len);
}

int hmb_jpeg_rewrite(const uint8_t *jpeg, size_t size, hmb_jpeg_rewrite_options options, hmb_buffer *out, char *err,
                         size_t err_len) {
    int chosen[3];
    const int forced[3] = {options.force_choice % 4, (options.force_choice / 4) % 4, (options.force_choice / 16) % 4};
    return rewrite(jpeg, size, &options, options.force_choice >= 0 ? forced : nullptr, chosen, false, out, err, err_len);
}

namespace {

int rewrite(const uint8_t *jpeg, size_t size, const hmb_jpeg_rewrite_options *lab, const int *forced, int *chosen,
            bool chosen_only, hmb_buffer *out, char *err, size_t err_len) {
    if (out == nullptr) return fail(err, err_len, "hmb_jpeg_optimize_scans: out is NULL");
    out->data = nullptr;
    out->size = 0;
    size_t marker_end = 0;
    if (jpeg == nullptr || !leading_markers(jpeg, size, &marker_end)) return 0;   // not ours: no gain, no error

    jpeg_decompress_struct dinfo;
    jpeg_compress_struct cinfo;
    HMBJpegError error;
    struct { unsigned char *data; unsigned long size; } output = {nullptr, 0};  // NOLINT(runtime/int)
    volatile bool dcreated = false, ccreated = false;
    hmb_arena::Scope arena;
    ArenaHooks dhooks = {}, chooks = {};
    jpeg_scan_info scans[kMaxScans];

    std::memset(&dinfo, 0, sizeof dinfo);
    std::memset(&cinfo, 0, sizeof cinfo);
    dinfo.err = jpegli_std_error(&error.manager);
    cinfo.err = &error.manager;
    error.manager.error_exit = hmb_jpegli_error_exit;
    error.manager.output_message = hmb_jpegli_output_message;
    error.message[0] = '\0';

    if (setjmp(error.env)) {
        if (ccreated) jpegli_destroy_compress(&cinfo);
        if (dcreated) jpegli_destroy_decompress(&dinfo);
        arena.discard();
        std::free(output.data);
        return fail(err, err_len, "jpegli post-pass: %s", error.message[0] ? error.message : "unknown error");
    }

    auto hook = [](j_common_ptr common, ArenaHooks *hooks) {
        hooks->alloc_small = common->mem->alloc_small;
        hooks->alloc_large = common->mem->alloc_large;
        hooks->free_pool = common->mem->free_pool;
        hooks->self_destruct = common->mem->self_destruct;
        common->client_data = hooks;
        common->mem->alloc_small = arena_alloc_small;
        common->mem->alloc_large = arena_alloc_large;
        common->mem->free_pool = arena_free_pool;
        common->mem->self_destruct = arena_self_destruct;
    };

    jpegli_create_decompress(&dinfo);
    dcreated = true;
    hook(reinterpret_cast<j_common_ptr>(&dinfo), &dhooks);
    jpegli_mem_src(&dinfo, jpeg, static_cast<unsigned long>(size));  // NOLINT(runtime/int)
    jpegli_read_header(&dinfo, TRUE);
    const bool eligible = dinfo.num_components == 3 && dinfo.progressive_mode && !dinfo.arith_code &&
                          dinfo.restart_interval == 0 && dinfo.jpeg_color_space == JCS_YCbCr;
    if (!eligible) {
        jpegli_destroy_decompress(&dinfo);
        return 0;
    }
    jvirt_barray_ptr *coefficients = jpegli_read_coefficients(&dinfo);

    // Choose the cheapest AC option per component (lab: optionally after zeroing, optionally the level-2 script).
    int choice[3] = {0, 0, 0};
    for (int c = 0; c < 3; ++c) {
        if (lab != nullptr && lab->zero_min_k > 0 && (lab->component_mask & (1 << c))) {
            jpeg_component_info *comp = &dinfo.comp_info[c];
            const int nrows = static_cast<int>(comp->height_in_blocks), ncols = static_cast<int>(comp->width_in_blocks);
            std::vector<JBLOCKROW> rows(static_cast<size_t>(nrows));
            for (int y = 0; y < nrows; ++y) {
                rows[static_cast<size_t>(y)] = (*dinfo.mem->access_virt_barray)(
                    reinterpret_cast<j_common_ptr>(&dinfo), coefficients[c], static_cast<JDIMENSION>(y), 1, TRUE)[0];
            }
            zero_isolated_ones(rows.data(), nrows, ncols, lab->zero_min_k, lab->zero_min_run);
        }
        if (forced != nullptr) { choice[c] = forced[c]; continue; }
        if (lab != nullptr && !lab->optimize_scans) continue;
        jpeg_component_info *comp = &dinfo.comp_info[c];
        const int nrows = static_cast<int>(comp->height_in_blocks), ncols = static_cast<int>(comp->width_in_blocks);
        std::vector<JBLOCKROW> rows(static_cast<size_t>(nrows));
        for (int y = 0; y < nrows; ++y) {
            rows[static_cast<size_t>(y)] = (*dinfo.mem->access_virt_barray)(
                reinterpret_cast<j_common_ptr>(&dinfo), coefficients[c], static_cast<JDIMENSION>(y), 1, FALSE)[0];
        }
        uint64_t bits[kAcOptionCount];
        estimate_options(rows.data(), nrows, ncols, bits);
        for (int o = 1; o < kAcOptionCount; ++o) if (bits[o] < bits[choice[c]]) choice[c] = o;
    }

    for (int c = 0; c < 3; ++c) chosen[c] = choice[c];
    if (chosen_only) {
        jpegli_destroy_decompress(&dinfo);
        return 0;
    }
    const int n = build_script(dinfo.max_h_samp_factor == 1 && dinfo.max_v_samp_factor == 1, choice, scans);

    jpegli_create_compress(&cinfo);
    ccreated = true;
    hook(reinterpret_cast<j_common_ptr>(&cinfo), &chooks);
    jpegli_mem_dest(&cinfo, &output.data, &output.size);
    jpegli_copy_critical_parameters(&dinfo, &cinfo);
    cinfo.write_JFIF_header = FALSE;
    cinfo.write_Adobe_marker = FALSE;
    cinfo.optimize_coding = TRUE;
    cinfo.scan_info = scans;
    cinfo.num_scans = n;
    jpegli_write_coefficients(&cinfo, coefficients);
    jpegli_finish_compress(&cinfo);
    jpegli_destroy_compress(&cinfo);
    ccreated = false;
    jpegli_finish_decompress(&dinfo);
    jpegli_destroy_decompress(&dinfo);
    dcreated = false;

    // Output = SOI + the input's APPn/COM run verbatim + jpegli's tables and scans (its own output after SOI).
    const size_t body = output.size >= 2 ? output.size - 2 : 0;
    const size_t total = marker_end + body;
    if (output.data == nullptr || output.size < 4 || (lab == nullptr && total >= size)) {     // no gain
        std::free(output.data);
        return 0;
    }
    uint8_t *result = static_cast<uint8_t *>(std::malloc(total));
    if (result == nullptr) {
        std::free(output.data);
        return fail(err, err_len, "jpegli post-pass: out of memory");
    }
    std::memcpy(result, jpeg, marker_end);
    std::memcpy(result + marker_end, output.data + 2, body);
    std::free(output.data);
    out->data = result;
    out->size = total;
    return 0;
}

}  // namespace
