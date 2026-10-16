# Variant "highest": a high-target JPEG mode inside jpegli

Branch `eng-highest` (worktree `hmb-eng-highest`), base `main` 66e3db0 (merged eng-v3). 2026-10-16, MacBookPro18,4
(M1 Max, 10 cores, 64 GB), shared with other agents and never quiet (load in every timing row; no timing here is a gate
number). Decision record: Docs/DECISIONS.md D-ENG-12; how it works: Docs/ENGINE.md §3.2.

Quality is always v2's metric on the delivered bytes: ImageIO decode of source and file, Metal SSIMULACRA2. No floor
and no metric was changed. "turbo" = both source and file decoded by libjpeg-turbo 3.2 `djpeg` (islow IDCT), then the
same metric (`HighestLabTests/turboPairs`); reported for every delivered file as the second-decoder check research F4
asks for.

## 1. Result

**Highest (full size, ≥ 90), holdout 19, release `hmb compress`, back to back with main:**

| | main 66e3db0 | **eng-highest** | JPEGmini 3.4.1 (research §2.1) | research F1 (libjpeg-turbo Annex K, baseline) |
|---|---|---|---|---|
| Bytes | 191,497,771 | **182,337,941 (−4.78 %)** | 190,997,000 | 176,340,000 |
| Lowest score, ImageIO | 90.019 | **90.011** | 79.10 | ≥ 90.0 |
| Lowest score, libjpeg-turbo | 89.81 (median 90.08) | **89.82** (median 89.98) | — | — (its files read 0.35–0.8 lower in turbo, §3) |
| Probes per photo | 2.26 | 2.74 | — | — |
| Wall (2 runs) | 16.7 / 16.5 s | 19.9 / 21.4 s (+24 %) | | |
| CPU (2 runs, other pair) | 78.6 / 77.0 s | 101.4 / 100.9 s (+30 %) | | |
| Peak footprint / RSS | 5.18–5.41 / 3.49–3.56 GB | 5.20–5.37 / 3.53–3.70 GB | | |

Load (1 min) 6.2–11.1 across the pairs. All 19 deliveries are `jpegli (high)`, 15 at 4:2:0 and 4 at 4:4:4; repeats
byte-identical. 12 of 19 files are smaller than JPEGmini's, whose files score 79.1–91.5; on the 9 photos where JPEGmini
reached ≥ 90 (90.15–91.45), eng-highest delivers 83.1 MB against JPEGmini's 105.4 MB (0.79×).

**High (full size, ≥ 85), holdout:** 102,245,961 → **98,776,135 B (−3.39 %)**, probes 2.00 → 1.74, min 85.014 / 85.004,
turbo min 84.88 / 84.85 (medians 85.06 / 85.04), wall 12.1 / 12.4 s → 10.3 / 10.2 s.

**Unchanged deliveries:** Couple, Website, Social, Archive on the holdout: 76/76 files SHA-256-identical to main. With
`HMB_HIGH=off`, Highest and High are byte-identical to main (19/19 each).

**Full wedding, Highest** (535 × 45 MP, one run each, back to back): see §5.

## 2. What changed

1. **jpegli bridge** (`hmb_jpegli_options.standard_tables`, `JPEGKnobs.standardTables` / `.sequential`): Annex K tables
   via `jpegli_use_standard_quant_tables` (linear scale 22.2 × (d − 0.1) %, luma + one shared chroma table), and
   sequential (baseline) coding, also for scoring-only mosaic candidates (a mosaic must be coded like the delivery,
   because ImageIO decodes the two modes differently). Every existing call is byte-identical (the new fields default
   to off).
