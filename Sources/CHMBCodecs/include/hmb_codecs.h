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
typedef struct hmb_webp_prepared hmb_webp_prepared;
int  hmb_webp_prepare(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                      hmb_webp_prepared **out, char *err, size_t err_len);
int  hmb_webp_encode(const hmb_webp_prepared *p, float quality, int method,
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
