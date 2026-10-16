# Variant "dct": DCT-domain recompression (JPEGmini-style)

Branch `eng-dct` (worktree `hmb-eng-dct`), base `main` d42cb2d. Engineer name: dct. 2026-10-16, MacBookPro18,4
(M1 Max, 10 cores, 64 GB), machine shared by 5 agents and never quiet: every timing carries its load average and is an
upper bound; relative numbers come from back-to-back or interleaved runs only. Quality is always v2's metric on the
delivered bytes (ImageIO decode + Metal SSIMULACRA2); no floor or metric was touched.

## Verdict

**The JPEGmini-style path loses on bytes and is not faster; do not merge it.** Requantising the source's own
coefficients (A) needs **+2.8 % bytes** with jpegli's AQ field and **+4.5 %** with plain rounding (the literal JPEGmini
idea) at the same verified floor. It is slower than the baseline per photo, because the entropy decoding of a 20 MB
Q100 source plus DCT-domain chroma downsampling (0.46 s) costs more than the pixel front end it replaces. The loss
has a measurable cause: ImageIO does not decode JPEG coefficients exactly (§3). The reference is ImageIO's decode of
the source and every candidate is ImageIO's decode of the output, so the source's coefficients carry ImageIO's error
twice. Re-encoding the **identical** coefficients reads only **96.97 (baseline) / 93.30 (progressive)** against
ImageIO's decode of the source.

**The DCT machinery does find one real win, and it is not specific to the DCT path: jpegli's chroma tables are too
coarse for v2's metric.** Chroma tables × 0.75 reach the same verified score with **−1.5 % bytes** end to end on the
holdout (49,493,923 vs 50,239,686; 19/19 ≥ 74, 1.79 vs 1.95 probes, CPU not higher, memory unchanged). On curves it is
−1.7 % (holdout), **−2.4 % on the 6 held-back samples**, −4.1 % at full size ≥ 85 and about −2 % at 1440 px ≥ 85.
This only needs `hmb_jpegli_encode_chroma` and `JpegliEncoder.chromaScale`; it is the part worth merging (see
*Merge*). **Full wedding, Couple's Package, chroma × 0.75 (announced run): 1,330,416,815 bytes vs 1,352,439,246
(−1.63 %), 535/535 ≥ 74 (min 74.0004), probes 1.93 (base 1.96).**

**The cached DCT path (B) is jpegli to within 0.03 % bytes and about 3–5 % less CPU, but uses +0.5 GB footprint.** It
does jpegli's front end once per photo instead of once per probe. With today's 1.95 probes per photo and a fast
progressive entropy coder, that saving is small: 0.145 s per full encode and 7 ms per mosaic encode, against 0.28 s
of set-up. The search does not improve either, because the full−mosaic bias comes from where the tiles sit, not from
the encoder (§3.4). It is not worth the memory against G7's 8 GB (7.42 GB today). It stays opt-in on this branch.

## What was built

| Path | What |
|---|---|
| `Sources/CHMBCodecs/dct.cc`, `include/hmb_dct.h` | DCT-domain codec on the vendored jpegli (no new dependency, no Homebrew): `hmb_dct_read` (jpegli's decoder, `jpegli_read_coefficients`: entropy decoding only, coefficients kept dequantised as int16), `hmb_dct_prepare_420` (4:4:4 → 4:2:0 chroma in the DCT domain, G = L·X·Lᵀ, box or truncation filter), `hmb_dct_from_pixels` (jpegli's front end done once: BT.601 colour transform, 2×2 box chroma, exact float DCT, stored ×16), `hmb_dct_mosaic` (the search mosaic cut from the same coefficient blocks), `hmb_dct_aq_prefield` (scalar port of jpegli's adaptive-quantisation field, distance-independent part), `hmb_dct_encode` (jpegli's tables via `jpegli_set_distance`, jpegli's zero-bias quantiser with a constant or per-block AQ strength, `jpegli_write_coefficients`: optimised Huffman, progressive level 2, caller's APPn/COM markers) |
| `Sources/CHMBCodecs/jpegli.cc`, `Sources/HMBEngine/Codecs/JpegliEncoder.swift` | `hmb_jpegli_encode_chroma`: the pixel encoder with jpegli's chroma tables × a scale; `hmb_jpegli_encode` calls it with 1 (unchanged bytes). `JpegliEncoder.chromaScale` (default 1) |
| `Sources/CHMBCodecs/jpegli_mem.h` | the jpegli arena hooks moved out of `jpegli.cc` so both files share them (`jpegli.cc` output unchanged, verified by SHA-256 below) |
| `Sources/HMBEngine/Codecs/DCTRecompressor.swift` | `DCTSource` (read / transform / prepare420 / mosaic / encode) and `StrengthField` (AQ field + its mosaic) |
| `Sources/HMBEngine/Pipeline/DCTCandidates.swift`, `PhotoPipeline.swift`, `Search/SearchModel.swift` | `SearchConstants.fullSizeCodec` (`.jpegli` default; `.dctCached`, `.dctSource`, `.dctSourcePlain`): full-size 4:2:0 probes and mosaic proxies from coefficients prepared once per photo, unchanged `MosaicSearch`; 4:4:4 fail-open and everything the DCT path cannot read stay with jpegli. `hmb` reads `HMB_DCT`, `HMB_DCT_BIAS`, `HMB_DCT_CHROMA` and `HMB_JPEGLI_CHROMA` (A/B runs only) |
| `Sources/HMBBench/DCTLab.swift` | `hmb dct-lab curve` (not in the usage text): rate/score curves per variant, full or mosaic, CSV |
| `Tests/HMBEngineTests/Primitives/DCTCodecTests.swift` | round trip + marker order + determinism, refusal of CMYK/arithmetic, cached transform ≡ jpegli (bytes ±2 %, > 45 dB between decodes), mosaic tiles block-identical to the full candidate, AQ field shape |