2. **High-target mode** (`SearchConstants.highTuning = JPEGTuning.highTarget`): `fullSize`'s table shape (chroma × 0.65,
   luma tilt 1.6, DC × 0.8) **with adaptive quantisation off**, progressive, scan script per subsampling as before.
   `MosaicSearch.searchHigh`: 4:2:0 first; from `high444From` = 89 also 4:4:4, unless a mosaic preselection rules it out
   (the 4:2:0 probe's measured bias aims 4:4:4 on the mosaic; skipped when its mosaic bytes are > 3 % above the passing
   4:2:0 point's); the smaller verified result wins. Own priors (`Targets.highPrior`), bias prior −0.3, rescue floor 0.3.
3. **Policy** (`SearchConstants.highMode(target:)`): full-size JPEG at a **fixed floor** (not Balanced, so Couple's
   Package is untouched) uses the high mode from `highFirstFrom` = 85; the tuned search runs only if the high mode reaches
   nothing. `highCompareFrom..<highFirstFrom` is the compare band (both searches, smaller verified result); by default it
   is empty because at 85 the compare found nothing (98,773,489 vs 98,776,135 B for 3.74 vs 1.74 probes, §4.3).
4. Pipeline: a second oracle on the same mosaic and reference, mosaic results cached per (subsampling, distance);
   encoder name `jpegli (high)`. Estimator: the high mode's mosaic estimate (smallest of the modes the search compares).
   `hmb` switches: `HMB_HIGH=off`, `HMB_HIGH_BAND=<compare from>,<first from>`, `HMB_HIGH_TABLES=annexk`,
   `HMB_HIGH_SCAN=baseline`.

## 3. Why not Annex K, and why not baseline

The task was research F1: Annex K tables at 4:4:4, scaled per photo, −15 % at Highest with libjpeg-turbo. In jpegli,
frontier survey (`HighestLabTests/frontier`: per photo the largest distance reaching 90 with the Highest markers,
bisection to 0.004 in ln d; main's knob reaches 102.21 MB at 85 on this survey vs 102.25 MB for main's real search, so
frontier and real search are comparable):

| Setting (jpegli, holdout, T = 90) | Bytes | vs main 191.50 MB | turbo min / median |
|---|---|---|---|
| Annex K, 4:4:4, AQ off, progressive | 197.37 MB | +3.1 % | 90.01 / 90.30 |
| Annex K, 4:4:4, AQ off, **baseline** | 185.19 MB | −3.3 % | **89.04** / 89.54 |
| Annex K, 4:4:4, AQ on, baseline | 191.65 MB | +0.1 % | 89.33 / 89.62 |
| Annex K, 4:4:4, AQ off, baseline, DC × 0.8 / chroma × 0.8 / tilt 0.8 | 183.32 / 183.65 / 187.06 MB | −4.3 / −4.1 / −2.3 % | 89.2–89.3 / 89.5 |
| jpegli tables, 4:4:4, AQ off, baseline | 197.54 MB | +3.2 % | 89.13 / 89.65 |
| `fullSize` shape, 4:4:4, AQ on, progressive (main's fail-open) | 191.92 MB | +0.2 % | 89.93 / 90.16 |
| `fullSize` shape, 4:4:4, AQ off, baseline | 174.18 MB | −9.0 % | **89.22** / 89.46 |
| `fullSize` shape, 4:4:4, AQ off, progressive | 186.95 MB | −2.4 % | 89.94 / 90.17 |
| `fullSize` shape, 4:2:0, AQ off, progressive | 184.04 MB | −3.9 % | 89.82 / 89.95 |
| **smaller of the two rows above per photo** | **181.46 MB** | **−5.2 %** | ≥ 89.82 |

Other progressive shapes (AQ off, 4:4:4): chroma 0.5 / 0.8, tilt 0.8 / 2.4, DC 0.6 at chroma 0.65 tilt 1.6: 185.8–188.4 MB
(the ±1 % differences are inside what 19 photos can resolve; `fullSize`'s shape was kept rather than tuning a new one on
the metric that judges it).

**Annex K loses in jpegli.** At identical tables (0014, Annex K × 0.17) jpegli gives 8,061,597 B at 90.05 and
libjpeg-turbo `cjpeg` (from the same ImageIO decode) 8,212,685 B at 90.43: libjpeg's integer DCT reconstructs this
material better per byte, worth about 3–5 % (cjpeg bisected to 90 from the ImageIO decode: 0014 7.62 MB, 0518 7.83 MB,
0154 12.25 MB; jpegli Annex K baseline 8.11 / 8.50 / 12.73 MB). It is not jpegli's AC dead zone: a test patch that
rounds plainly with standard tables (`InitQuantizer`, zero-bias offset 0) moved Annex K baseline by −0.02 % and the
`fullSize` rows by −0.2…−0.6 %, so it was dropped (no codec change on this branch; the pin stays `3e81407d…`). jpegli's own
table shape does better than Annex K in every mode, and the best jpegli setting (174.18 MB baseline / 181.46 MB
progressive) already matches or beats the libjpeg-turbo number of F1 (176.34 MB) on the same gate, so **no second
encoder is needed**: what F1 measured is mostly 4:4:4 + no AQ + baseline, not the Annex K table.

**Baseline is a decoder effect, not a better encoding (research F4).** The same coefficients read about 1 point higher
in ImageIO when coded baseline (the source is baseline, and ImageIO decodes baseline and progressive differently). Two
other decoders on four photos (frontier files at ImageIO ≈ 90.0):

| File | Bytes | ImageIO | libjpeg-turbo islow | libjpeg-turbo float IDCT |
|---|---|---|---|---|
| 0014 baseline 4:4:4 AQ off | 7,503,348 | 90.04 | 89.22 | 89.26 |
| 0014 progressive 4:4:4 AQ off | 8,433,952 | 90.03 | 90.08 | 90.12 |
| 0014 main | 8,709,218 | 90.14 | 89.97 | 90.01 |
| 0154 baseline / progressive / main | 12.49 / 13.05 / 13.84 MB | 90.01 / 90.15 / 90.15 | 89.50 / 90.23 / 90.25 | 89.55 / 90.28 / 90.29 |
| 0350 baseline / progressive / main | 7.52 / 8.99 / 8.94 MB | 90.01 / 90.04 / 90.07 | 89.46 / 90.47 / 90.25 | 89.51 / 90.51 / 90.29 |
| 0518 baseline / progressive / main | 7.92 / 8.88 / 9.09 MB | 90.01 / 90.03 / 90.09 | 89.48 / 90.33 / 90.30 | 89.52 / 90.38 / 90.34 |

libjpeg-turbo and an (almost) exact float IDCT agree within 0.05; ImageIO's baseline reading is the outlier, +0.5…+0.8.
Delivering baseline would break D-ENG-2's premise that ImageIO is the low reading: the real pipeline with
`HMB_HIGH_SCAN=baseline` gives **175,029,548 B (−8.6 %)**, all 19 at 4:4:4, ImageIO min 90.003, but libjpeg-turbo
89.22–89.80 (median 89.50; every file below 90). The default therefore stays progressive, where both decoders agree as
they do for main (turbo − ImageIO −0.21…+0.25). Baseline remains a switch for an owner decision (§6). The research F1
files passed the two-decoder check only because `cjpeg` was fed libjpeg-turbo's own decode of the source.

`HMB_HIGH_TABLES=annexk` in the real pipeline (Annex K in the high mode, both subsamplings, progressive):
198,512,917 B (+3.7 % vs main), all 4:4:4, turbo 90.01–90.65.

## 4. Search details

### 4.1 Priors and bias

Holdout frontier medians of the distance reaching T: 4:2:0 AQ off 0.39 at 90 / 0.89 at 85, 4:4:4 0.50 / 1.07
(`Targets.highPrior`). Full − mosaic bias at the frontier: median −0.27 / −0.37 (4:2:0), −0.21 / −0.38 (4:4:4), range
−0.98…+0.15 → `highBiasPrior` −0.3 (the tuned search's −1.1 belongs to AQ on). 4:4:4 minus 4:2:0 bias: median +0.03,
sd 0.13, so the measured 4:2:0 bias aims the 4:4:4 search.

### 4.2 When 4:4:4

Frontier, per-photo smaller of 4:2:0 and 4:4:4 (AQ off) vs 4:2:0 alone: 85: 0 % (4:4:4 never smaller), 88: −0.08 %
(one photo), 90: −1.4 % (5 photos) → `high444From` = 89. Mosaic bytes at the two frontier points predict the full-size
4:4:4 / 4:2:0 ratio within ±1.5 % (19 photos at 88 and 90), hence the preselection with a 3 % margin. Real pipeline:

| Highest, holdout | Bytes | Probes | 4:4:4 | Mosaic evals |
|---|---|---|---|---|
| both subsamplings always | 182,426,314 | 3.68 | 6 | — |
| **with the mosaic preselection** | **182,337,941** | **2.74** | 4 | 444 (main: 272) |

### 4.3 The compare band

At 85 (High) the compare band (tuned AQ-on search and high mode, smaller verified result) delivered 98,773,489 B with
3.74 probes vs 98,776,135 B with 1.74 for the high mode alone (one photo of 19 from the tuned search, −2.6 KB); at 85
the high mode's 4:2:0 AQ off beats the tuned search's frontier on all 19 photos (98.64 vs 102.21 MB). Balanced targets
(≤ 85.2) are not in the high mode at all. The band is configurable (`highCompareFrom`, `HMB_HIGH_BAND`) and empty by
default.

### 4.4 Estimator

`hmb estimate` (12 samples), actual / estimate: Highest 182.34 / 177.0 MB = 1.030 (main 191.50 / 181.7 = 1.054), High
98.78 / 94.6 = 1.044 (main 102.25 / 106.7 = 0.958). κ stays 1.0.

## 5. Full wedding, Highest

WEDDING_PLACEHOLDER

## 6. Open (owner)

- **Baseline for the high mode** (`HMB_HIGH_SCAN=baseline`): −8.6 % more on the holdout's Highest, every file ≥ 90 on
  v2's metric but 89.2–89.8 under libjpeg-turbo (browsers, most non-Apple software) and under an exact IDCT. JPEGmini
  ships baseline and profits from the same ImageIO reading. Taking it means D-ENG-2's "ImageIO is the lowest reading"
  no longer holds for Highest; a fair alternative would be a second in-engine decoder (jpegli's) in the verification.
- **AQ off at other full-size targets**: at 85 it is −3.4 % with fewer probes; Balanced (74–85) was not tested here and
  Couple's Package stays byte-identical by construction. Worth a Couple survey (eng-search measured AQ on better for
  the tuned shape at 74, `Docs/variants/search.md`).
- Resized Highest/High deliveries (DirectSearch) are unchanged: they already run 4:4:4 without AQ from T 80.
- Tuned on 19 photos of one camera against the metric that judges it; the visual check below is one person on two photos.

## 7. Tests

`swift build` zero warnings. New: `HighModeSearchTests` (policy on analytic curves: off below the band, high mode
alone above it, tuned rescue when it reaches nothing, compare band picks the smaller verified result, 4:4:4 from
`high444From` and the mosaic preselection, switched off = tuned search), `HighModeCodecTests` (standard tables are Annex
K scaled from d, sequential is SOF0 and scoring-only keeps it, tunings unchanged), `HighModeLiveTests` (holdout Highest:
19/19 ≥ 90 in the high mode, ≤ 183,000,000 B, ≤ 0.96 × main, probes ≤ 3.2), opt-in `HighestLabTests` (frontier
survey with turbo reading, `djpeg` pair scoring, single encodes). TESTS_PLACEHOLDER
