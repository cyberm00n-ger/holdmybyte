# Variant "speed": the same outputs, faster

Branch `eng-speed` (worktree `hmb-eng-speed`), base `main` at d42cb2d. The goal was to cut wall time with
**byte-identical outputs**, while keeping memory at or below 8 GB. Every number below is release `hmb compress` under
`/usr/bin/time -l`, run A/B back to back in the same session against the baseline binary built from d42cb2d.
Each delivered file was hashed with SHA-256.

**Machine:** MacBookPro18,4 (M1 Max, 10 cores, 64 GB). It was shared with 4 other agents and never quiet: the
1-minute load ran from 8 to 108. A load of ≥ 30 makes every absolute time an upper bound, so read the relative
numbers.

**Wedding runs:** the full wedding ran only for the final candidates, announced here: 3 four-delivery A/B pairs and
1 Couple's Package pair, at 14:33–15:25 and 15:32–16:08. Outputs went to
`~/Library/Application Support/holdmybyte-dev/runs/speed-*` and were deleted after hashing. Afterwards, `shasum -a 256`
of all 535 sources matched `runs/wedding-sha256-before.txt`.

## Result

| Run | Build | Bytes | Score min / median | Probes mean / max | Wall | CPU user + sys | Peak footprint / RSS | Load (1 min) before → after |
|---|---|---|---|---|---|---|---|---|
| Holdout, Couple, ×3 | baseline | 50,239,686 | 74.007 / 74.105 | 1.95 / 3 | 15.13 / 15.64 / 14.35 s | 30.4 + 7.2 s | 3.90 / 3.73 GB | 10.4 → 8.8 |
| | **speed** | **identical (19/19 SHA-256)** | identical | identical | **7.22 / 6.95 / 6.97 s (−53 %)** | 23.6 + 7.4 s (−18 %) | 5.38 / 3.77 GB | 8.9 → 9.2 |
| Holdout, all four, ×2 | baseline | 374,872,420 | as below | | 21.33 / 21.74 s | 109.8 + 13.0 s | 7.17 / 6.81 GB | 9.2 → 11.6 |
| | **speed** | **identical (76/76)** | | | **18.78 / 19.01 s (−12 %)** | 106.3 + 12.3 s (−3 %) | 6.95 / 5.33 GB | 10.0 → 14.3 |
| Wedding, Couple | baseline | 1,352,439,246 | 74.000 / 74.111 | 1.96 / 3 | 383.7 s (0.72 s/photo) | 855.8 + 204.0 s | 4.24 / 4.21 GB | 14.0 → 7.6 |
| | **speed** | **identical (535/535)** | identical | identical | **189.1 s (0.35 s/photo, −51 %)** | 780.0 + 236.3 s (−4 %) | 5.98 / 4.39 GB | 7.5 → 12.4 |
| Wedding, all four | baseline | Couple 1,352,439,246 · Website 163,408,108 · Social 163,455,205 · Archive 8,559,293,161 | Couple 74.000 / 74.111 · Website 70.002 / 70.577 · Social 85.001 / 85.192 · Archive 535/535 byte-exact | 1.96 · 2.87 · 4.04 | 587.4 s | 3142.7 + 457.2 s | 7.48 / 6.84 GB | 10.1 → 10.9 |
| | **speed** | **identical (2140/2140)** | identical | identical | **503.3 s (−14 %)** | 3005.1 + 350.5 s (−7 %) | 7.49 / 6.03 GB | 8.2 → 16.0 |
| Wedding, all four, high load | baseline | identical | | | 1271.7 s | 3702.5 + 514.5 s | 7.34 / 7.00 GB | 53 → 41 (5 min 75 → 67) |
| | speed | identical | | | 629.7 s (−50 %) | 3168.4 + 415.5 s (−15 %) | 7.71 / 6.25 GB | 28 → 16 |

On the high-load pair the candidate ran at a lower load than the baseline, so that pair overstates the gain. The
four-delivery row above it (15:32) was measured at equal load.

**The scores did not move.** Every score, probe count, byte count and file is the baseline's. The scorer is still
v2's own: ImageIO decode of the delivered bytes plus the Metal SSIMULACRA2 port.