Four DCT paths were measured:

- **A-plain** (`dctSourcePlain`), the literal JPEGmini idea: the source's own coefficients requantised with jpegli's
  tables (one distance per photo = one scale factor over jpegli's table shape), plain rounding, no pixels touched.
  4:2:0 chroma from the source's 4:4:4 chroma in the DCT domain (box filter, the same filter jpegli uses).
- **A-field** (`dctSource`): the same plus jpegli's zero-bias thresholds driven by the ported AQ field (computed once
  from the decoded source, which the metric needs anyway).
- **B / cached** (`dctCached`): no source coefficients; jpegli's pixel front end (colour, chroma, DCT, AQ field) runs
  once per photo and every probe only requantises + entropy-codes. This is jpegli with the per-probe redundancy removed.
- **Optimised tables**: one scale per photo (the distance) over jpegli's table shape, plus a chroma/luma balance
  (`chroma_scale`), searched as a fixed constant on the curves. The DCT-truncation chroma filter is in the codec but
  was not pursued: A loses for a reason no filter or table fixes (§3.2).

## 1. Rate at equal floor (perfect search, holdout 19, Couple's floor 74)

`hmb dct-lab curve` per variant: d ∈ {1.3, 1.6, 1.9, 2.2, 2.6, 3.0}, progressive level 2, no markers (the image data
only), ImageIO decode + Metal SSIMULACRA2 against ImageIO's decode of the source. Bytes at score 74 are interpolated
per photo in (score, ln bytes) between the two probes that bracket 74. This is the "perfect search" comparison: no
search noise, the same metric for every row. CSVs: `~/Library/Application Support/holdmybyte-dev/runs/dct-lab2/`.

| Variant | Σ bytes @ 74 | vs jpegli | Photos better / worse | Note |
|---|---|---|---|---|
| jpegli, p2 (baseline encoder) | 49.150 MB | — | — | |
| jpegli, p0 (sequential) | 50.014 MB | +1.76 % | 1 / 16 (2 ±0) | encode 0.26 vs 0.42 s, decode 0.21 vs 0.31 s |
| A-plain: source coefficients, plain rounding (JPEGmini-style) | 51.348 MB | **+4.47 %** | 1 / 18 | |
| A-field: source coefficients + ported jpegli AQ | 50.543 MB | **+2.83 %** | 0 / 19 | |
| B: cached transform + ported jpegli AQ | 49.165 MB | +0.03 % | — | same bytes ±0.5 % and score ±0.12 at every d |
| B, chroma × 1.25 | 50.560 MB | +2.87 % | | |
| B, chroma × 0.8 | 48.329 MB | −1.67 % | | |
| **B, chroma × 0.75** | **48.314 MB** | **−1.70 %** | 14 / 4 (1 ±0) | |
| B, chroma × 0.65 | 48.262 MB | −1.81 % | | |
| B, chroma × 0.5 | 48.688 MB | −0.94 % | | |
| **jpegli (pixel encoder), chroma × 0.75** | **48.298 MB** | **−1.73 %** | 14 / 4 (1 ±0) | same as B at 0.75 |
| per-photo best chroma of {1.25, 1, 0.8, 0.65, 0.5} (oracle) | 47.94 MB | −2.46 % | | needs a 2-D search, not built |
| hybrid: per photo min(jpegli, A-plain, A-field) (oracle) | 49.111 MB | −0.08 % | 1 / 19 wins | |

