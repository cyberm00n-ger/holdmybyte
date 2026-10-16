# Engine v3: integration of the engine variants

Branch `eng-v3` (worktree `hmb-eng-v3`), base `main` at d42cb2d. Author: engine integrator, 2026-10-16. Decision
record: Docs/DECISIONS.md D-ENG-11. Machine: MacBookPro18,4 (M1 Max, 10 cores, 64 GB), shared with other agents, never
quiet; every timing carries its load and is an upper bound. Quality is always v2's own metric with v2's decoder
(ImageIO decode + Metal SSIMULACRA2) on the delivered bytes; no floor and no metric was touched.

## 1. What was merged

| Branch | Verdict | Reason (evidence in the branch's report) |
|---|---|---|
| `eng-speed` (5 commits) | **adopted, all** | Byte-identical outputs (SHA-256 holdout + wedding); Couple's Package −51…−59 % wall. |
| `eng-search` (3 commits) | **adopted, all** | Couple −3.4 %, Social −7.9 % at the same verified floor, no extra time; validated on 19 unseen photos (−3.6 %). |
| `eng-postpass` (4 commits) | **adopted, all** (lab tests opt-in) | Website −11.3 %, Social −3.4 %, Couple −0.25 %; lossless parts pixel-checked, lossy parts re-scored. |
| `eng-dct` | **rejected** (report copied to `Docs/variants/dct.md`) | DCT path +2.8 % / +4.5 % bytes, not faster, +0.5–1 GB; its chroma × 0.75 gain is inside `eng-search`'s chroma 0.65. |
| `eng-research` | docs only (`Docs/COMPETITORS.md`, `Docs/variants/research.md`) | No code. Highest 4:4:4 / Annex K idea is an open item (D-ENG-11). |

**Interactions resolved.** All three branches changed the jpegli bridge. `hmb_jpegli_encode_opts` is now the one C
entry: the tuned tables (search), `progressive_level = HMB_JPEGLI_SCAN_PROXY` (speed) and a `scan_choice` pointer
(post-pass) in one options struct; `hmb_jpegli_encode` and `hmb_jpegli_encode_scans` are thin wrappers, so the frozen
call is byte-identical. In Swift, `JPEGKnobs` carries `scoringOnly` (proxy script) and `scans`; the mosaic is encoded
tuned *and* in the proxy script (`encodeForScoring(…, tuning:)`), the post-pass picks its scan script from the
coefficients of that proxy mosaic (the choice does not depend on the input's script), and every full probe is encoded
tuned with that script. DirectSearch JPEG gets the resized tuning, the 4:4:4-first rule and then the post-pass.
New test `ScanScriptEquivalenceTests.tunedTablesDecodeToTheSamePixelsInEveryScript`: proxy, level 2 and the chosen
script decode to identical ImageIO pixels with both tunings (6 samples × mosaic/1440 × 4:2:0/4:4:4 × 3 distances,
144 pairs). WebP keeps the post-pass's method 6 + filter strength 40 / sharpness 7 after a visual check (below).

**Every part can be switched back** (`hmb` env for A/B runs; `SearchConstants` / `WebPTuning` in code):
`HMB_JPEG_TUNING=jpegli`, `HMB_DIRECT444=off`, `HMB_OPTIMIZE_SCANS=0`, `HMB_ZEROING=0`, `HMB_XMP_LAYOUT=verbatim`,
`HMB_WEBP=spec|m6|postpass`; speed knobs `HMB_FULL_SLOTS`, `HMB_DECODE_SLOTS`, `HMB_JXL_THREADS`.

## 2. Merge checks (holdout, release, SHA-256 per file)

| eng-v3 run | Compared with | Result |
|---|---|---|
| everything off (6 switches) | d42cb2d outputs, all four | **76/76 identical** |
| post-pass only (`HMB_JPEG_TUNING=jpegli HMB_DIRECT444=off`) | `eng-postpass` outputs (Couple, Website, Social) | **57/57 identical** (50,114,251 / 5,555,974 / 5,810,864) |
| tuning only (post-pass off) | `eng-search` outputs (Couple, Social) | **38/38 identical** (48,523,486 / 5,540,379) |
| default, Archive | d42cb2d | 19/19 identical |

So the patched tokenisers, the zero-copy decode and the proxy mosaic leave both other variants' bytes exactly as their
authors measured them, and the combination is additive.

## 3. Holdout A/B (release `hmb compress`, back to back)

| Run | Couple bytes | Website | Social | Archive | Couple min / median | Probes C / W / S | Wall | CPU (user + sys) | Peak footprint / RSS | Load before → after |
|---|---|---|---|---|---|---|---|---|---|---|
| d42cb2d Couple, 1 | 50,239,686 | | | | 74.007 / 74.105 | 1.95 | 14.4 s | 34.7 s | 3.78 / 3.80 GB | 8.26 → 7.83 |
| eng-v3 Couple, 1 | **48,365,625** | | | | 74.020 / 74.090 | **1.84** | **5.8 s** | **23.7 s** | 5.63 / 3.96 GB | 7.83 → 8.10 |
| d42cb2d Couple, 2 | 50,239,686 | | | | | | 13.7 s | 34.8 s | 3.96 / 3.82 GB | 8.10 → 7.70 |
| eng-v3 Couple, 2 | 48,365,625 | | | | | | 5.7 s | 24.0 s | 5.18 / 3.50 GB | 7.70 → 7.42 |
| d42cb2d all four, 1 | 50,239,686 | 6,265,646 | 6,015,880 | 312,351,208 | | 1.95 / 2.74 / 3.95 | 20.6 s | 118.5 s | 7.07 / 6.51 GB | 7.23 → 8.38 |
| eng-v3 all four, 1 | 48,365,625 | **5,555,974** | **5,319,707** | identical | | 1.84 / 2.79 / 6.63 | 20.2 s | 126.4 s | 6.87 / 5.28 GB | 8.38 → 10.91 |
| d42cb2d all four, 2 | (same) | | | | | | 20.5 s | 118.6 s | 7.01 / 7.00 GB | 10.91 → 10.84 |
| eng-v3 all four, 2 | (same) | | | | | | 19.8 s | 125.3 s | 6.82 / 5.28 GB | 10.05 → 11.88 |

Δ: Couple −3.73 %, Website −11.33 %, Social −11.57 %, Archive 0. Website min / median 70.034 / 70.672, Social
85.002 / 85.024 (all 4:4:4). 19/19 ≥ target in every delivery, repeats byte-identical. Couple wall −59 %, CPU −31 %;
all four: wall −3 %, CPU +6.4 % (post-pass: WebP method 6 encode 292 → ~490 ms per probe, up to 4 Social re-scores).
Social probes include the zeroing re-scores. Estimate (`hmb estimate`, 4 deliveries, 5.3 s wall at load 10): Couple
48.5 MB, Website 5.5 MB, Social 5.3 MB, Archive 312.2 MB.

Other runs: method 6 without the filter settings (`HMB_WEBP=m6`): Website 5,770,914 (−7.9 %), min 70.009.

## 4. Full wedding, all four deliveries (announced; one A/B pair)

535 × 45 MP, `$HMB_WEDDING` read-only, 7 workers / 3 archive lanes, outputs hashed then deleted.

| | Couple | Website | Social | Archive | Wall | CPU | Peak footprint / RSS | Load before → after |
|---|---|---|---|---|---|---|---|---|
| d42cb2d | 1,352,439,246 | 163,408,108 | 163,455,205 | 8,559,293,161 | 534.7 s | 3342.9 s | 7.44 / 6.97 GB | 4.57 → 11.34 |
| **eng-v3** | **1,304,140,132 (−3.57 %)** | **147,270,094 (−9.88 %)** | **143,125,766 (−12.44 %)** | 8,559,293,161, **535/535 SHA-256 identical, byte-exact** | 519.4 s (−2.9 %) | 3535.5 s (+5.8 %) | 7.28 / 5.76 GB | 8.49 → 17.49 |

eng-v3 minima: Couple 74.000 (median 74.109, max 74.78, probes 1.95, all 4:2:0), Website 70.001 (median 70.528,
probes 2.84), Social 85.000 (median 85.026, probes 7.03, all 4:4:4). 0 below target, 0 failed, 0 kept original.
Baseline bytes equal the documented G3/G5/G6 numbers. The eng-v3 run had the higher load (other agents), so its
wall is if anything pessimistic. Sources: `shasum -a 256` of all 535 before the first and after the last run are
identical to each other and to `runs/wedding-sha256-before.txt`; nothing in the folder is newer than the manifest.

## 5. Visual checks (the two flagged risks)

- **WebP loop filter** (post-pass risk): the two holdout photos with the largest Website saving (0126 −18 %, 0154
  −18 %) decoded at 2× on smooth out-of-focus foreground, skin and hair: spec m4 / m6 / m6 + filter. No blocking in
  the tuned files; they keep slightly more grain. Adopted as default.
- **Tuned full-size tables** (search risk): grainy skin and hair of 0154 at 1:1 (2× zoom) against the source and the
  d42cb2d output, both at 74: the tuned file is marginally smoother in grain, no blocking or ringing. Adopted.
  Both checks are one person's eye on two photos, not a study; the switches above stay for an owner review.

## 6. Not done / open

- Research rank 1 (Highest ≥ 88: 4:4:4 with Annex K tables, AQ off, −15 % with libjpeg-turbo) needs a jpegli
  standard-tables knob and a two-decoder check; not measured here.
- The estimator does not model the DirectSearch post-pass, yet stays calibrated: `LiveEngineTests` actual / estimate
  couple 0.998, website 1.010, social 1.000, archive 1.000 (κ 1.0).
- Zeroing for full size, JXL effort 8/9 and a lower JXL effort stay out (cost or byte-exactness by construction).

## 7. Tests

`swift build` zero warnings (one captured-var warning in the merged post-pass lab test fixed). Full `swift test` with env.sh sourced:
**376 tests in 68 suites passed** (391 s, load 13.3 → 5.3), including `LiveEngineTests` (holdout G1: 48.37 MB, probes
1.84; live determinism 6 × 4; estimator above) and the new tuned-table scan equivalence test.

