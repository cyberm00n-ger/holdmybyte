# METRIC: the SSIMULACRA2 port (WP1)

Owner: WP1 · 2026-10-15 · M1 Max (10 cores, 64 GB), shared machine: every timing carries its load average.

## 1. What is measured

`MetalSSIMULACRA2` (`Sources/HMBEngine/Metric/`) is the engine's metric (SPEC §3.0 E5). It ports the old jpegos
`MetalSSIMULACRA2.swift` / `SSIMULACRA2.swift` / `GaussianBlur.swift`: same algorithm, same constants, same scale.
`SSIMULACRA2` (CPU, Accelerate) stays in the module as the test oracle; `CPUSSIMULACRA2` wraps it as a
`PerceptualMetric` for tests.

Semantics carried over unchanged (they define the scale every floor lives on):
- 8-bit samples are read as **sRGB-encoded whatever the image's colour space** (the old engine did the same; a P3 or
  Adobe RGB photo is scored on its own code values against its own code values).
- Blur: truncated FIR Gaussian, sigma 1.5, radius 6, edge-extended (not libjxl's IIR). This is why the scale reads
  about +0.5 above the libjxl reference binary at ~74 (SPEC E5).
- The scale loop tests the previous level's size before halving, as libjxl does (a level under 8 px can be measured).
  The old GPU path tested the halved size instead; the difference only matters below 256 px on the short edge, where the
  old engine used the CPU path anyway. The new GPU path follows the oracle.
- Alpha is ignored (`PixelImage` is opaque). Inputs must be ≥ 8×8.

## 2. GPU design (and how it differs from the old port)

Per scale the candidate takes **two dispatches** (old: ~44):
1. `xyb_down_*`: one thread per pixel of the next scale reads its 2×2 source pixels (scale 0: RGBA8 through the
   oracle's own 256-entry sRGB→linear table), writes their XYB values at this scale and the box-filtered linear value
   at the next scale.
2. `ssim_tile`: one threadgroup (32×8 threads) per 32×32 output tile and channel. Phase 1 stages the horizontal 13-tap
   blur of a, b, a², b², a·b for the 44 rows the tile needs in threadgroup memory (28 KB); phase 2 finishes the vertical
   blur, evaluates the SSIM error and both edge maps and reduces Σd, Σd⁴ for the three maps to 6 floats per tile
   (`simd_sum` + an 8-way threadgroup sum). The CPU sums the ~1.1 M partials of a 45 MP score in double.

The reference keeps only its XYB pyramid (0.73 GB at 45 MP; old: XYB + mu + sigma, 2.2 GB): mu1 and sigma11 are
recomputed inside the tile kernel, where they cost no extra memory traffic. Working sets and spare reference pyramids
are pooled per geometry (old audit #2; retention configurable, default one each), page-aligned candidate pixels are
wrapped without a copy (audit #7), `pow(BIAS, 1/3)` is a constant (audit #3). All math stays **float**: the spec
suggested half-precision intermediates, but sigma terms are small differences of large moments (s − mu², ~1e-4 next to
C2 = 9e-4) and half precision would move per-pixel SSIM errors by percent; it was not needed for the budget either.

Thread safety: any number of callers may score concurrently (each call takes its own working set); releasing a
reference while a score still uses it defers the buffer recycling to the last user.

## 3. Validation

| Check | Result | Gate |
|---|---|---|
| GPU vs CPU oracle, 10 synthetic pairs (4 kinds, odd sizes 97×61 … 1031×517, 4:2:0/4:4:4, d 0.6 … 6, identical pair) | max \|Δ\| 0.0046 (identical pair exactly 100) | ≤ 0.02 |
| GPU vs CPU, 2 sample photos at 1280 px × d 1.0/2.5 | max \|Δ\| 0.0007 | ≤ 0.02 |
| GPU vs CPU, full 45 MP (0110, jpegli d2.0) | 72.453490 vs 72.453703, Δ 2.1e-4 | ≤ 0.02 |
| New port vs old port, 19 holdout outputs, identical pixels (both decoded by ImageIO; old = `squeeze score`) | max \|Δ\| 0.00028 | ≤ 0.05 |
| New port vs the old engine's own scores (`old-holdout-ownscores.txt`, one decimal), candidate decoded like the old engine (libjpeg-turbo) | max \|Δ\| 0.046 | ≤ 0.05 (+0.05 rounding) |
| Monotone on a jpegli ladder d 0.3 … 13, two images | strictly decreasing | monotone |
| Determinism: 8 concurrent scores, a second reference of the same geometry | bit-identical | — |

Tests: `Tests/HMBEngineTests/Primitives/MetricAgreementTests.swift`, `MetricHoldoutTests.swift` (needs
`HMB_HOLDOUT`; comparison A needs `djpeg` on PATH or `HMB_DJPEG`), `MetricPerformanceTests.swift` (opt-in).

## 4. Finding: the candidate decoder moves the scale

The old engine decoded its **candidates** with libjpeg-turbo (`sq_jpeg_decode`) and the source with ImageIO. v2 decodes
both with ImageIO (SPEC E6). The decoders differ (Apple vs libjpeg-turbo: RMSE 0.43 on a 45 MP 4:2:0 candidate, 9 % of
samples off by 1), and SSIMULACRA2 notices. Same 19 holdout outputs, same reference, three decoders:

| Photo | old engine own score | old port, ImageIO (`squeeze score`) | new port, ImageIO | new port, libjpeg-turbo | new port, jpegli decoder |
|---|---|---|---|---|---|
| 0014 | 74.1 | 73.76933 | 73.76932 | 74.06843 | 75.832 |
| 0042 | 75.4 | 75.03329 | 75.03330 | 75.44330 | 76.338 |
| 0070 | 74.4 | 74.04905 | 74.04901 | 74.35439 | 75.591 |
| 0098 | 74.7 | 74.33147 | 74.33142 | 74.67088 | 75.695 |
| 0126 | 74.6 | 74.37944 | 74.37962 | 74.56501 | 76.204 |
| 0154 | 74.4 | 74.15319 | 74.15313 | 74.38734 | 75.669 |
| 0182 | 74.6 | 74.47130 | 74.47137 | 74.62681 | 75.896 |
| 0210 | 74.3 | 74.03606 | 74.03609 | 74.32230 | 75.889 |
| 0238 | 74.3 | 74.00188 | 74.00192 | 74.30098 | 75.979 |
| 0266 | 74.4 | 74.12875 | 74.12878 | 74.35379 | 75.612 |
| 0294 | 74.3 | 74.09524 | 74.09547 | 74.25747 | 76.292 |
| 0322 | 74.7 | 74.33538 | 74.33536 | 74.66615 | 76.380 |
| 0350 | 74.3 | 74.12125 | 74.12110 | 74.34334 | 76.186 |
| 0378 | 74.8 | 74.51176 | 74.51159 | 74.78593 | 76.749 |
| 0406 | 74.5 | 73.87549 | 73.87554 | 74.48595 | 74.504 |
| 0434 | 74.2 | 73.83971 | 73.83975 | 74.22955 | 75.845 |
| 0462 | 74.3 | 73.97416 | 73.97435 | 74.27727 | 75.655 |
| 0490 | 74.2 | 73.99790 | 73.99788 | 74.23545 | 76.189 |
| 0518 | 74.5 | 74.30135 | 74.30163 | 74.53876 | 76.810 |

max |new − old port| (same pixels): 0.00028; max |turbo path − own score|: 0.0462 (own scores have one decimal)
ImageIO − turbo: mean -0.290, min -0.610, max -0.155
jpegli − turbo: mean +1.495, min +0.018, max +2.271

What this means:
- The port itself is exact (column 3 vs 4). The **floors (74…87, 85, 70) were set on the libjpeg-turbo reading** (the
  old engine's own scores, DATENLAGE). Under ImageIO the same bytes read **0.29 lower on average (0.16 … 0.61)**.
- Bytes: from the jpegli equivalence runs (6 samples, d 1.6 → 2.0) one score point costs **6.7 % bytes** (4.5 … 8.7 %).
  Holding the floors with ImageIO decode therefore costs about **+1.9 %** bytes against the old engine at equal
  nominal targets. G1's margin is +1.0 % (50.31 MB vs 49.81 MB): **G1 is at risk from this alone.**
- ImageIO is the conservative choice of the three: it reads lowest, so a file that passes under ImageIO passes under
  libjpeg-turbo (browsers, most web tools). jpegli's own decoder reads 1.5 points higher; it would be anti-conservative
  for every common viewer and must not be used for verification.
- **Decided (2026-10-15, Docs/DECISIONS.md D-ENG-1/2): option (a).** ImageIO stays; G1 is measured against the old
  engine held to the v2-measured floor (re-run at raised targets: 50,301,670 bytes, +1.0 % over its Classic output).
- Options for the lead (WP1 has not changed E6): (a) keep ImageIO and accept/re-baseline G1 (+~2 %); (b) decode
  candidates the way the old engine did (libjpeg-turbo semantics: ISLOW IDCT + fancy upsampling). libjpeg-turbo is not
  vendored (E6 rejected it for speed and the symbol clash); jpegli's decoder *is* in the archive but reads +1.5, so it
  does not reproduce the old scale either. (a) is WP1's recommendation: the guarantee "score ≥ floor" then holds for
  the Apple decoder and, with margin, for libjpeg-turbo.

## 5. Performance

Release build (`swift test -c release -Xswiftc -enable-testing`, opt-in `HMB_METRIC_BENCH=1`), sample 0110,
8256×5504, candidate = jpegli d2.0 4:2:0, ImageIO-decoded.

| Item | Result | Budget | Machine |
|---|---|---|---|
| **Score, 45 MP candidate, cached reference** (median of 10) | **0.046 s** wall (GPU 0.043 s), min 0.046, max 0.047 | ≤ 0.40 s (stretch 0.25) | load 6.55 11.42 16.23 |
| same, earlier run | 0.047 s (GPU 0.043 s) | | load 9.46 19.13 20.07 |
| same, debug build | 0.070 s (GPU 0.043 s) | | load 9.98 20.60 20.61 |
| **Reference preparation, 45 MP** (median of 5) | **0.008 s** (GPU 0.005 s) | ≤ 0.20 s | load 6.55 11.42 16.23 |
| Cold (pools drained: fresh buffers, page faults) | prepare 0.053 s, score 0.083 s | — | load 6.55 11.42 16.23 |
| CPU oracle, 45 MP (release) | 3.2–3.5 s | never on the hot path | load 6.9–9.4 |

The GPU time (0.043 s) did not move between load 6 and load 24: the other engineers' load is CPU, not GPU. The budget
is met by a factor of ~8.5; the stretch goal (0.25 s) by ~5. Old port for comparison: 0.87 s per 24 MP score without a
session (DATENLAGE), roughly 1 s per 45 MP with one.

Memory per 45 MP geometry: reference 0.73 GB (live, until `release`), working set 0.72 GB (pooled, one per geometry by
default), spare reference 0.73 GB (pooled, one per geometry by default; `referenceRetention: 0` saves it for ~35 ms
per photo). `drainPools()` frees all pooled buffers.

**Consequence for the budget (§3.11):** with the metric at ~0.05 GPU-s per full probe, a Balanced photo needs about
2 × 0.05 + 3 mosaic probes ≈ 0.12 GPU-s. The pipeline is now **CPU-bound**: per full probe, jpegli p2 encode 0.39 s
plus ImageIO decode of the candidate 0.28 s (§6), i.e. ~1.3 CPU-s per photo for two probes plus the source decode.

## 6. Other primitive timings (45 MP sample 0110, release, median of 3, load 4.4–4.7 / 11 / 16)

| Primitive | Time |
|---|---|
| inspect (header walk, memory-mapped) | 0.003 s |
| ImageIO decode, source (baseline) | 0.178 s |
| ImageIO decode, jpegli candidate (progressive) | 0.278 s |
| features (textureP50 + chromaEnergy) | 0.004 s (budget 0.05 s) |
| resize → 2560 / → 1440 (Lanczos) | 0.104 s / 0.117 s |
| mosaic 2048×1024 | 0.002 s |
| sRGB conversion, Display P3 → sRGB, 45 MP | 0.016 s |
| jpegli encode d2.0, p2, 4:2:0 / 4:4:4 | 0.388 s / 0.604 s |
| WebP 2560: prepare (sharp YUV) / encode q75 m4 | 0.173 s / 0.267 s |
| JXL transcode e7 / reconstruct (1 thread) | 1.751 s / 1.082 s (−22.5 %) |

## 7. Re-running

```bash
source "$HOME/Library/Application Support/holdmybyte-dev/env.sh"
swift test --filter "MetricAgreementTests|MetricHoldoutTests|JpegliEquivalenceTests"
HMB_METRIC_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter MetricPerformanceTests   # quiet machine
```
