# Variant "postpass": free bytes after the search

Branch `eng-postpass` (worktree `hmb-eng-postpass`), base `main` at d42cb2d. Author: postpass. 2026-10-16.

Goal: shrink what the search has already decided without lowering any floor. Every pixel-exact step is proven by
comparing ImageIO decode buffers. Every lossy step is re-scored with v2's metric (ImageIO decode plus the Metal
SSIMULACRA2 port) on the delivered bytes and must reach the target.

## 1. Result

Release `hmb compress`, MacBookPro18,4, shared machine (5 agents; the load was never below 14). Times under load are
upper bounds. CPU is user + sys from `/usr/bin/time -l`, and A/B pairs ran back to back.

**Holdout, 19 photos, all four deliveries, A/B/A/B** (`runs/postpass-final-{baseline,postpass-v2}-{1,2}`):

| Delivery | Baseline bytes | postpass bytes | Δ | Min / median score (base → postpass) | Probes (base → postpass) |
|---|---|---|---|---|---|
| Couple (full, 74) | 50,239,686 | 50,114,251 | **−0.250 %** | 74.007 / 74.105 → 74.007 / 74.105 (pixels identical, 19/19) | 1.95 → 1.95 |
| Website (WebP 2560, ≥ 70) | 6,265,646 | 5,555,974 | **−11.33 %** | 70.090 / 70.636 → 70.034 / 70.672 | 2.74 → 2.79 |
| Social (JPEG 1440, ≥ 85) | 6,015,880 | 5,810,864 | **−3.41 %** | 85.006 / 85.264 → 85.000 / 85.026 | 3.95 → 7.95 (incl. 4 zeroing re-scores) |
| Archive (JXL) | 312,351,208 | 312,351,208 | 0 (SHA-256 identical) | byte-exact | — |

| Run | Wall | CPU (user + sys) | Peak RSS | Peak footprint | 1-min load before → after |
|---|---|---|---|---|---|
| baseline 1 | 48.8 s | 141.2 s | 6.10 GB | 6.84 GB | 16.8 → 50.1 |
| postpass 1 | 55.1 s | 153.9 s | 6.25 GB | 7.07 GB | 50.1 → 68.0 |
| baseline 2 | 44.5 s | 141.3 s | 6.20 GB | 6.90 GB | 68.0 → 71.2 |
| postpass 2 | 61.3 s | 148.6 s | 6.14 GB | 7.11 GB | 71.2 → 102.7 |

CPU: **+7.1 %** (mean of the pairs). The wall times are not comparable because the load rose from 17 to 103 during the
four runs. Both postpass repeats are byte-identical to each other (determinism holds).

**Full wedding, 535 photos, Couple + Website + Social in one run** (`runs/postpass-wedding-*`; announced as the
final-candidate run). Archive was left out because its bytes and code path are unchanged, which the holdout's
SHA-256 check above confirms. The postpass build ran first, then the baseline:

| | Couple | Website | Social | Total | Wall | CPU | Peak RSS / footprint | Load before → after |
|---|---|---|---|---|---|---|---|---|
| baseline | 1,352,439,246 | 163,408,108 | 163,455,205 | 1,679,302,559 | 873.0 s | 2355.7 s | 4.11 / 4.59 GB | 65.4 → 94.3 |
| postpass | 1,349,242,824 (**−0.236 %**) | 147,270,094 (**−9.88 %**) | 157,851,552 (**−3.43 %**) | 1,654,364,470 (−1.49 %, −24.9 MB) | 630.8 s | 2483.1 s (**+5.4 %**) | 3.98 / 4.87 GB | 95.5 → 65.4 |

All 535 photos reach their target in every delivery. Minimum scores: Couple 74.000, Website 70.001, Social 85.000.
Baseline bytes equal the documented baseline (G3/G5). The wall times are noise at load 65–95, and the baseline ran at
the higher load. No file in the wedding folder is newer than the start of these runs (`find -newer`). Website moves
from 163.4 MB to 147.3 MB and Social from 163.5 MB to 157.9 MB, which widens the margin under G5 (≤ 165 MB).

## 2. Where the bytes come from (holdout ablation)

The same postpass binary with its switches (`HMB_WEBP=spec`, `HMB_ZEROING=0`, `HMB_OPTIMIZE_SCANS=0`,
`HMB_XMP_LAYOUT=verbatim`). With every switch off, the output is SHA-256 identical to baseline. Load 14–17,
Couple + Website + Social:

