// holdmybyte codec bridge: plain C API over jpegli, libwebp and libjxl (Docs/SPEC.md §3.13).
// Frozen after WP0; WP1 implements it in jpegli.cc, webp.cc, jxl.cc and buffer.cc.
#ifndef HMB_CODECS_H
#define HMB_CODECS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { uint8_t *data; size_t size; } hmb_buffer;          // malloc'ed; release with hmb_buffer_free
typedef struct { const uint8_t *data; size_t size; } hmb_bytes;     // borrowed
typedef struct { uint8_t code; hmb_bytes payload; } hmb_marker;
void hmb_buffer_free(hmb_buffer *b);
// All functions return 0 on success; on failure write a NUL-terminated message into err (err_len ≥ 256).
// progressive_level 0…2 as cjpegli -p; HMB_JPEGLI_SCAN_PROXY: progressive (SOF2) with the minimal scan script (one
// interleaved DC scan, one full AC scan per component, no successive approximation). Same coefficients as level 2,
// fewer scans; for candidates that are only scored, never delivered (the search mosaic).
#define HMB_JPEGLI_SCAN_PROXY 3
int  hmb_jpegli_encode(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                       float distance, int subsampling_444, int progressive_level,
                       const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len);
// Extended jpegli knobs (added after WP0; `hmb_jpegli_encode` is this with chroma_distance = distance, sampling from
// subsampling_444, adaptive quantisation on). Every combination is a baseline-decodable progressive JPEG.
typedef struct {
    float distance;             // luma (table 0) distance, 0...25
    float chroma_distance;      // Cb/Cr tables (1, 2); <= 0 means `distance`
    int sampling;               // 0 = 4:2:0, 1 = 4:4:4, 2 = 4:2:2 (luma h2v1)
    int adaptive_quantization;  // 1 = on (jpegli default)
    int progressive_level;      // 0...2, or HMB_JPEGLI_SCAN_PROXY
    float luma_tilt;            // AC entries at radial frequency f = row + col >= 4 scaled by exp(tilt·(f − 3)/11); 0 = off
    float chroma_tilt;          // the same for the Cb/Cr tables
    float dc_ratio;             // each table's DC entry taken at its distance × this; <= 0 or 1 = off
    const int *scan_choice;     // per-component AC scan script (see hmb_jpeg_choose_scans), NULL = progressive_level's;
                                // ignored for HMB_JPEGLI_SCAN_PROXY and level 0
    int standard_tables;        // 1 = the Annex K tables (ITU T.81 K.1/K.2, one chroma table) scaled linearly by jpegli
                                // from the distance (jpegli_use_standard_quant_tables); 0 = jpegli's own tables
} hmb_jpegli_options;
int  hmb_jpegli_encode_opts(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                            const hmb_jpegli_options *options,
                            const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len);
// Lossless post-pass on a progressive 3-component jpegli output (variant "postpass"): rewrites the entropy-coded
// data with a per-component progressive scan script chosen from the coefficients; APPn/COM segments, tables and
// coefficients are unchanged (identical decoded pixels). out->size == 0 when the input is not eligible or the
// rewrite is not smaller.
int  hmb_jpeg_optimize_scans(const uint8_t *jpeg, size_t size, hmb_buffer *out, char *err, size_t err_len);
// Rewrite with options, always returned (the caller verifies): zero_min_k > 0 zeroes isolated ±1 AC coefficients at
// zigzag index >= zero_min_k with zero runs >= zero_min_run on both sides, in the components of component_mask (bit c);
// then the script is estimated (optimize_scans), forced (force_choice = c0 + 4*c1 + 16*c2) or level 2. Lossy when
// zeroing: the caller re-scores (variant "postpass", resized JPEG deliveries).
// The per-component AC scan choice (0 = jpegli level 2: 1-2, 3-63 Al 2→1→0; 1 = 1-2, 3-63 Al 1→0; 2 = 1-2, 3-63;
// 3 = 1-63) that `hmb_jpeg_optimize_scans` would use for this JPEG; {0,0,0} when it is not eligible.
int  hmb_jpeg_choose_scans(const uint8_t *jpeg, size_t size, int choice[3], char *err, size_t err_len);
typedef struct { int zero_min_k; int zero_min_run; int component_mask; int optimize_scans; int force_choice; } hmb_jpeg_rewrite_options;
int  hmb_jpeg_rewrite(const uint8_t *jpeg, size_t size, hmb_jpeg_rewrite_options options, hmb_buffer *out,
                          char *err, size_t err_len);
// hmb_jpegli_encode with an explicit per-component AC scan choice (as above; NULL = progressive_level's script);
// hmb_jpegli_encode_opts with `scan_choice` set is the same with the extended knobs.
int  hmb_jpegli_encode_scans(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                             float distance, int subsampling_444, int progressive_level, const int *scan_choice,
                             const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len);
typedef struct hmb_webp_prepared hmb_webp_prepared;
int  hmb_webp_prepare(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                      hmb_webp_prepared **out, char *err, size_t err_len);
int  hmb_webp_encode(const hmb_webp_prepared *p, float quality, int method,
                     hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp, hmb_buffer *out, char *err, size_t err_len);
// WEBP_PRESET_PHOTO with overrides (a negative value keeps the preset's setting); hmb_webp_encode = method only.
typedef struct { int method; int sns_strength; int filter_strength; int filter_sharpness; int filter_type;
                 int autofilter; int segments; int partition_limit; int pass; } hmb_webp_tuning;
int  hmb_webp_encode_tuned(const hmb_webp_prepared *p, float quality, hmb_webp_tuning tuning,
                           hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp, hmb_buffer *out, char *err, size_t err_len);
void hmb_webp_release(hmb_webp_prepared *p);
int  hmb_jxl_transcode_jpeg(const uint8_t *jpeg, size_t size, int effort, hmb_buffer *out, char *err, size_t err_len);
int  hmb_jxl_reconstruct_jpeg(const uint8_t *jxl, size_t size, hmb_buffer *out, char *err, size_t err_len);
// The same with up to `threads` threads per call (libjxl's output does not depend on the thread count).
int  hmb_jxl_transcode_jpeg_threads(const uint8_t *jpeg, size_t size, int effort, int threads, hmb_buffer *out,
                                    char *err, size_t err_len);
int  hmb_jxl_reconstruct_jpeg_threads(const uint8_t *jxl, size_t size, int threads, hmb_buffer *out, char *err,
                                      size_t err_len);
const char *hmb_codec_versions(void);   // "libjxl 0.11.2 · jpegli (libjxl 0.11.2) · libwebp 1.6.0"

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // HMB_CODECS_H
