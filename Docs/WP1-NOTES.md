# WP1 notes: codecs, imaging and metric

Branch `wp1-codecs-metric`. Everything listed in SPEC §5.1 is built; all seven acceptance criteria are met (table
below). Measurements and the metric validation are in `Docs/METRIC.md`.

## What was built

| Path | Content |
|---|---|
| `Sources/CHMBCodecs/jpegli.cc` | `hmb_jpegli_encode`: native `jpegli_*` API, RGBX input, `cjpegli` settings (defaults, adaptive quantisation, optimised Huffman, given progressive level, 4:2:0 or 4:4:4). Errors via `error_exit` → `longjmp` → message; the output buffer is freed on every error path. |
| `Sources/CHMBCodecs/webp.cc` | `hmb_webp_prepare` (RGBX import + `WebPPictureSharpARGBToYUVA` once, ARGB dropped), `hmb_webp_encode` (copy of the YUV planes per probe, `WEBP_PRESET_PHOTO`, method, `thread_level 0`; ICCP/EXIF/XMP via libwebpmux → VP8X file; without metadata a simple VP8 file), `hmb_webp_release`. |
| `Sources/CHMBCodecs/jxl.cc` | `hmb_jxl_transcode_jpeg` (container + `JxlEncoderStoreJPEGMetadata`, effort option, no parallel runner = one thread, deterministic), `hmb_jxl_reconstruct_jpeg` (JPEG reconstruction events, growing buffer; files without reconstruction data are an error). |
| `Sources/CHMBCodecs/buffer.cc` | `hmb_buffer_free`, `hmb_codec_versions` (unchanged from WP0). `stub_error.h` deleted (WP0 notes). |
| `Sources/HMBEngine/Codecs/` | `JpegliEncoder`, `LibWebPEncoder` + `LibWebPPrepared`, `LibJXLTranscoder`, `CodecBridge` (error buffers; outputs become `Data` that owns the malloc'ed bytes, no copy). |
| `Sources/HMBEngine/Imaging/` | `ImageIODecoder` (inspect: header-only, memory-mapped; decode: own RGB colour space, stored orientation, `kCGImageSourceShouldCache: false`), `JPEGInspector` (APPn/COM in order, ICC chain, EXIF, XMP, DQT quality, SOF type, CMYK, Adobe APP14, holdmybyte COM), `VImageProcessing` (features, Lanczos resize, perceptual `vImageConverter` to sRGB, mosaic), `GrainFeatures` (verbatim port). |
| `Sources/HMBEngine/Metric/` | `MetalSSIMULACRA2` (+ `MetalShaders`), `SSIMULACRA2` CPU oracle, `CPUSSIMULACRA2`. |
| `Sources/HMBEngine/Interfaces/Primitives+Live.swift` | `EnginePrimitives.live()`. |
| `Tests/HMBEngineTests/Primitives/` | 8 files, 33 tests: 2 need local data (`HMB_TEST_PHOTOS` + cjpegli, `HMB_HOLDOUT`), several extend to the samples when set, 3 are opt-in benchmarks (`HMB_METRIC_BENCH=1`). |

## Acceptance criteria (§5.1)

| # | Criterion | Status |
|---|---|---|
| 1 | Codec round trips on 4 synthetic fixtures + the 6 samples: JPEG size and marker order; WebP ICC/EXIF/XMP chunks; JXL byte-exact (SHA-256) | **met** (`CodecTests`; JXL also on 5 fixture JPEGs, a jpegli JPEG and all 6 samples) |
| 2 | jpegli equivalence vs `jpegos/Vendor/bin/cjpegli`, d 1.6/2.0, 6 samples: sizes ±1 %, scores ±0.2 | **met, byte-identical** in all 12 cases (0.000 %, 0.000). No pin switch needed. |
| 3 | GPU−CPU ≤ 0.02 on 10 pairs; new vs old port ≤ 0.05 on the 19 holdout outputs; monotone ladder | **met**: max 0.0046 (synthetic), 2.1e-4 (45 MP); old port max 0.00028 on identical pixels, 0.046 vs the one-decimal own scores with the old engine's candidate decoder. **But see Q1.** |
| 4 | 45 MP score ≤ 0.40 s median of 10, reference ≤ 0.20 s | **met**: 0.046 s (GPU 0.043 s), prepare 0.008 s, load 6.6 (release). Debug build 0.070 s. |
| 5 | Features = old GrainEstimator within 1e-6; resize never upscales; sRGB→sRGB identity (Δ ≤ 1) | **met** (12 synthetic image/size cases, expected values from running the old code once) |
| 6 | Repeated decodes identical; jpegli d 0.5 → PSNR ≥ 40 dB; CMYK/arithmetic/holdmybyte fixtures | **met** |
| 7 | No leaks (malloc_zone_statistics, 50 rounds, < 5 MB); C errors return messages, never abort | **met**: run alone, 2.9 KB per 50 rounds of all three codecs. Inside the full parallel suite the heap is shared with tests decoding 45 MP photos, so the in-suite bound (smallest of ten windows) is weaker; run `swift test --filter fiftyEncodesDoNotLeak` for the exact number. Error paths tested at C and Swift level |

`swift build` and `swift test` (97 tests in 18 suites, all targets, with `HMB_TEST_PHOTOS`/`HMB_HOLDOUT` set, 147 s at load 9.4; the 3 benchmarks skipped) are green; zero
warnings in WP1 files.

## Deviations and decisions

| # | Where | Spec | Code | Why |
|---|---|---|---|---|
| D1 | jpegli output | — | no JFIF APP0, no Adobe APP14: SOI, then exactly the caller's markers, then tables/scans | §3.7 lists the markers WP2 writes; a JFIF APP0 before APP1 Exif is non-conforming for Exif readers. Old outputs had no APP0 either. Outputs are still byte-identical to `cjpegli` on PPM input. |
| D2 | `MetalSSIMULACRA2` | "half-precision intermediates" | float throughout | precision: sigma = blurred moment − mu² are ~1e-4 differences; half would move per-pixel SSIM by percent. Budget met without it (METRIC §2). |
| D3 | GPU final reduction | GPU-side final reduction (audit #5) | GPU reduces to 6 floats per 32×32 tile; CPU sums ~1.1 M floats in double (< 3 ms release) | precision of the double sum; cost negligible. |
| D4 | Reference cache | old port cached XYB + mu1 + sigma11 | only the XYB pyramid | mu1/sigma11 recomputed for free inside the fused kernel; 0.73 GB per 45 MP reference instead of 2.2 GB (helps §3.9's memory budget). |
| D5 | Scale loop on GPU | old GPU tested the halved size | follows the CPU oracle / libjxl (previous level tested) | old GPU and CPU disagreed below 256 px short edge; the oracle is the reference. |
| D6 | `EnginePrimitives.live()` | — | throws when Metal is unavailable (no silent CPU fallback) | the CPU oracle is ~3.5 s (release) per 45 MP score; a silent fallback would make jobs ~70× slower in the metric. Callers can compose `CPUSSIMULACRA2()` explicitly. |
| D7 | `inspect` for PNG/TIFF/HEIC | EXIF as TIFF payload | `exif = nil`; `xmp` = ImageIO's XMP serialisation of all metadata (EXIF/TIFF/GPS in the `exif:`/`tiff:` namespaces); ICC from the image's colour space | ImageIO does not expose raw EXIF bytes for these containers; WP2's XMP policy filter can still remove GPS/serials. |
| D8 | `resized` | — | long edge exactly `longEdge`, short edge rounded (≥ 1); returns the same instance when no downscale is needed | — |
| D9 | `decode` of transparent PNG/TIFF | "alpha ignored" | flattened onto white; X byte is 255 everywhere | deterministic, opaque contract |
| D10 | `convertedToSRGB` | — | returns the same instance when the colour space already is sRGB (by name or identical ICC) | the identity test also forces a real conversion (Δ ≤ 1) |
| D11 | mosaic | 8×4 grid of 256² | port of `scripts/mosaic.py` "grid" (cell centre floored to /16), also for portrait images (no rotation of the grid); nil if width < 2048 or height < 1024 | as specified; portrait 45 MP (5504 wide) qualifies |

Additions (public, beyond §3.2): `MetalSSIMULACRA2.shared`, `init(workingSetRetention:referenceRetention:)`,
`drainPools()`, `lastGPUSeconds`, `lastUploadWasWrapped`, `Reference.byteCount`; `SSIMULACRA2.score(reference:distorted:)`,
`CPUSSIMULACRA2`; `ImageIODecoder.inspect(data:)`; `VImageProcessing.resizedSize`, `mosaicOrigins`, `sRGB`;
`JpegliEncoder.progressiveLevel`, `LibWebPEncoder.method`.

## Hand-over to WP2

- Memory per 45 MP geometry: live reference 0.73 GB until `release`; pooled working set 0.72 GB and pooled spare
  reference 0.73 GB (one each per geometry, at most 3 geometries). Call `MetalSSIMULACRA2.shared?.drainPools()` when a
  job settles. `release` is idempotent and safe while another thread still scores.
- `score` is thread-safe; serialising through the MetricLane is still right (one GPU).
- The metric is no longer the bottleneck: per full probe jpegli p2 encode 0.39 s + ImageIO candidate decode 0.28 s
  (CPU) vs 0.05 s GPU. Worker count, not the GPU lane, will decide G2/G3.
- `JpegliEncoder` validates markers (APPn/COM only, payload ≤ 65 533 bytes); ICC chains must be pre-chunked.
- `LibWebPPrepared` frees its picture in `deinit`; one prepare per (photo, delivery), any number of encodes.

## Open questions for the lead

1. **Decoder scale shift (affects G1).** The floors were set on scores whose candidates were decoded by
   libjpeg-turbo. With ImageIO (E6) the same bytes read 0.29 lower on average (0.16…0.61, 19 holdout photos); at
   6.7 % bytes per point that is about +1.9 % bytes at equal floors, more than G1's +1.0 % margin. jpegli's own decoder
   (present in the archive) reads +1.5 above libjpeg-turbo and is therefore no fix. WP1 recommends keeping ImageIO
   (conservative for every common viewer) and re-baselining G1, or measuring G1 with this in mind. Details: METRIC §4.
2. **Budget re-plan.** With 0.05 s per score the §3.11 framing "Balanced is GPU-bound" no longer holds; the pipeline is
   CPU-bound (encode + decode per probe). This may change WP2's worker-count and MetricLane choices.
3. **Test-only tools.** The equivalence test runs `jpegos/Vendor/bin/cjpegli` (override `HMB_CJPEGLI`) and the
   holdout test runs `djpeg` from PATH (override `HMB_DJPEG`); both are skipped when absent and never linked. If WP5's
   audit greps test sources for Homebrew paths: none are hard-coded in WP1 tests.
4. **Benchmarks in release** need `swift test -c release -Xswiftc -enable-testing` (tests use `@testable`). WP5 may
   want the timing code in `HMBBench` instead.
