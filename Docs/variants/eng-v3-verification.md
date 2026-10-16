# Engine v3: independent verification

Branch `eng-v3` at 2702cb6, verified against `main` at d42cb2d by an independent verifier, 2026-10-16. Machine:
MacBookPro18,4 (M1 Max, 10 cores, 64 GB), shared with other agents and never quiet. Every timing carries its load and
is an upper bound. Quality is always judged by v2's own metric with v2's decoder (ImageIO + Metal SSIMULACRA2) on the
delivered bytes. To make the check independent, the rescoring used **d42cb2d's** decoder and metric code, not eng-v3's.
Raw data, hashes and scripts are in `~/Library/Application Support/holdmybyte-dev/runs/verifier-v3/`.

**Verdict:** every claim that matters holds: bytes, scores, archive, determinism, source safety, tests and memory.
Two numbers in the integrator's report are optimistic (four-delivery wall time and estimate time; see §3). No code
defect was found, so this commit adds only this report. **Merge recommended.**

## 1. Method

- **Clean rebuild.** Fresh `git clone` of eng-v3 and of d42cb2d into a scratch directory.
  - `Scripts/build-codecs.sh` was run from scratch (`HMB_CODEC_FORCE=1`, new work directory, fresh libjxl/libwebp
    clones, patch applied) in 77 s.
  - Every archive member is byte-identical to the locked `3e81407d…` library. Only the ar-header group id differs (0
    instead of 20), because the scratch directory belongs to `wheel`. That changes the archive's SHA-256, and the script
    then rewrites `Vendor/codecs.lock` (see §5).
  - Against main's `515f666e…` library, the only object that differs is `entropy_coding.cc.o` (the tokeniser patch).
  - `swift build -c release` gave zero warnings in both clones.
- **Tests.** Full `swift test` in the clean clone with env.sh sourced: **376 tests in 68 suites passed**, zero warnings,
  7:04 wall, load 11 → 6.
- **A/B.** Release `hmb compress` on the 19-photo holdout. Couple alone ×2, then all four deliveries ×2, baseline and
  eng-v3 alternating, measured with `/usr/bin/time -l`.
- **Rescoring.** A throwaway test in the d42cb2d clone (not committed) rebuilt each reference: the source for Couple,
  sRGB + 2560 px for Website, sRGB + 1440 px for Social. It recomputed the Balanced target from the features, decoded
  each delivered file with ImageIO and scored it with the Metal SSIMULACRA2.
- **Compatibility.** Every output was decoded outside ImageIO:
  - JPEG with `djpeg` (libjpeg-turbo 3.2.0) and ffmpeg's own mjpeg decoder. Both must exit 0 with no warnings.
  - The JPEG markers were parsed: SOF, precision, DQT precision, sampling and scan count.
  - Each JPEG was transcoded with `jpegtran` to a sequential JPEG and decoded with djpeg; the pixels had to match the
    delivered file's.
  - WebP with `dwebp`, `webpinfo` and ffmpeg.
  - JXL with `djxl` (libjxl 0.12.0), reconstructing the JPEG and comparing its SHA-256 with the source.
- **Full wedding** (announced): one eng-v3 run of the default deliveries (Couple + Website), which the integrator
  had not measured on its own. Outputs were hashed, rescored and decoded, then deleted for disk space (27 GB free).

## 2. Results

### Holdout, release, back to back

| Run | Couple bytes | Website | Social | Archive | Min / median score (C · W · S) | Probes C / W / S | Wall | CPU (user + sys) | Peak footprint / RSS | Load (1 min) before → after |
|---|---|---|---|---|---|---|---|---|---|---|
| d42cb2d Couple 1 | 50,239,686 | | | | 74.007 / 74.105 | 1.95 | 13.75 s | 35.7 s | 3.96 / 3.88 GB | 6.95 → 7.57 |
| eng-v3 Couple 1 | **48,365,625** | | | | 74.020 / 74.090 | **1.84** | **6.11 s** | **25.0 s** | 5.34 / 3.67 GB | 7.57 → 7.68 |
| d42cb2d Couple 2 | 50,239,686 | | | | | | 14.46 s | 35.8 s | 3.84 / 3.71 GB | 7.68 → 8.06 |
| eng-v3 Couple 2 | 48,365,625 | | | | | | 5.80 s | 25.0 s | 5.18 / 3.88 GB | 8.06 → 8.78 |
| d42cb2d all four 1 | 50,239,686 | 6,265,646 | 6,015,880 | 312,351,208 | C 74.007 / 74.105 · W 70.090 / 70.636 · S 85.006 / 85.264 | 1.95 / 2.74 / 3.95 | 21.21 s | 122.6 s | 7.09 / 6.96 GB | 8.31 → 9.05 |
| eng-v3 all four 1 | 48,365,625 | **5,555,974** | **5,319,707** | identical | C 74.020 / 74.090 · W 70.034 / 70.672 · S 85.002 / 85.024 | 1.84 / 2.79 / 6.63 | 22.26 s | 133.4 s | 6.88 / 5.29 GB | 9.05 → 12.27 |
| d42cb2d all four 2 | (same) | | | | | | 22.09 s | 125.1 s | 6.92 / 6.66 GB | 12.27 → 12.26 |
| eng-v3 all four 2 | (same) | | | | | | 21.15 s | 129.3 s | 6.87 / 5.30 GB | 12.26 → 13.74 |
| eng-v3, all six switches off | 50,239,686 | 6,265,646 | 6,015,880 | 312,351,208 | = d42cb2d | = d42cb2d | 18.26 s | 114.4 s | 7.03 / 5.40 GB | 4.81 → 16.41 |

