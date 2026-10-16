# Variant "research": competitor analysis and what it means for the engine

Branch `eng-research` (worktree `hmb-eng-research`), base `main` d42cb2d. 2026-10-16, MacBookPro18,4 (M1 Max, 10 cores,
64 GB), shared by several agents and never quiet (1-minute load 20–31 during these runs): **no timing here is a
gate number**; bytes and scores are deterministic. No engine code was changed on this branch. Market survey and the
JPEGmini forensics are in [`../COMPETITORS.md`](../COMPETITORS.md).

Quality is v2's metric (`hmb score`: ImageIO decode of both files, Metal SSIMULACRA2) unless a row says
"turbo/turbo" (both reference and candidate decoded by libjpeg-turbo 3.x `djpeg`, written as PNG, then `hmb score`).
`hmb` was a release build copied from `hmb-eng-search` (provenance: libjxl/jpegli 0.11.2, libwebp 1.6.0). Sources were
APFS clones of the 19 holdout photos in the scratch folder; no original was opened for writing.

## 1. Findings

| # | Finding | Evidence |
|---|---|---|
| F1 | **At the Highest floor (90), plain 4:4:4 baseline JPEG with standard Annex K tables beats v2 by 15 %.** libjpeg-turbo `cjpeg -sample 1x1 -optimize` with Annex K × one factor per photo (bisected to ≥ 90): **176.3 MB vs v2 Highest 207.8 MB** on the holdout (0.849×; per photo 0.75–0.94×, all 19 smaller). Best of two table shapes per photo: 172.0 MB (0.828×). Holds for v2's own 4:4:4 fail-open photos too (6/19, 0.843×), so it is not only chroma. | §2.1 |
| F2 | The F1 gap survives decoder-consistent scoring. Turbo/turbo on 4 photos: v2 89.93 / 90.13 / 90.21 / 90.01 vs Annex K 90.12 / 90.27 / 90.01 / 90.31 at −18 % / −18 % / −26 % / −11 % bytes. | §2.2 |
| F3 | **At 85, jpegli 4:2:0 wins**: v2 High beats the best libjpeg-turbo 4:4:4 result on 7 of 8 photos (total 44.13 MB vs 45.60 MB for the best 4:4:4 table per photo, −3 %; 0154 loses by 5 %). libjpeg-turbo 4:2:0 is worse than its 4:4:4 at every photo, by 3–49 %. The crossover is between 85 and 90. | §2.3 |
| F4 | **ImageIO reads the same coefficients up to 1.6 points differently depending on baseline vs progressive.** Annex K 4:4:4 file of 0014: baseline 90.13, lossless `jpegtran -progressive` of it 88.53, turbo/turbo 90.12. Apple's own q75: 90.73 baseline vs 89.06 progressive. v2's jpegli 4:2:0 output: progressive 90.13, baseline repack 89.70. Mixed decoding (ImageIO reference, turbo candidate) moves a 4:4:4 candidate by −1.5. METRIC §4 measured the candidate-decoder effect only for jpegli 4:2:0 (ImageIO 0.29 lower than turbo); it does not generalise. | §2.4 |
| F5 | JPEGmini = Annex K × one factor, 4:4:4, baseline, optimised Huffman, metadata kept, `COM` mark (COMPETITORS §2.2). On 45 MP exports 70 % of files sit at IJG Q 92–94; 14 % below Q 85. On the holdout its files total 191.0 MB at scores 79.1–91.5 (`squeeze score`, F9). **F1's encoder gives every photo ≥ 90 in 176.3 MB (−8 % vs JPEGmini)**; v2 today needs 207.8 MB (+9 %). | `jpegos/Benchmarks/data/wedding-per-file.csv`, §2.1 |
| F6 | On the 535 wedding the old engine matched to JPEGmini's per-file score was 1.20× its bytes in the 90–92 band and 1.50× at ≥ 92, but 0.86× below 85. With F1 the high band should flip. | re-analysis of `wedding-per-file.csv` |
| F7 | JPEGmini outputs leave lossless bytes on the table: `jpegtran -progressive` saves 1.0–2.0 % (3 files), the JPEG XL lossless transcode 23.5 % (old engine, 535 files). 27,200 JPEGmini-marked files exist on this Mac alone. | COMPETITORS §2.2, DATENLAGE §1c |
| F8 | Speed: JPEGmini 0.42 s/photo wall, ~2.3 CPU-s/photo (535 × 45 MP, 2026-07). v2 Couple's Package 1.93 CPU-s/photo (2026-10-15, under load): CPU parity; the wall gap is verification. v2 Highest on the holdout: 2.26 full probes/photo, 6/19 photos ran the failed 4:2:0 search before fail-open 4:4:4. | BENCHMARKS, `hi19.json` |
| F9 | Scoring caveat for the July duel: JPEGmini-style files read 88.57 under the old engine's *internal* mixed pairing (source ImageIO, candidate libjpeg-turbo) but 90.13 under `squeeze score` (ImageIO both sides, measured today on the same file) and v2. The July JPEGmini scores were most likely taken with `squeeze score`, so they are on v2's scale; nothing in the old pipeline should be re-used for 4:4:4 baseline candidates without checking which decoder pairing produced it. | §2.4 |