Validation on the 6 sample photos (`HMB_TEST_PHOTOS`, not used for tuning): jpegli 17.709 MB, **jpegli chroma × 0.75
17.279 MB (−2.43 %)**, B chroma × 0.75 −2.29 %, B chroma × 1 +0.25 %.

Other floors (holdout, jpegli chroma × 0.75 vs × 1): full size ≥ 85: 103.457 vs 107.881 MB (**−4.10 %**, no
extrapolation). 1440 px ≥ 85 (Social's variant): −0.2 … −3.7 % on each of the 16 photos that reach 85 at 4:2:0. The
3 photos that need 4:4:4 at 1440 px (D-ENG-4) are not measured: the scaled 4:4:4 chroma tables are untested.

Same-distance comparison, B vs jpegli, all 114 points: bytes −0.11 % (−0.50 … +0.06 %), score −0.02 (−0.12 … +0.02).
B's encoder is jpegli's quantiser and entropy coder fed with the same coefficients. The residue comes from the float
DCT/colour rounding and from exact log/exp in the AQ port where jpegli uses fast approximations.

## 2. End to end: holdout, Couple's Package (floor 74), release `hmb compress`, back to back

`/usr/bin/time -l hmb compress $HMB_HOLDOUT --delivery couple` (7 workers), the baseline binary (d42cb2d) and this
branch alternating. CPU = user + sys. Load is the 1-minute average before → after. The machine was at load 12 … 78
throughout (other agents), so walls are noise. CPU is more robust, but contention inflates it too: compare pairs that
ran next to each other. Outputs and reports: `runs/dct-ab/`.

| Run | Bytes | Min / median score | Probes mean | Wall | CPU | Peak footprint | Load |
|---|---|---|---|---|---|---|---|
| baseline d42cb2d (8 runs) | 50,239,686 | 74.007 / 74.105 | 1.95 | 16.4 – 39.5 s | 39.8 – 48.4 s (median 44.7) | 3.77 – 3.96 GB | 12 – 78 |
| this branch, default (`.jpegli`) | 50,239,686, **19/19 SHA-256 identical** | 74.007 / 74.105 | 1.95 | 29.2 s | 47.2 s | 3.86 GB | 30.8 → 30.9 |
| B `dctCached` (5 runs) | 50,266,749 (+0.05 %) | 74.021 / 74.111 | 1.84 | 18.5 – 35.1 s | 42.6 – 45.4 s (median 43.4) | 4.34 – 4.40 GB | 21 – 74 |
| A `dctSource` | 51,633,915 (+2.77 %) | 74.018 / 74.090 | 2.11 | 50.5 s | 54.5 s | 4.79 GB | 53 → 78 |
| A-plain `dctSourcePlain` | 52,658,737 (+4.81 %) | 74.013 / 74.124 | 2.05 | 24.6 s | 51.8 s | 4.95 GB | 62 → 54 |
| **jpegli chroma × 0.75** (2 runs) | **49,493,923 (−1.48 %)** | 74.003 / 74.116 | **1.79** | 21.6 – 22.7 s | 39.1 – 39.7 s | 3.86 – 3.91 GB | 37 – 44 |
| B + chroma × 0.75 (3 runs) | 49,489,073 (−1.49 %) | 74.003 / 74.103 | 1.79 | 14.6 – 22.3 s | 34.8 – 42.1 s | 4.43 – 4.51 GB | 12 – 44 |

Every run: 19/19 ≥ 74, nothing kept or failed, repeats byte-identical. Adjacent pairs, CPU: base3/B3 44.4/43.9,
base4/B4 47.0/43.3, base5/B5 46.4/43.4 (B −1 … −8 %). base7, base8 42.4, 42.3 against jpegli × 0.75 39.1, 39.7 (−7 %,
mostly the 0.16 fewer probes) and B × 0.75 37.9, 34.8. G1 (≤ 50,301,670 bytes, ≤ 2.2 probes) passes for every row
except A and A-plain.

Where B's CPU goes (the decomposition matches the measured −3 s on 19 photos): per photo it saves 1.84 × 0.145 s on full
encodes and ~12 × 7 ms on mosaic encodes (0.35 s). It spends 0.28 s on set-up. The rest of the difference is 0.11
fewer full probes, which is where the search happened to land: B's candidates differ from jpegli's by a fraction of a
percent, and the same search on them stops one probe earlier on two photos. Without that luck the codec gains about
3 %.

**Full wedding (535 photos), Couple's Package, jpegli chroma × 0.75**, the one wedding run of this variant (announced
here; `runs/dct-wedding/`). Release `hmb compress`, 7 workers, `/usr/bin/time -l`:

| Run | Bytes | Min / median / max score | Probes mean (1/2/3) | Wall | CPU | Peak footprint | Load |
|---|---|---|---|---|---|---|---|
| baseline (BENCHMARKS G3, 2026-10-15) | 1,352,439,246 | 74.00 / 74.11 / 75.29 | 1.96 (100/356/79) | 375.1 s | 1.93 CPU-s/photo | (5.73 GB RSS) | 29 → 9 |
| **chroma × 0.75** | **1,330,416,815 (−1.63 %)** | 74.0004 / 74.11 / 75.72 | **1.93** (108/356/71) | 641.3 s | 1249.6 s (2.33 CPU-s/photo) | 4.32 GB (4.01 GB RSS) | 15.9 → 17.5 (peak ~45; this branch's test suite ran in parallel for 6 min) |

535/535 delivered and ≥ 74, nothing kept or failed, every photo 4:2:0, all targets 74. The baseline was not re-run, so
wall and CPU are not comparable to it (different day and load). The bytes and scores are deterministic and do not
depend on load. The holdout pairs in the table above are the timing evidence: CPU is not higher. Sources unchanged: no
file in the wedding, holdout or sample folders is newer than the runs.

## 3. Findings

### 3.1 Per-operation timings (45 MP, release, interleaved, load ~20, medians of 18 / 30)

| Operation | jpegli (pixels) | B (cached) | A (source coefficients) |
|---|---|---|---|
| Set-up once per photo | — | 0.28 s (transform 0.12 + AQ field 0.16) | 0.67 s (entropy decode + copy 0.33, 4:2:0 in DCT 0.13, AQ field 0.16) |
| Full encode, d 2.0, 4:2:0, p2 | 0.482 s | 0.337 s (requantise 0.04, jpegli entropy coding ~0.27) | 0.316 s |
| ImageIO decode of that candidate | 0.330 s | 0.353 s | 0.359 s |
| Score (GPU, incl. wait) | 0.061 s | 0.066 s | 0.060 s |
| Mosaic encode, 2048×1024 | 20.4 ms | 13.0 ms | 14.3 ms |

The work per probe that the DCT path cannot touch is the progressive entropy coding (~0.27 s, the same jpegli code in
both paths), ImageIO's decode of the candidate (0.33 s) and the score. jpegli's whole pixel front end (colour, DCT, AQ
field, quantisation) is only ~0.15 s per encode. JPEGmini's speed does not carry over to v2, because v2 decodes and
verifies every candidate at full resolution with a full-reference metric. That decode, not the encoder, is the floor.
For scale: p0 (sequential) cuts both encode (0.26 s) and decode (0.21 s) by ~40 % but costs +1.76 % bytes at equal
score. G1's margin is 0.12 %, so p0 is a trade-off for the owner, not a free win.

### 3.2 Why requantising the source loses: ImageIO's decode is not exact

Re-encoding sample 0014's own coefficients with Q = 1 tables (identical dequantised values; temporary lab build) and
scoring against ImageIO's decode of the source: **96.97** as a sequential file, **93.30** as progressive. It is
unchanged with the source's APP14/ICC markers and with restart markers every MCU row. ImageIO decodes even
bit-identical coefficients differently in another file. Its progressive path also reads lower than its sequential one:
the same jpegli coefficients score +0.49 higher as p0 than as p1/p2 (p1 and p2 read identically). A pixel encoder
encodes the reference as ImageIO decoded it, so only the candidate's decode error counts. A coefficient requantiser
inherits the source's decode error as well. At 4:4:4 without AQ, the requantised source reaches −1.3 % bytes but −0.70
points at the same distance, about +3–4 % bytes at the same score. The DCT-domain chroma downsampling is not the
cause: the same gap appears at 4:4:4. A different table shape cannot fix this either.

### 3.3 jpegli's chroma/luma balance

jpegli's tables are fitted to butteraugli ("Global scale is chosen in a way that butteraugli 3-norm matches libjpeg",
`lib/jpegli/quant.cc`), and v2's floor is SSIMULACRA2 on ImageIO's decode. On this wedding v2's metric rewards finer
chroma: at the same score, chroma × 0.75 buys back more luma bits than it spends. The optimum is flat between 0.65 and
0.8; 0.75 is in the middle of it. Per photo it ranges from +2 % (0042) to −8 % (0462, a saturated scene). A per-photo
choice is worth another ~0.8 % but needs a second search dimension (cheap on the mosaic, not built).