Changes against the baseline:

| | Change |
|---|---|
| Couple bytes | −3.73 % |
| Website bytes | −11.33 % |
| Social bytes | −11.57 % |
| Archive bytes | 0 |
| Couple wall time (means 14.1 → 5.96 s) | −58 % |
| Couple CPU | −30 % |
| Couple peak footprint | +1.3 GB (+35 %) |
| All four, wall time (means 21.65 → 21.71 s) | +0.3 % |
| All four, CPU | +6.1 % |
| All four, peak footprint | −0.1 GB |

### Full wedding, eng-v3, default deliveries (Couple + Website), 535 × 45 MP, one run

| Couple bytes | Website bytes | Min / median score | Probes C / W | Wall | CPU | Peak footprint / RSS | Load before → after |
|---|---|---|---|---|---|---|---|
| 1,304,140,132 | 147,270,094 | C 74.0002 / 74.109 · W 70.0006 / 70.528 | 1.95 (max 3) / 2.84 (max 5) | 274.8 s | 1778.5 s | **5.17** / 3.68 GB | 5.75 → 13.77 |

- The bytes are identical to the integrator's numbers from his four-delivery wedding run. Couple and Website come out
  the same in a different job composition.
- All 535 Couple and 535 Website files were `done`. None was kept as the original and none failed.
- No baseline run was made for this job, to save machine time, so the wall time has no A/B.

### Quality, compatibility, safety

| Check | Result |
|---|---|
| Rescore with **d42cb2d's** decoder and metric, holdout, all lossy files | 57/57 ≥ target. Lowest margins: Couple +0.020, Website +0.034, Social +0.0018. They differ from the engine's reported scores by at most 5·10⁻⁷. |
| The same, full wedding (Couple + Website) | **1070/1070 ≥ target**. Lowest margins: Couple +0.00024, Website +0.00059. Maximum difference from the reported scores: 5·10⁻⁷. |
| Archive | 19/19 `.jxl` files SHA-identical to d42cb2d's. 19/19 reconstructed with the external `djxl` to the source bytes. |
| Determinism | Couple ×2 and all four ×2: identical SHA-256 per file. Couple in the Couple-only job = Couple in the four-delivery job. The wedding bytes match the integrator's earlier run. |
| Switches off (`HMB_JPEG_TUNING=jpegli HMB_DIRECT444=off HMB_OPTIMIZE_SCANS=0 HMB_ZEROING=0 HMB_XMP_LAYOUT=verbatim HMB_WEBP=spec`) | 76/76 files SHA-identical to d42cb2d. |
| JPEG format (holdout 38, wedding 535) | All SOF2 progressive, 8-bit, 8-bit DQT, Huffman-coded. This is the same frame type as d42cb2d. Couple stays 4:2:0; Social is now always 4:4:4 (d42cb2d: 13 × 4:2:0, 6 × 4:4:4). Couple has 8–12 scans and Social 6–10 (d42cb2d: 13–15). |
| djpeg + ffmpeg mjpeg | 573/573 decode with exit 0 and no warnings. PSNR between djpeg and ffmpeg is ≥ 46.9 dB on the holdout (d42cb2d: ≥ 43.7); the wedding was checked for clean decodes only. |
| djpeg pixels, delivered file vs. jpegtran sequential re-encode | 38/38 identical. libjpeg-turbo's output does not depend on the scan script, so a different scan order cannot change what a libjpeg-based viewer shows. |
| WebP (holdout 19, wedding 535) | dwebp, webpinfo and ffmpeg all exit 0. PSNR between dwebp and ffmpeg is 36.9 dB, the same as d42cb2d (the decoders upsample differently). |
| Metadata (holdout) | Every APPn/COM segment other than XMP is byte-identical to d42cb2d's. XMP equals d42cb2d's after removing the whitespace between tags. Couple (keepAll) keeps it verbatim. Website + Social save 158 KB of XMP on 19 photos. |
| Sources | SHA-256 of the holdout (19), the samples (6) and the wedding (535) are unchanged after all runs and tests. The wedding manifest equals `runs/wedding-sha256-before.txt`. No file in the source folders is newer than the manifest. |
| Memory | Peak footprint ≤ 7.09 GB on every job measured. Wedding default job: 5.17 GB. The integrator's four-delivery wedding run: 7.28 GB. |