| Step (cumulative) | Couple | Website | Social | Pixel-exact? | Cost |
|---|---|---|---|---|---|
| all off (= baseline) | 50,239,686 | 6,265,646 | 6,015,880 | — | — |
| + XMP without layout whitespace (removeLocation/removeAll only) | — | −1.26 % | −1.31 % | yes (not image data) | ~ms per photo (two CGImageMetadata parses) |
| + progressive scan script per component | −0.250 % | — | −0.32 % | **yes** | Couple ≈ 0 (see §3.2); Social ~45 ms CPU per photo + 2 decodes |
| + zeroing isolated ±1 coefficients, re-scored (Social) | — | — | −1.82 % | no, re-scored ≥ 85 | 4 rewrites + 4 scores; Social worker time +0.53 s per photo at load 14 |
| + WebP method 6, loop filter strength 40, sharpness 7 | — | −10.2 % | — | no, it is the searched encoder | encode 292 → 487 ms (lab); Website worker time +0.74 s per photo at load 14 |
| (option, not default) XMP minified under keepAll too | −0.19 % more | — | — | yes | ~ms |

## 3. What was evaluated

### 3.1 Lossless JPEG: scan script, Huffman, markers

- Already optimal: jpegli writes optimised Huffman tables (and clusters them), no restart markers, no JFIF or Adobe
  segment. Its DQT is three tables in one segment (199 B). Nothing is left there.
- **mozjpeg's `jpegtran` is worse than jpegli.** Its default scan optimisation gives 2,030,433 vs 2,009,434 bytes
  (+1.0 %), because it interleaves DC, which costs 25 KB at 4:2:0. jpegtran then falls back to copying the input.
- Brute force with jpegli itself (`read_coefficients` → `write_coefficients` with ten AC scripts, per photo and
  component): **−0.293 %** Couple, −0.31 % Social. The level-2 rewrite reproduces jpegli's file byte for byte. Fixed
  scripts gain less: the best fixed one, Y `1-2, 3-63 Al 1→0` with chroma `1-2, 3-63`, gives about −0.14 % of the file.
- **Estimator** (`hmb_jpeg_optimize_scans`): the libjpeg progressive token rules (EOB runs, ZRL, refinement
  correction bits) plus the optimal 16-bit-limited Huffman code per scan, over four candidate scripts per component.
  It makes the same choice as the brute force (−0.292 % vs −0.293 %). Cost at 45 MP, thread CPU at load 35–66:
  coefficient read 200 ms, estimate 155 ms, write 194 ms, so about 0.55 CPU-s per photo. That is too dear for Couple
  (+28 % of its CPU).
- **Shipped for full size: choose the script from the mosaic.** The script is estimated from the first 2 MP mosaic
  encode of the search, which MosaicSearch makes before any full probe, and every full probe is then encoded with it
  (`hmb_jpegli_encode_scans`). The coefficients are unchanged, so the scores are bit-identical and the search path is
  identical. Delivered bytes are still exactly the scored bytes (E3 holds). Lab (`mosaicChoice`, 19 photos, d at
  0.85, 1 and 1.15 × the prior): −0.279 % / −0.308 % / −0.311 %, vs −0.297 % / −0.326 % / −0.330 % with the full
  estimate. Pixels are identical. Encodes with the chosen script are no slower: 480 → 412 ms at d×1, with fewer
  scans. The extra cost is one read plus estimate on 2 MP.
- **Shipped for DirectSearch JPEG** (Social, full-size images under 2048×1024, the WebP→JPEG fallback): the full
  rewrite of the final file. It is kept only if it is smaller and ImageIO decodes both files to identical buffers.

### 3.2 Near-lossless: zeroing isolated ±1 AC coefficients

Lab (`threshold`): from a common encode, "zero the ±1 coefficients at zigzag ≥ K whose zero runs on both sides are
≥ r" against "raise d". Social at d 0.65: the zeroing saves 10–13 % of bytes per score point lost, against 8–10 %
per point for d. Couple at d 2.0 is mixed, because jpegli's d curve has steps.

As a re-scored post-pass on the delivered files (`lossyPostPass`): bisection over K ∈ [4, 64), run ≥ 2, all
components, at most 5 scores, on top of the scan rewrite:

| | Delivered | + scans | + zeroing | Overshoot mean before → after | Cost |
|---|---|---|---|---|---|
| Social | 6,015,880 | −0.312 % | **−2.229 %** | 0.240 → 0.020 | ~330 ms wall per photo (load 18, 4 parallel) |
| Couple | 50,239,686 | −0.292 % | −0.947 % | 0.137 → 0.051 | ~6.7 s wall per photo (45 MP rewrites + scores) |

It ships for DirectSearch JPEG only, with 4 attempts (`SearchConstants.zeroingAttempts`). In the pipeline it saves
1.82 % on the holdout. For Couple it costs too much CPU per byte saved and is not enabled.

### 3.3 WebP (Website)