### 3.4 The block-exact mosaic does not improve the search

B's mosaic is cut from the full candidate's own coefficients and AQ field (test `mosaicIsCutFromTheSameBlocks`: tile
interiors decode identically to the full candidate). Full − mosaic at the same distance is still **−1.10 median (range
−1.99 … −0.13, sd within a photo 0.12)**, the same as jpegli's mosaic (−1.10, −1.98 … −0.08, 0.12). The bias is the
metric pooled over 4.5 % of the image versus all of it, not an encoding difference, so `exactBiasPrior` stays −1.1.

## 4. Merge

**Worth merging** (after the lead's review; it changes output bytes, so it is not a pure speed change):

- `hmb_jpegli_encode_chroma` (`Sources/CHMBCodecs/jpegli.cc`; declared in `include/hmb_dct.h`, which can move to its
  own header) and `JpegliEncoder.chromaScale` (`Sources/HMBEngine/Codecs/JpegliEncoder.swift`), commit de1f22f; the
  arena-hook refactor `jpegli_mem.h` (deaa7e6) that it sits on. With `chromaScale = 1` the frozen `hmb_jpegli_encode`
  runs byte for byte (test `chromaScaledJpegli`, and the SHA-256-identical default run above).
- To adopt it, set `chromaScale = 0.75` in `EnginePrimitives.live()`. That is a one-line change, not made on this
  branch, because it changes all JPEG deliveries (Couple, High, Social) and needs a decision record (proposed
  D-ENG-11). Before switching: G3 (wedding Couple) is measured here (−1.63 %, 535/535 ≥ 74). G4 (High 85) and G5
  (Social) were not run on the wedding; on holdout curves they gain 4.1 % and ~2 %. Re-fit κ (estimates read
  ~1.5–4 % high) and run `LiveEngineTests`.

**Not worth merging** (keep on `eng-dct` as a record, or merge default-off only if the lab tool is wanted):
`dct.cc`, `DCTRecompressor.swift`, `DCTCandidates.swift`, `SearchConstants.fullSizeCodec`/`dct*`, the `HMB_DCT*`
variables, `hmb dct-lab`, and the DCT tests. A loses on bytes. B saves ~3–5 % CPU but costs +0.5 GB footprint per run
(G7 is at 7.42 of 8 GB), and the chroma gain needs no DCT path at all.

**Risks.**
- The chroma factor is tuned on one wedding, one camera and one Lightroom export: 19 holdout photos, validated on 6
  samples. Saturated or colour-critical work may move differently (per photo +2 … −8 %).
- The scaled 4:4:4 tables (fail-open, Social's 3 hard photos) are unmeasured.
- The AQ port and the BSD tables are copied from libjxl v0.11.2 and must follow a pin change.
- `hmb dct-lab` is hidden but parsed.
- An umbrella-header gotcha: adding a header to `Sources/CHMBCodecs/include` needs `.build/*/ModuleCache` cleared once,
  or Swift does not see it.
- The scratchpad is shared between agents: another agent overwrote a script named `ab.sh` mid-run (no data was lost; the
  affected runs were repeated).

## 5. Reproduce

```bash
source "$HOME/Library/Application Support/holdmybyte-dev/env.sh"
swift build -c release --product hmb
.build/release/hmb dct-lab curve "$HMB_HOLDOUT"/*.jpg --mode jpegli|fdct|dct [--aq field|-1|S] [--chroma C] [--prog 0|2] [--mosaic] [--edge 1440] --d 1.3,1.6,…
HMB_DCT=dctCached [HMB_DCT_CHROMA=0.75] .build/release/hmb compress "$HMB_HOLDOUT" -o <out> --delivery couple --json <r.json>
HMB_JPEGLI_CHROMA=0.75 .build/release/hmb compress …
swift test --filter "DCTCodecTests|DCTPipelineTests"
```