### Second-opinion metric (not a gate)

The tables were tuned against the metric that judges them. To check that, libjxl's reference `ssimulacra2` CLI (CPU,
libjpeg-based decode, ICC-aware) was run on the 19 holdout Couple files.

| | Reference CLI score: min / median / mean | v2 engine score: mean |
|---|---|---|
| d42cb2d | 73.16 / 73.79 / 73.79 | 74.14 |
| eng-v3 | 73.02 / 73.71 / 73.67 | 74.13 |

- Per photo, eng-v3 is −0.12 against d42cb2d at the median, with a range of −0.74 to +0.35.
- The worst case, 0042, is mostly the baseline overshooting (engine 74.65 → 74.08).
- The engine's lead over the reference CLI grows from +0.35 to +0.46 on average. So about 0.1 point of the Couple
  saving is the tuned tables suiting v2's metric and decoder more than the reference implementation. That is small, but
  it is the measurable form of the "tuned against the judge" risk.

## 3. The integrator's claims, one by one

| Claim | Verdict |
|---|---|
| Holdout bytes: Couple 48,365,625, Website 5,555,974, Social 5,319,707, Archive identical | **Confirmed** to the byte. |
| Every photo ≥ target | **Confirmed** with d42cb2d's metric: holdout 57/57 and wedding Couple + Website 1070/1070. Social and Archive on the wedding were not re-run. |
| Couple probes 1.95 → 1.84; G1 passes | **Confirmed**. `LiveEngineTests` passed in the full run. |
| Couple wall −59 %, CPU −31 % | **Confirmed**: −58 % and −30 %. |
| All four: wall −3 % | **Not reproduced**: +0.3 % here (means of two pairs). Read it as "no change". |
| All four: CPU +6.4 % | **Confirmed**: +6.1 %. |
| Couple peak footprint higher (5.2–5.6 GB) | **Confirmed**: 5.18–5.34 GB, against 3.84–3.96 GB for d42cb2d. |
| All four: peak footprint not higher | **Confirmed**: 6.87–6.88 GB, against 6.92–7.09 GB. |
| Archive byte-exact, unchanged | **Confirmed**, including reconstruction with the external `djxl`. |
| Repeated runs identical | **Confirmed**. |
| Everything off = d42cb2d, 76/76 | **Confirmed**. |
| 376 tests in 68 suites pass, zero warnings | **Confirmed** in a fresh clone with freshly built codecs. |
| Wedding sources unchanged | **Confirmed** independently, before and after the verifier's wedding run. |
| Wedding Couple / Website bytes | **Confirmed** to the byte by a separate run. Social and Archive on the wedding were not re-run. |
| "Every new checkout runs `Scripts/build-codecs.sh`" | **True and needed.** The code is reproducible, but the lock hash is not under every group id (§5). |
| Estimate "5.3 s at load 10" | **Incomplete**: it is a regression the report does not call one. `hmb estimate`, eng-v3 against d42cb2d, back to back: default deliveries 4.82 / 4.90 s against 4.54 / 4.45 s (+8 %, load 14–17). Website alone 4.70 s against 3.52 s (+34 %, from WebP method 6). All four 5.19 / 5.21 s against 4.02 / 4.03 s (+29 %). The §3.10 budget is ≤ 5 s on a quiet machine for the default deliveries; eng-v3 is under it here even under load, but with less headroom. |

## 4. Code review (diff d42cb2d..2702cb6, engine and C bridge)

- **Tokeniser patch** (`Vendor/patches/libjxl/0001`): checked against upstream's loops.
  - The masks match the upstream tests: `|c| ≥ 2^Al` ⇔ `(|c| >> Al) ≠ 0`. `vabsq_s16(INT16_MIN)` still reads as non-zero.
  - The EOB and run bookkeeping matches upstream in the first scan (`last < Se` ⇔ `r > 0`) and in refinement scans
    (r accumulated across `absval > 1`, plus the trailing `Se − prev`).
  - Empirically byte-identical (the all-off run above).