**Against the target (≥ 30 % less wall time, byte-identical, ≤ 8 GB):**
- **Couple's Package: met.** The holdout dropped 53 % and the wedding 51 %, to 0.35 s/photo against JPEGmini's
  0.42 s/photo. All outputs are identical. The peak footprint went from 3.9 to 5.4–6.0 GB, still under 8 GB.
- **All four deliveries: not met.** The gain is 12–14 % at equal, low load, with no extra memory (7.49 vs 7.48 GB).
  Under heavy contention it is larger: −50 % on an unequal-load pair, −39 % on 60 wedding photos at load 70 → 95. The
  reason is that the four-delivery job is now CPU-bound, and 48 % of its CPU time is the archive (see below).

## What changed, in order of effect

| Commit | Change | Effect | Why the outputs cannot change |
|---|---|---|---|
| 8403440 | **Full-size search slots sized by the memory plan.** A Couple's Package job ran 8 workers but only 3 full-size searches; 5 workers waited, and 2.4 of 10 cores were busy. `MemoryPlan` now gives every lossy worker a slot while the model fits, and otherwise drops slots to the old 3 before it drops a worker. `MetricLane` slots and decode slots are counting gates set per job. `EngineOptions.maxLiveReferences` became optional (nil means "from the plan"). | Most of the Couple gain: holdout 22.0 → 14.2 s on this change alone | Scheduling only. Each photo's search is deterministic. |
| 8403440 | **Zero-copy candidate decode.** `ImageIODecoder` wraps ImageIO's own RGBX buffer (`CGImage.dataProvider.data`) in a `PixelImage` instead of drawing a copy. This applies only when the layout is exactly 8-bit RGBX in an RGB colour space; anything else is rasterized as before. | −10 % CPU on Couple, −180 MB per decode | Drawing that layout 1:1 into its own colour space with the copy blend mode is a plain copy. Verified byte-equal. |
| 8403440 | **Proxy scan script for the search mosaic.** The mosaic is only scored, never delivered. It is now encoded with 4 progressive scans instead of level 2's 15 (`HMB_JPEGLI_SCAN_PROXY`, `JPEGEncoding.encodeForScoring`). | Mosaic encode −19 %, decode −35 % | jpegli's quantisation ignores the scan script, and ImageIO's progressive decoder rebuilds the same pixels from the same coefficients. `ScanScriptEquivalenceTests` checked this on 900 pairs: 25 photos × {mosaic, 1440 px} × 9 distances × 4:2:0/4:4:4. A baseline (non-progressive) re-encode does **not** decode to the same pixels in ImageIO (different decoder path), so it is not used. |
| 8403440 | **libjxl transcode and verification on up to 4 threads.** This is a custom `JxlParallelRunner` built on per-call pthreads; the helper threads adopt the caller's arena slot (`hmb_arena::Adopt`), so D-ENG-10 memory still holds. `HMB_JXL_THREADS` overrides the count. | Shorter archive items and tail. Small on a quiet machine. | libjxl output does not depend on the thread count (checked with cjxl 0/2/4/8 threads and on all 535 wedding archives). |
| f334160 | **Small scores outside the metric lock.** Mosaic and ≤ 3 MP live-reference scores (~12 per photo) no longer queue every worker on one lock; their working sets are pooled per caller (up to 8). **The deferred 45 MP score** builds the reference pyramid and scores in one command buffer, so it waits for the GPU once instead of twice. | 60 wedding photos, Couple: 35.9 → 30.7 s | Same kernels, same buffers, same order. Concurrent scores are bit-identical (METRIC.md). |
| 63e6d63 | **jpegli codec patch** (`Vendor/patches/libjxl/0001-jpegli-tokenize-masks.patch`, applied by `Scripts/build-codecs.sh`). The progressive AC tokenisers find the coefficients that matter through two 64-bit NEON masks per block instead of testing all 61 one by one. Tokenisation was 25.6 % of Couple CPU time. | Couple user CPU −14 % | Same tokens, refinement bits and counters, by construction. `EncoderGoldenTests` matched 784 jpegli outputs to the unpatched build by SHA-256: synthetic images, samples, mosaics, 45 MP sources, d 0.5–12, 4:2:0/4:4:4, level 2 and the proxy script. |
| (this commit) | The memory model's full-size search stays at 6 B/px. At 5 B/px the four-delivery job gets an 8th worker: 485 vs 560 s, but a 7.96 GB peak footprint. | Keeps the all-four memory at baseline | — |

