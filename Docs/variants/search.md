# Variant "search": smarter rate control at the same verified floor

Branch `eng-search` (worktree `hmb-eng-search`), base `main` at d42cb2d. Owner of this report: search.
Every byte count below is the **delivered** bytes, scored by v2's own metric (ImageIO decode + Metal SSIMULACRA2)
inside the pipeline; the holdout Couple outputs were additionally re-scored file by file with `hmb score` (identical
to the pipeline's scores, min 74.020). No floor and no metric were touched.

## Result

Two changes, both table/sampling choices of the existing one-parameter searches (no extra probes, no new search
loop):

1. **Full-size JPEG (MosaicSearch: Couple's Package, High/Highest full):** jpegli's quantisation tables reshaped as
   `JPEGTuning.fullSize` = chroma tables at 0.65 × d, every DC entry at 0.8 × d, luma AC at radial frequency
   f = row + col ≥ 4 multiplied by exp(1.6 · (f − 3)/11) (up to ×4.95 at f = 14). Same tuning in the mosaic proxy and
   the estimator, so the search and κ stay calibrated.
2. **Resized JPEG (DirectSearch: Social, WebP→JPEG fallback, full-size images < 2048×1024):**
   `JPEGTuning.resized` = chroma 0.7 × d, adaptive quantisation off; `direct444From = 80`: targets ≥ 80 search
   4:4:4 directly (4:2:0 is not even searched), targets < 80 keep the §3.5 order.

### Measured (release `hmb compress`, A/B back to back in one session)

Holdout, 19 photos (`$HMB_HOLDOUT`), two repeats each, outputs of the repeats byte-identical:

| Run | Delivery | Bytes | vs base | Min / median score | Probes mean / max | Wall | CPU user + sys | Peak footprint | 1-min load before → after |
|---|---|---|---|---|---|---|---|---|---|
| base d42cb2d | Couple | 50,239,686 | — | 74.007 / 74.105 | 1.95 / 3 | 24.6 s, 27.2 s | 48.4 s, 49.7 s | 3.76 GB, 3.89 GB | 13.9 → 17.3, 19.3 → 20.4 |
| **search** | Couple | **48,523,486** | **−3.42 %** | 74.020 / 74.090 | **1.84** / 3 | 24.9 s, 25.1 s | 46.7 s, 47.1 s | 3.81 GB, 3.81 GB | 17.3 → 19.3, 20.4 → 19.9 |
| base | Social | 6,015,880 | — | 85.006 / 85.264 | 3.95 / 8 | 3.4 s, 3.3 s | 9.4 s, 9.1 s | 2.03 GB, 2.04 GB | 118 → 114 |
| **search** | Social | **5,540,379** | **−7.90 %** | 85.101 / 85.305 | **2.63** / 5 | 3.8 s, 2.7 s | 8.2 s, 8.2 s | 1.77 GB, 2.17 GB | 114 → 106 |
| base | all four | C 50,239,686 · W 6,265,646 · S 6,015,880 · A 312,351,208 | — | | | 40.3 s, 48.9 s | 142.0 s, 143.2 s | 7.11 GB, 6.94 GB | 49 → 60, 56 → 65 |
| **search** | all four | C 48,523,486 · W **identical** · S 5,540,379 · A **identical** | −0.58 % total (lossy −3.5 %) | | | 36.7 s, 51.9 s | 137.4 s, 139.2 s | 7.04 GB, 7.02 GB | 60 → 56, 65 → 75 |

Website and Archive outputs are SHA-256-identical to the baseline (their code paths are untouched).

Full wedding (535 × 45 MP, `$HMB_WEDDING` read-only, Couple + Social in one run; **announced full-wedding run**,
machine heavily loaded by the other agents, so timings are upper bounds and only the relative order counts):

| Run | Couple bytes | Social bytes | Min / median (C) | Min / median (S) | Probes C / S | Wall | CPU user + sys | Peak footprint | Load before → after |
|---|---|---|---|---|---|---|---|---|---|
| base | 1,352,439,246 | 163,455,205 | 74.000 / 74.111 | 85.001 / 85.192 | 1.96 / 4.04 | 755.7 s | 1220 + 312 s | 4.35 GB | 73.2 → 85.3 |
| **search** | **1,308,497,173 (−3.25 %)** | **148,856,757 (−8.93 %)** | 74.000 / 74.109 | 85.000 / 85.296 | 1.95 / 3.03 | 628.7 s | 1115 + 260 s (−10 %) | 4.30 GB | 85.3 → 56.2 |

0 below target, 0 failed, 0 kept-original in every run. Time: no cost; CPU is lower (fewer Social probes, 4:2:0
fail-open searches gone, slightly smaller Couple files to decode). Goal (holdout ≤ −3 % at equal floor, ≤ +20 %
time) is met at zero time cost.

## How it was found

### Tools (committed, opt-in)

- `hmb_jpegli_encode_opts` (`Sources/CHMBCodecs/jpegli.cc`, header `hmb_codecs.h`): separate chroma distance, 4:2:2,
  adaptive quantisation on/off, luma/chroma high-frequency tilt, DC ratio. All tables come from jpegli's own
  `jpegli_set_distance` at the respective distances (same base matrices, same 4:2:0 rescale, baseline-clamped ≤ 255);
  jpegli's quantiser derives zero bias and AQ from the final tables. `hmb_jpegli_encode` is now this call with every
  knob neutral and is **byte-identical** to before (holdout outputs identical; `JpegliEquivalenceTests` green).
- `KnobSurveyTests` (`HMB_KNOBS`, `HMB_KNOBS_OUT`, optional `HMB_KNOBS_EDGE`, `HMB_KNOBS_TARGET`): per photo and
  knob set, the largest passing luma distance found by bracketing + bisection to 0.01 ln d ("frontier"), plus the
  bytes interpolated in log space to exactly T ("interp", removes jpegli's step noise).
- `SearchABTests` gained `cr`, `lt`, `ct`, `dcr`, `jpegli`; `DirectSearchABTests` gained `from444`, `cr`, `aq`, `jpegli`.

### Full-size, holdout (19 × 45 MP, Balanced T = 74), frontier totals vs jpegli 4:2:0 (50.256 MB; interp 49.951 MB)

| Knob set | interp | frontier |
|---|---|---|
| 4:4:4 / 4:4:4 chroma ×1.5 / ×2 / ×3 | +7.2 / +14.2 / +22.5 / +40.8 % | +7.2 … +40.3 % |
| 4:2:2 chroma ×1.5 | +22.1 % | +22.4 % |
| 4:2:0 chroma ×1.25 / ×1.5 / ×2 (coarser chroma) | +1.8 / +3.4 / +7.8 % | |
| 4:2:0 chroma ×0.8 / 0.7 / 0.6 / 0.5 (finer chroma) | −1.1 / −1.7 / −1.8 / −1.5 % | |
| AQ off | −0.4 % | −0.2 % |
| AQ off + chroma 0.65 | −1.6 % | −1.7 % (no gain over chroma alone) |
| luma tilt +0.3 / +0.6 / +1.0 / −0.3 | −0.5 / −1.0 / −1.3 / +0.7 % | |
| chroma 0.65 + tilt 0.6 / 1.2 | −2.5 / −2.9 % | −2.2 / −2.9 % |
| chroma 0.65 + tilt 0.6 + DC 0.8 / DC 1.25 | −3.0 / −1.2 % | −2.7 / −1.5 % |
| chroma 0.65 + tilt 1.2 + DC 0.8 / DC 0.65 | −3.2 / −2.8 % | −2.9 / −2.7 % |
| **chroma 0.65 + tilt 1.6 + DC 0.8 (shipped)** | **−3.35 %** | **−3.40 %** |
| chroma 0.65 + tilt 2.0 + DC 0.8 | −3.4 % | −3.3 % |
| shipped + chroma tilt 0.6 | −3.4 % | −3.6 % |
| shipped + AQ off / 4:4:4 + AQ off | −3.1 % / +2.1 % | |

Checks of the shipped point outside the holdout:
- **Validation set** (19 other wedding photos, 0007 + 28k, never used for tuning): tilt 1.2: −3.5 % interp,
  tilt 1.6: **−3.6 %** interp / −3.7 % frontier.
- **T = 85 at full size** (custom High): tilt 1.2: −6.8 %, tilt 1.6: **−6.6 %**.
- **Real search A/B** (`SearchABTests`, MosaicSearch unchanged, 19/19 ≥ 74): jpegli 50.240 MB / 1.95 probes;
  tilt 1.2: 48.795 (−2.9 %); tilt 1.4 + chroma 0.7: 48.688; **tilt 1.6: 48.523 MB, 1.84 probes, overshoot 0.128**;
  tilt 2.0: 48.651; tilt 1.6 + DC 0.7: 48.696; tilt 1.6 + chroma 0.7: 48.691; + chroma tilt 0.6: 48.506; stop 0.1:
  no change. The shipped point sits in a flat region (±0.1 MB).
- The mosaic bias (full − mosaic at equal d) is unchanged by the tuning (median −1.03 vs −1.03), the landing distance
  moves from d ≈ 1.90 to 2.12 (median), inside the prior's bracket — no constant of the search needed retuning.

Per-photo choice by the mosaic proxy (encode the mosaic with every knob set at T + 1.1, take the fewest bytes) was
tested in every batch: it always came out below the oracle but **never beat the best fixed knob set** (batch 5:
mosaic-picked −2.97 % vs fixed −3.35 %): per-photo differences between good knob sets are mostly jpegli's step
noise, which a 2 MP mosaic cannot see. Not shipped; fixed tuning costs nothing.

Why it works (reading, not proven): SSIMULACRA2 on ImageIO-decoded output weights chroma error and smooth-area DC
precision more than jpegli's butteraugli-tuned tables assume, and at 45 MP the highest luma frequencies are mostly
sensor noise that the multi-scale metric barely rewards. Coarsening them pays for finer chroma, DC and lower luma
distance.

### Resized (DirectSearch), holdout variants (sRGB, Lanczos), frontier vs jpegli 4:2:0

| Size / T | full-size tuning | 4:2:0 chroma 0.65 | 4:2:0 chroma 0.7 + AQ off | 4:4:4 chroma 0.65 | **4:4:4 chroma 0.7 + AQ off** |
|---|---|---|---|---|---|
| 1440 / 85 (Social; 16 photos where 4:2:0 passes) | +3.0 % | −2.0 % | −6.8 % | −8.9 % | **−12.4 %** (c0.8: −12.7, c0.5: −10.9) |
| 1440 / 74 | | | **−5.8 %** | | −3.7 % |
| 2560 / 70 (WebP fallback) | | | **−2.9 %** | | +4.6 % |
| 1024 / 85 (13 photos) | | | −6.2 % | | **−7.2 %** |
| 1440 / 90 | | | 4:2:0 passes 0/19 photos | | 19/19 pass |

Hence: chroma 0.7 + AQ off for every resized JPEG, 4:4:4 first from T ≥ 80 (4:2:0 first below). Real-search A/B
(`DirectSearchABTests`, Social): jpegli 6.016 MB / 3.95 probes → **5.540 MB / 2.63** (chroma 0.8: 5.522 / 2.37;
0.6: 5.575; stop 0.3: 5.492 / 3.21; stop 0.7: 5.584 / 2.26). Website (WebP) unchanged.

### Ideas tested and dropped

- **4:4:4 / 4:2:2 at full size:** +7 % / +22 % even with chroma relief; 4:2:0 stays (E1/E2 confirmed).
- **Coarser chroma (2-D search towards chroma > luma):** loses everywhere; the useful direction is the opposite.
- **AQ off at full size:** ≈ 0 to −0.4 %, nothing on top of the tuning. (At ≤ 2560 px it is a large win.)
- **Landing closer to the floor:** the shipped search already lands at mean overshoot 0.128 (tuned); stop 0.1 changed
  nothing; the remaining gap to the interpolated bound is ≈ 0.3 %, and the step sizes of the tables (DC 0.8 makes
  them smaller) are what limits it. A chroma-only fine step after the last probe would need a full probe (~0.8 s)
  for ≤ 0.5 %: not worth +40 % Couple time.
- **Per-photo knob choice on the mosaic:** see above, no gain over the fixed tuning.
- **Content-adaptive start:** the mosaic solver already places probe 1; with the tuning the mean full probes dropped
  1.95 → 1.84 without touching the prior.

## What competitors do, and what was borrowed

- **JPEGmini (Beamr):** per-image re-encoding until a proprietary blockiness-centred quality measure (block-edge
  artefacts + PSNR-like terms, Beamr patents) says "same"; per-image quant-table scaling. Borrowed: per-image
  rate control against a perceptual floor (we already do), table shape as a lever. Not borrowed: their metric or
  their table-averaging step (see risks).
- **Guetzli (Google):** butteraugli-guided search over quantisation tables plus per-block coefficient zeroing, ~1 min
  per MP. Borrowed: the table *shape* is a free parameter worth optimising for the target metric (here once, offline,
  on SSIMULACRA2, then fixed: zero run-time cost). Coefficient-level search is far outside our time budget.
- **mozjpeg / Squoosh defaults:** q 75, 4:2:0, progressive, trellis quantisation, optimised scans, and a separate
  chroma quality option. Borrowed: separate chroma quality (our chroma ratio). Trellis is not available in jpegli;
  AQ is jpegli's analogue, and turning it off helps only on downscaled images for this metric.
- **jpeg-recompress (jpeg-archive), TinyJPG, Kraken, Optimizilla:** quality bisection against SSIM/MS-SSIM/"smallfry"
  (a JPEGmini-like metric) or proprietary heuristics; Optimizilla adds a manual slider. Our verified search is
  already stricter (every delivered file is scored); nothing further to borrow.
- **jpegli itself:** its tables and AQ are tuned for butteraugli at distance d; nothing in the format requires them.
  Every tuned file here is a standard progressive JPEG with ordinary 8-bit DQT tables.

## What is worth merging

Both commits on `eng-search`, in order:

- `6950cff` Full-size JPEG: tuned quantisation tables — `Sources/CHMBCodecs/{jpegli.cc, include/hmb_codecs.h}`,
  `Sources/HMBEngine/Codecs/JpegliEncoder.swift` (`JPEGKnobs`, `TunableJPEGEncoding`, `encode(…tuning:…)`),
  `Sources/HMBEngine/Search/SearchModel.swift` (`JPEGTuning`, `SearchConstants.jpegTuning/directJPEGTuning`),
  `Sources/HMBEngine/Pipeline/PhotoPipeline.swift`, `Sources/HMBEngine/Estimate/Estimator.swift`; tests
  `CodecTests.jpegTuningIsStandardAndIdentityIsUnchanged`, `KnobSurveyTests`, `SearchABTests`.
- `d96447f` Resized JPEG: chroma 0.7, AQ off, 4:4:4 first from T 80 — `SearchModel.swift`, `DirectSearch.swift`,
  tests `SearchTests` (`directJPEGSearchesFourFourFourFirstAtHighTargets`, updated floor test),
  `DirectSearchABTests`.
- this report.

`Primitives.swift` (frozen protocol) is untouched: the knobs go through a separate `TunableJPEGEncoding` protocol;
fakes and the identity tuning use the frozen call. `swift build` has no warnings; the full `HMBEngineTests` suite
passes with `env.sh` sourced (137 tests, incl. `LiveEngineTests`: holdout gate, live determinism, estimator).

Docs to update on merge (lead): ENGINE §3.1/§3.3 (tuning, 4:4:4-first rule), SPEC E1/E2/E3 deviation note
("adaptive quantisation on" no longer holds for resized JPEG; 4:4:4 is no longer only fail-open for T ≥ 80
resized), a DECISIONS entry, and the G1/G5 baselines (Couple and Social bytes drop).

## Risks

- **Tuned against the metric that judges it.** The tables trade luma high frequencies (texture, grain) for chroma,
  DC and lower-frequency precision because SSIMULACRA2 + ImageIO decode reward that. Every file still meets the floor
  on v2's metric, but a metric-specific optimum can sit on a metric blind spot. Recommend a visual A/B in Compare on
  a few grainy, textured and skin-tone photos before merging (the T = 85 gain of −6.6 % is where it would show).
- **One wedding, one camera.** Holdout and validation set are the same shoot (45 MP). The resized results suggest the
  gain depends on resolution / noise level: a 12–24 MP camera might see less, or the full-size tilt might cost bytes
  (the search still verifies, so the risk is bytes, not quality). Worth one survey run on a second camera's photos.
- **Resized rule is a threshold** (80) fitted on four (size, T) points; between 74 and 85 the better sampling is not
  measured. Balanced targets of small full-size images (75…87) fall on both sides.
- **4:4:4 Social files** are ~1.4× larger in decoded chroma planes; irrelevant for viewers, but tools that assume
  4:2:0 (none known) would see a different sampling.
- **Patent note** (cf. the Beamr note in project memory): the tuning does not average a scaled matrix with an original
  one; tables are jpegli's own formulas at other distances times a fixed frequency tilt. Low risk, but the "per-image
  quant table" family is Beamr's area; mention to counsel together with the existing note.
- **Estimator:** the full-size estimate encodes the mosaic with the same tuning and the resized estimate runs the
  real DirectSearch, so κ stays ≈ 1: live estimator test (holdout, all four) actual/estimate couple 1.002,
  website 1.024, social 1.026, archive 1.000. κ was not refitted.