Lab (`webp`): the real DirectSearch with the final metadata, run once per setting. Bytes are relative to the method-4
preset.

| Setting | Bytes | Min score | Probes | Encode per probe |
|---|---|---|---|---|
| method 4 (spec) | ±0 | 70.090 | 2.74 | 292 ms |
| method 5 | −3.51 % | 70.024 | 2.53 | 312 ms |
| method 6 | −6.63 % | 70.009 | 2.42 | 487 ms |
| method 4 + autofilter | −4.40 % | 70.049 | 2.95 | 1519 ms |
| method 6 + autofilter | −10.83 % | 70.023 | 2.79 | 1745 ms |
| sns 50 / 100 | +1.82 % / +1.32 % | | | |
| filter strength 50 | −0.79 % | | | |
| sharpness 0 / 6 | +3.30 % / −2.27 % | | | |
| simple filter (type 0) | +3.20 % | | | |
| segments 2 | +9.39 % | | | |
| **method 6, sharpness 7, strength 40 (shipped)** | **−10.2 %** (vs method 6: −3.72 %) | 70.034 | 2.79 | ~490 ms |
| method 5, sharpness 7, strength 40 | −6.4 % | 70.049 | 2.95 | ~340 ms |
| method 4, sharpness 7, strength 40 | −3.1 % | 70.054 | 2.89 | ~290 ms |

The second and third rounds ran at load 25–50, with the XMP minifier already active, so their baseline was 6,186,606
bytes. The loop filter's strength and sharpness are header fields that only the decoder applies, so at the same q they
give identical byte counts and only change the decoded image, and with it the score. Strength 40, 50 and 60 gave
identical results. As a same-q post-pass, method 6 re-encoded at the method-4 search's q passed on 19/19 photos
(−7.3 %). Searching directly with the better settings is simpler, and it keeps delivered = scored.
`near_lossless` only affects lossless WebP, so nothing changes there.

### 3.4 Archive (JXL lossless transcode, effort and Brotli)

Six holdout sources (126.5 MB), vendored libjxl 0.11.2, single thread, load 16–20:

| Setting | Bytes | Δ | Time per photo |
|---|---|---|---|
| effort 7 (shipped) | 99,097,697 | — | 2.25 s |
| effort 7, brotli_effort 11 | 99,093,117 | −0.005 % | 2.31 s |
| effort 7, uncompressed metadata boxes | 99,172,730 | +0.08 % | 2.44 s |
| effort 8 | 98,814,362 | −0.29 % | 6.23 s (×2.8) |
| effort 9 | 98,697,236 | −0.40 % | 39.95 s (×17.8) |

**Not worth it.** Effort 8 would save about 25 MB of 8.56 GB for about +2,100 CPU-s on the wedding, through the
3 archive lanes. Brotli effort does nothing.

### 3.5 Markers

XMP is pretty-printed by Lightroom and CGImageMetadata, and Lightroom adds about 2.5 KB of padding. Removing
whitespace runs that contain a line break and sit between tags saves 4.2 KB per Website and Social file and 4.9 KB
per Couple file. `XMPMinify` keeps the result only if CGImageMetadata reads exactly the same tags back: namespace,
type, value, arrays, structures and qualifiers. It skips packets that contain `parseType="Literal"`. On by default
for removeLocation and removeAll; keepAll stays verbatim (`XMPLayout.minifiedUnlessKeepAll`).

Not done:
- A compact sRGB ICC instead of the 3,144 B Apple profile on Website and Social (about −0.8 %). A different
  profile could render differently in some apps, so this is an owner decision.
- Dropping EXIF, XMP or IPTC is a policy question, not a post-pass.

## 4. What to merge

| Commit | Contents | Recommendation |
|---|---|---|
| ea9d955 | Codec layer: `hmb_jpeg_optimize_scans`, `hmb_jpeg_choose_scans`, `hmb_jpeg_rewrite`, `hmb_jpegli_encode_scans` (`Sources/CHMBCodecs/jpegli.cc`, `include/hmb_codecs.h`); `hmb_webp_encode_tuned` (`webp.cc`); `JPEGPostPass.swift`, `JPEGScanChoice` and defaulted `JPEGEncoding` requirements (`Primitives.swift`), `JpegliEncoder.swift`, `WebPTuning` (`LibWebPEncoder.swift`, `Primitives+Live.swift`), `XMPMinify.swift`, `Scripts/codec-headers.txt` (+ jpegli `decode.h`), `Tests/…/PostPassTests.swift` | **merge** |
| fac7a38 | Pipeline: scan script from the mosaic (full size), rewrite plus zeroing for DirectSearch JPEG, XMP layout (`PhotoPipeline.swift`, `SearchModel.swift`, `MetadataEditor.swift`); `hmb` A/B switches (`main.swift`) | **merge** |
| e5d1ba8 | Opt-in lab tests (`PostPassLabTests.swift`) | merge (opt-in, like `SearchABTests`) |