- **Scan post-pass** (`hmb_jpeg_optimize_scans` / `hmb_jpeg_rewrite`).
  - Marker walking is bounds-checked, and jpegli errors go through `setjmp`, with both objects destroyed.
  - The script is a legal progressive script of ≤ 15 scans. Interleaved DC is used only without subsampling, as in jpegli.
  - The leading APPn/COM run is copied verbatim; inputs with APPn after DQT are declined.
  - The decoder independence of the scan script was checked with djpeg and ffmpeg above.
- **Mosaic scan choice.** The proxy encodes in `MosaicSearch` run sequentially, so the first mosaic per subsampling
  that sets `scanChoices` is deterministic. Full-size probes are encoded in the chosen script and delivered as scored
  (E3 holds for full size).
- **DirectSearch post-pass.**
  - The lossless rewrite is kept only after ImageIO decodes both files to identical pixels.
  - Zeroing candidates are built from the scored bytes, scored as delivered, and kept only if they pass and are smaller.
  - `ProbeRecord.bytes` is computed from `data`, so the size comparison after the rewrite is correct.
- **Unlocked small scores** (`MetricLane`).
  - Working sets come from the pool under its lock, references are read-only, and `MTLCommandQueue` is thread-safe.
  - The shared state is statistics only, behind `statsLock`.
- **Threaded JXL.** Per-call pthreads, joined in the call. The shared work counter is atomic. The arena slots that
  helper threads adopt are mutex-protected. Output does not depend on the thread count (archive SHA-identical).
- **Memory plan.** A lossy-only job now gets 8 workers × 8 full-size slots (model 128 B/px ≈ 5.8 GB at 45 MP). The
  measured 5.17–5.34 GB stays under it. Smaller Macs give up slots first (test `lossyOnlyJobsGiveEveryWorkerAFullSizeSlot`).
- **XMP minifier.** A packet is minified only when CGImageMetadata reads back the same tags and values; packets with
  XML literals are left alone. Cleared.
- **Nits, not changed.** `#include <algorithm>` appears twice in `jpegli.cc`. `Spans.measure` wrappers stay in the hot
  path, though they cost one flag check when off.

**No real defect found, so no fix was committed.**

## 5. Remaining risks

1. **Tuned against the judge.**
   - Full-size tables are fitted on one camera and one wedding with v2's metric.
   - The reference CLI shows eng-v3's Couple about 0.1 point (worst photo −0.74) less favourable than v2's metric says.
   - Before Social or Couple sit at the floor for a client, an owner should look at a different camera (and a
     non-wedding set).
2. **Floors with almost no margin.**
   - Social median 85.02 with a minimum margin of +0.0018; wedding Couple minimum margin +0.0002.
   - That is by design (the search stops at the target), but any metric or decoder drift now shows up as files below
     target.
   - Rerun `ScanScriptEquivalenceTests`, `EncoderGoldenTests` and the holdout gate after every macOS or toolchain update,
     as D-ENG-11 says.
3. **Codec lock hash is environment-dependent.**
   - The cause predates this branch (main has it too); eng-v3 now depends on a rebuilt library.
   - `libtool -static` records each object's group id in the ar headers. A checkout under a `wheel`-owned directory
     (`/tmp`, `/private/var`, some CI setups) builds an object-identical library with a different SHA-256. The script
     then silently rewrites `Vendor/codecs.lock`.
   - Fix later: normalise uid/gid in the merged archive (or `chgrp` the inputs) and re-pin.
4. **Estimate time.** +8 % on the default deliveries and +29 % on all four, from WebP method 6. Still under the 5 s
   budget here, but with less headroom.
5. **Couple's Package footprint.** +1.3 GB (≈ 5.2–5.3 GB at 8 slots). This is within the 8 GB budget; on a 16 GB Mac
   it is half the RAM.
6. **SPEC §3 drift** (E1 AQ, E2 4:4:4-first for resized targets ≥ 80, §3.5 WebP method, §3.6 threads, Social as a
   scan rewrite). This is recorded in D-ENG-11; SPEC.md itself is still unedited and should be updated by the lead at
   merge.

## 6. Recommendation

**Merge eng-v3** (fast-forward of main to 2702cb6 + this report).

- Couple is −3.7 % smaller and −58 % faster; Website is −11 % and Social −12 %. Archive is untouched.
- Quality, determinism, source safety and compatibility were each verified independently with baseline code and
  external decoders. Every part can be switched off back to d42cb2d byte for byte.
- On merge, communicate two things: every checkout must run `Scripts/build-codecs.sh`, and four-delivery wall time is
  unchanged (CPU +6 %), not −3 %.