## 2. Experiments

Scripts (kept out of the repo, in the scratch folder): `jpginfo.py` (marker/DQT/IJG-fit dump), `tablesweep.py`
(bisection over one table factor, 9 steps, per photo × table family × sampling, score ≥ T), `enc1.py` (one encode).
Encoder for all non-v2 rows: Homebrew libjpeg-turbo `cjpeg -quality 50 -qtables <file> -qslots 0,1,1 -sample S
-optimize` from a `djpeg` PPM of the source (baseline, islow DCT, no trellis, no AQ). Two table families: **Annex K**
(ITU T.81 K.1/K.2) and **Apple shape** (the tables Apple ImageIO writes at quality 0.75, used as a shape, scaled).

### 2.1 Holdout 19 at T = 90 (v2 scoring)

v2: `hmb compress <holdout> --delivery highest-full --workers 4` (95 s wall at load ~25, 13 photos 4:2:0, 6 4:4:4).

| Photo | v2 Highest | Annex K 4:4:4 | Apple shape 4:4:4 | best / v2 | JPEGmini (score) |
|---|---|---|---|---|---|
| 0014 | 9,179,940 (4:2:0) | 7,511,077 | 7,646,589 | 0.818 | 9.547 MB (90.73) |
| 0042 | 8,916,988 (4:2:0) | 8,697,130 | 8,412,360 | 0.943 | 9.907 (89.67) |
| 0070 | 9,339,719 (4:2:0) | 8,320,178 | 8,348,571 | 0.891 | 9.689 (89.84) |
| 0098 | 8,589,621 (4:2:0) | 7,837,079 | 7,948,338 | 0.912 | 10.291 (91.38) |
| 0126 | 11,103,012 (4:4:4) | 9,112,851 | 8,746,112 | 0.788 | 11.307 (90.15) |
| 0154 | 14,161,935 (4:4:4) | 12,261,543 | 11,992,324 | 0.847 | 11.259 (87.01) |
| 0182 | 12,949,754 (4:2:0) | 10,807,754 | 10,448,100 | 0.807 | 10.132 (87.54) |
| 0210 | 11,436,789 (4:2:0) | 9,503,603 | 9,274,066 | 0.811 | 12.490 (90.22) |
| 0238 | 9,483,723 (4:2:0) | 7,871,005 | 7,988,427 | 0.830 | 8.973 (89.27) |
| 0266 | 13,156,944 (4:2:0) | 11,709,528 | 11,227,272 | 0.853 | 11.633 (88.33) |
| 0294 | 14,127,267 (4:4:4) | 11,768,158 | 11,135,549 | 0.788 | 6.875 (82.25) |
| 0322 | 10,941,070 (4:4:4) | 9,125,710 | 8,888,085 | 0.812 | 12.227 (90.73) |
| 0350 | 9,879,565 (4:2:0) | 7,765,164 | 7,839,046 | 0.786 | 6.996 (87.71) |
| 0378 | 9,566,950 (4:2:0) | 7,664,109 | 7,419,381 | 0.776 | 9.255 (90.56) |
| 0406 | 10,526,846 (4:2:0) | 9,778,044 | 9,964,669 | 0.929 | 14.448 (91.45) |
| 0434 | 11,730,599 (4:4:4) | 9,687,120 | 9,216,348 | 0.786 | 12.887 (90.95) |
| 0462 | 11,938,414 (4:4:4) | 10,404,997 | 10,059,441 | 0.843 | 12.911 (90.88) |
| 0490 | 10,611,448 (4:2:0) | 8,913,120 | 8,557,205 | 0.806 | 6.494 (85.64) |
| 0518 | 10,167,164 (4:2:0) | 7,596,950 | 7,572,069 | 0.745 | 3.676 (79.10) |
| **Total** | **207.81 MB** | **176.34 MB (0.849)** | **172.68 MB (0.831)** | **172.03 MB (0.828)** | **191.0 MB (79.1–91.5)** |