Every part can be switched off on its own: `SearchConstants.optimizeScans`, `.zeroingAttempts`, `.xmpLayout`, and
`WebPTuning.spec` passed to `EnginePrimitives.live(webpTuning:)`. If the WebP loop-filter setting is not wanted (see
risks), `WebPTuning(method: 6)` alone keeps −6.6 %. If CPU matters more, method 5 + sharpness 7 + strength 40 gives
−6.4 % at about +15 % WebP encode time.

The libraries are untouched: `libhmbcodecs.a` already exports `jpegli_read_coefficients` and
`jpegli_write_coefficients`. `Sources/CHMBCodecs/vendor-include/` is git-ignored, so after merging, run
`Scripts/build-codecs.sh`, or copy `lib/jpegli/decode.h` from the pinned libjxl v0.11.2, so that `decode.h` is there.

## 5. Risks

- **The WebP loop-filter setting exploits a decoder-side knob.** Sharpness 7 and strength 40 change how the decoder
  deblocks, not what the encoder spends. SSIMULACRA2 rewards it (−3.7 % on top of method 6). A visual check of
  low-q Website files for blocking is recommended before merging that part, which is a single constant.
- **E3 nuance.** For DirectSearch JPEG, the lossless rewrite is delivered instead of the scored bytes. The pixels are
  checked identical with ImageIO, and a mismatch keeps the scored bytes and logs it. Zeroing candidates are scored as
  delivered. Full-size outputs remain exactly the scored bytes.
- **`PhotoResult.probes` now counts the zeroing re-scores** (Social 3.95 → 7.95). G1/G2 probe gates only concern
  Couple, which is unchanged at 1.95.
- **Social now lands at the floor:** median 85.03, overshoot 0.24 → 0.04. This is intended, but no photo has margin
  left above 85.
- **The estimator was not updated.** Resized JPEG estimates skip the rewrite and zeroing, so Social reads about 2 % high
  (κ 1.0). Website estimates use the same encoder settings. Full size is unchanged.
- **Docs to update on merge:**
  - SPEC/ENGINE §3.5 says WebP method 4.
  - ENGINE §5 says untouched XMP stays byte-identical under removeLocation. It is now minified.
  - SPEC E3 needs the DirectSearch nuance above.
- **Cost:** +5.4 % CPU on the wedding (three lossy deliveries) and +7.1 % on the holdout (all four), mostly WebP
  method 6 and the Social zeroing. Peak memory is within noise (holdout footprint 6.84–6.90 → 7.07–7.11 GB; wedding
  4.59 → 4.87 GB at very different loads). Nothing large is allocated: the post-pass works on a 2 MP mosaic or a
  1440 px file inside the jpegli arena.
- **API:** `JPEGEncoding` gained two requirements with default implementations, so fakes compile unchanged.
  `hmb_codecs.h` gained functions; none changed.

## 6. Tests

- `swift build` and `swift build -c release`: zero warnings.
- `PostPassTests` (4, no local data needed):
  - the level-2 rewrite is byte-identical;
  - rewrites are never larger and keep the pixels and APPn/COM segments;
  - scripted encodes have identical pixels and equal the forced rewrite;
  - foreign JPEGs are left alone;
  - zeroing is monotone;
  - XMP reads back the same, and Literal packets are skipped.
- `JobTests`, `ReviewTests`, `ServiceTests`, `EstimatorTests`, `CompareTests`: pass.
- Full suite with env.sh sourced on the final code (e5d1ba8): 368 tests. One failure at load 72–83:
  `JSONHistoryStoreTests.twoThousandPhotoRecordRoundTripsAndLoadsWithinBudget`, a timing budget (0.315 s against
  0.300 s) in HMBStore, which this branch does not touch. It passed when rerun alone at load 28.
  - An earlier run, before the fix in fac7a38, failed JobTests, ReviewTests and ServiceTests: zeroing threw on fake
    (non-JPEG) encodes. They pass now.
- Opt-in lab: `HMB_POSTPASS_DIR=… swift test -c release --filter PostPassLabTests/scans`; likewise `mosaicChoice`
  (`HMB_POSTPASS_MOSAIC=1`), `threshold` (`HMB_POSTPASS_THRESH=1`), `lossyPostPass` (`HMB_POSTPASS_LOSSY=<run>`),
  and `webp` (`HMB_POSTPASS_WEBP='name:m=6,sharp=7,f=40;…'`).