**Diagnostics added:**
- `HMB_SPANS=<file>`: wall seconds, counts and page faults per span (decode, encode, scores, lane waits, Metal phases).
- `hmb` tuning knobs: `HMB_FULL_SLOTS`, `HMB_DECODE_SLOTS`, `HMB_JXL_THREADS`.

## Where the time goes now

These shares come from Time Profiler on the holdout.

**Couple's Package.** Before the change:
- jpegli encode: 53 % (tokenisation alone 25.6 %)
- ImageIO candidate decode: 44 % (progressive refinement decode 13 %, copies 12 %)
- Metal: under 2 %

After the change the photo is CPU-bound in encode and ImageIO decode. The decode is fixed, because it is the
metric's definition.

**All four deliveries:**

| Component | Share of CPU |
|---|---|
| Archive transcode | 30 % |
| Archive reconstruction (verification) | 18 % |
| jpegli | 18 % |
| ImageIO decode | 14 % |
| WebP encode | 12 % |

On a quiet machine the job keeps about 7 cores busy, so further wall time has to come out of CPU time.

## Risks

- **Codec pin.** `Vendor/codecs.lock` now pins the patched archive (`3e81407d…`). Every checkout must run
  `Scripts/build-codecs.sh`, which applies the patch. The rebuild here also used a newer local toolchain; its outputs
  were checked as identical (golden test + wedding SHA-256), but a different toolchain would need the golden test
  again. To run it, write the golden file with the old codecs, then compare (instructions in the test header).
- **Behaviour of other people's code that we rely on.** Two changes depend on facts we measured but do not own:
  - ImageIO's progressive decoder producing the same pixels for any scan script.
  - libjxl's thread-count independence.

  Both were checked on every holdout and wedding file and on the equivalence tests. A macOS update could change
  ImageIO; rerun `ScanScriptEquivalenceTests` after OS updates.
- **Memory.** Couple-only jobs now peak at 5.4–6.0 GB footprint instead of 3.9–4.2 GB: up to 8 concurrent searches,
  within the model's 6.06 GB. Four-delivery jobs are unchanged (7.49 GB). A Mac with less memory gets fewer slots
  first and fewer workers second.
- **Unlocked small scores.** `drainPools` no longer serialises with mosaic scores. A score in flight keeps its own
  buffers, so this is safe, but it is a change to the lane's contract (documented in `MetricLane.score`).

## Worth merging

All four commits on `eng-speed`:
- 8403440 slots + zero-copy decode + proxy mosaic + threaded JXL
- f334160 lane
- 63e6d63 jpegli patch
- the memory-model commit

The jpegli patch is self-contained (one file in `lib/jpegli/entropy_coding.cc`). It can be dropped independently by
removing `Vendor/patches/libjxl` and rebuilding the codecs; that gives back about −14 % Couple CPU.

## Not done / next candidates

- **Archive effort.** e7 vs e3: cjxl 0.12 gave identical bytes on a test photo, about 10 % faster. But libjxl's
  histogram parameters depend on the speed tier (`enc_frame.cc`), so identical bytes are not guaranteed. Not
  byte-identical by construction, so not taken.
- **Archive verification** (reconstruct + SHA-256, 18 % of four-delivery CPU) is the spec's guarantee and was kept.
- **sys time** is 10–20 % of CPU: zero-fill faults of ImageIO's decode buffers (~33 k faults per 45 MP decode). It
  comes partly from `MallocLargeCache=0` (D-ENG-10). It cannot be fixed from the engine without giving back memory.
- **jpegli per-probe work.** The colour transform, adaptive quantisation and DCT are recomputed for every probe of a
  photo. Caching them would cost ~270 MB per worker.