All non-v2 rows score 90.0–90.7 (bisection resolution ~0.6 % in the factor). Two earlier photos at 4:2:0 with the
same encoder: 0014 needs 10.70 MB at 90 (vs 7.51 MB at 4:4:4), 0434 cannot reach 90 at 4:2:0 at all — 4:2:0 caps the
score near 90 on this material.

### 2.2 Decoder-consistent check (turbo/turbo)

| Photo | v2 Highest bytes · turbo/turbo | Annex K 4:4:4 bytes · ImageIO · turbo/turbo | bytes ratio |
|---|---|---|---|
| 0014 | 9,179,940 · 89.93 | 7,511,077 · 90.13 · 90.12 | 0.818 |
| 0126 | 11,103,012 · 90.13 | 9,112,851 · 90.24 · 90.27 | 0.821 |
| 0518 | 10,167,164 · 90.21 | 7,568,344 · 89.98 · 90.01 | 0.744 |
| 0266 | 13,156,944 · 90.01 | 11,709,528 · 90.24 · 90.31 | 0.890 |

Apple ImageIO q75 of 0014 (8,110,511 bytes): ImageIO 90.73, turbo/turbo 90.64.

### 2.3 T = 85, 8 photos (v2 scoring)

| Photo | v2 High (jpegli 4:2:0) | Annex K 4:4:4 | Apple 4:4:4 | Annex K 4:2:0 | Apple 4:2:0 |
|---|---|---|---|---|---|
| 0014 | **4,625,553** | 5,113,821 | 4,911,526 | 5,491,691 | 5,036,460 |
| 0098 | **4,448,419** | 5,240,796 | 4,791,093 | 5,381,169 | 5,190,717 |
| 0154 | 8,241,883 | 8,205,696 | **7,862,330** | 8,941,147 | 8,611,889 |
| 0238 | **4,769,053** | 5,445,016 | 5,117,811 | 6,002,653 | 5,388,820 |
| 0322 | **5,660,401** | 6,034,975 | 6,280,222 | 8,831,996 | 9,167,984 |
| 0406 | **5,829,598** | 6,454,380 | 6,165,450 | 9,634,697 | 9,293,770 |
| 0490 | **5,437,748** | 5,699,056 | 5,496,781 | 7,725,504 | 7,193,863 |
| 0518 | **5,118,470** | 5,316,450 | 5,217,294 | 6,048,276 | 6,014,303 |

Note F4: under ImageIO scoring the baseline libjpeg-turbo files read about +1.5 relative to progressive repacks of
themselves, so the 85-point comparison flatters them; jpegli's lead at 85 is, if anything, larger.

### 2.4 Decode-path asymmetry (0014)

| File | Bytes | ImageIO/ImageIO | turbo/turbo | ImageIO ref / turbo cand |
|---|---|---|---|---|
| Annex K 4:4:4, baseline | 7,511,077 | 90.13 | 90.12 | 88.57 |
| same, `jpegtran -progressive` (identical coefficients) | 7,376,995 | **88.53** | (90.12) | — |
| Apple q75 4:4:4, baseline | 8,110,511 | 90.73 | 90.64 | 89.11 |
| same, progressive | 7,846,374 | **89.06** | — | — |
| v2 jpegli 4:2:0, progressive p2 | 9,179,940 | 90.13 | 89.93 | 90.16 |
| same, `jpegtran` baseline repack | 9,634,733 | 89.70 | — | — |

The source (Lightroom, baseline 4:4:4) decoded by ImageIO and by libjpeg-turbo differs by mean |Δ| 0.19 code
values (0.5 % of samples > 1). For a 4:4:4 candidate whose blocks line up with the source's, the reading depends on
whether both files go through the same decoder path: ImageIO appears to use a different path for baseline and
progressive JPEG. "ImageIO is the lowest reading" (D-ENG-2) is true for jpegli 4:2:0 progressive candidates; it is
**not** a safe assumption for 4:4:4 baseline candidates, where ImageIO reads like turbo/turbo and higher than a
mixed pairing. Any 4:4:4-first change must be verified on both decoders.

## 3. Recommendations for the engine (ranked by expected gain ÷ risk)

| Rank | Change | Expected gain | Risk / cost | First experiment |
|---|---|---|---|---|
| 1 | **High-target JPEG path: for T ≥ 88 search 4:4:4 first, with Annex-K-shaped tables and no adaptive quantisation** (Highest; Balanced photos whose target is 88+ — none at today's clamp of 87). Keep jpegli 4:2:0 for T ≤ 85; between, compare on the mosaic. | **−15 % bytes on Highest** (holdout: 207.8 → ~176 MB), every photo ≥ 90 and 8 % below JPEGmini's bytes; fewer probes (no failed 4:2:0 pass on ~1/3 of photos). | Needs an encoder mode: first try jpegli itself with standard tables (`jpegli_use_standard_quant_tables`, `jpegli_enable_adaptive_quantization(…, FALSE)`, 4:4:4) to keep SPEC E1's one-encoder rule; only if that does not reproduce F1, consider libjpeg-turbo's quantiser (E1 rejected two libjpegs for symbol clashes; the `hmb-eng-dct` codec path could host it). Must pass F4's two-decoder check. | Holdout, Highest: jpegli 4:4:4 {default, standard tables, AQ off} vs this file's Annex K numbers, scored ImageIO/ImageIO and turbo/turbo; then the 535 wedding with `highest-full`. |
| 2 | **Decoder-consistent verification.** Decode reference and candidate with the same decoder, and in `hmb bench` also report min(ImageIO, libjpeg-turbo) per file. Record F4 in METRIC.md. | 0 bytes; protects the "lowest score" receipt from a ±1.6 decoder-path swing. | Small (turbo decode is in the test path already via `HMB_DJPEG`). | Re-score G1/G3 outputs turbo/turbo; expect ±0.3 for jpegli 4:2:0. |
| 3 | **Detect already-optimised sources.** `COM` "Optimized by JPEGmini" (and as a fallback, a scaled Annex K table at IJG ≤ 95 with optimised Huffman) → default to the lossless routes (JPEG XL archive −23.5 %, or a byte-safe progressive repack −1–2 %) and warn before a second lossy generation. | Avoids a quality trap on a large installed base; a migration story. | Low. | Scanner flag + preflight message; unit test on a JPEGmini sample. |
| 4 | Per-photo table shape at T ≥ 88 (Annex K vs a flatter Apple-like luma shape), chosen on the mosaic. | Further −2.4 % (0.849 → 0.828) on Highest. | Low once rank 1 exists; one more mosaic curve. | Same harness as rank 1. |
| 5 | Progressive for any 4:4:4 path, but only after rank 2: a progressive repack is −1.8 % at identical coefficients, yet reads 1.6 lower in ImageIO (F4). | −1.8 % | Score instability across decoders. | Part of rank 1. |
| 6 | **Do not** chase JPEGmini's DCT-domain requantisation for the high band: F1 beats JPEGmini at a higher floor without it, and the requantisation-plus-weighted-matrix combination is close to Beamr's claims (US 8,908,984; counsel). The `eng-dct` variant covers the 4:2:0 side. | — | Patent exposure. | — |

What does **not** need changing: Couple's Package (Balanced, mostly target 74) and Website/Social — jpegli 4:2:0 wins
there (F3; D-ENG-1 holdout data), and JPEGmini is no factor at those floors.

## 4. Recommendations for positioning

1. Lead with the **printed floor** ("every photo checked, lowest score X"); JPEGmini's own spread on one wedding is
   75–93.5 and its most-compressed files are its worst (corr −0.92).
2. Re-run the JPEGmini duel with the **current release (4.5.x)** and score its outputs with one decoder on both
   sides (F4, F9) before any public number; this Mac has the 2022 build 3.4.1.
3. After rank 1: "Highest (≥ 90) is smaller than JPEGmini" (holdout: 176 vs 191 MB with every file ≥ 90 vs
   JPEGmini's 79–91). Today that claim is false (v2 207.8 MB).
4. Offer a **JPEGmini library migration**: detect its mark, archive losslessly (−23.5 %), never re-lossy silently.
5. Match JPEGmini 4.5's automation features (watch folder, multi-size export) in the delivery model; they are its
   2026 roadmap and our core shape already.
6. Do not compete on speed or on "up to 80 %": both are commodity claims; JPEGmini is still faster in wall time.

## 5. Not done

- JPEGmini's GUI was not run on new photos: `open -a` on a cloned file stops at a modal "Files will be replaced"
  sheet (overwrite mode), which would need a click; the app was quit without processing (clone unchanged). The
  July 535-photo outputs were deleted; this file uses their recorded per-file numbers and the 27,200 JPEGmini files
  already on disk (read-only).
- JPEGmini's 4000 px exports in `~/Desktop/thefotoarchive/kleiner` were not scored: their resampler is unknown, so
  no fair reference exists.
- jpegli 4:4:4 with standard tables was not measured (needs engine code; rank 1's first experiment).
