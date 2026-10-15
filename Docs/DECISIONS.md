# Decisions

Append-only log of lead decisions after the five work packages merged. One short entry each: what was decided, why,
and where the evidence is. Never edit an entry; supersede it with a new one.

## D-ENG-1 · 2026-10-15 · G1 is measured at the v2-measured floor (engine lead)

**Decision.** G1's byte limit is the old engine *held to v2's own floor*: for each holdout photo, the smallest old
`squeeze` output (Classic, or `-t` raised in 0.05 steps) whose v2 score (ImageIO decode, Metal SSIMULACRA2) is ≥ 74.
Total **50,301,670 bytes** (was 50.31 MB = old + 1 % on the old engine's own scale). Mean full probes ≤ 2.2 and
"every photo ≥ target" are unchanged. Recorded in `Benchmarks/baselines.json` (`holdout.oldEngineAtV2Floor`,
per file `oldV2Score`, `oldAtV2Floor`, metadata bytes; `gates.G1.basis`).

**Why.** The old floors were set on libjpeg-turbo decoding; v2 decodes with ImageIO, which reads the same bytes
0.29 lower (METRIC §4). Re-scored with v2, 5 of the 19 old outputs are below 74 (73.77, 73.84, 73.88, 73.97, 73.998).
Comparing v2 at 74 with the old bytes would hold v2 to a stricter floor than the old engine. Re-running the old
engine (not modelling it) keeps the comparison honest: its own search overshoots when pushed (0014: 74.25 → 73.96,
74.3 → 75.70), +495 KB in total.

**Context numbers (holdout, not gates).**
- v2's metadata: Couple's Package keeps XMP and IPTC (spec, keepAll); the old engine dropped both. v2 writes
  991 KB of APPn/COM on the holdout vs 392 KB: +599 KB. Not subtracted from G1 (the stricter reading).
- Equal *per-photo* quality (jpegli at each old output's v2 score, dense live curves): 50.33 MB vs 49.81 MB. jpegli
  alone does not beat the old mozjpeg/quant-refine encoder photo for photo; v2 wins by landing closer to the floor.
- Perfect search (zero overshoot, interpolated 4:2:0 curves): 49.91 MB. Real jpegli has score steps of 0.3–1.3 at
  fixed distances (d 1.22–1.25, 2.065–2.117, 3.16–3.24, 3.40–3.49), so some overshoot is unavoidable.

## D-ENG-2 · 2026-10-15 · Candidates stay ImageIO-decoded (WP1 Q1, option a)

Keep SPEC E6: the metric reads candidates decoded by ImageIO. It is the lowest of the three readings (jpegli's decoder
reads +1.5, libjpeg-turbo +0.29), so "score ≥ floor" holds for Apple's decoder and, with margin, for browsers. No
floor is lowered; G1 is re-based instead (D-ENG-1).

## D-ENG-3 · 2026-10-15 · MosaicSearch aims on the exact mosaic (`.mosaicExact`)

Default `SearchConstants.aim = .mosaicExact` (Docs/ENGINE.md §3.2): predicted full score = mosaic score *at the same
distance* (encoded and scored, ≤ 6 cheap 2-MP evaluations per aim) + a per-photo bias (prior −1.1, slope −0.6 per
ln d, interpolated between the bracketing probes for the final step); margins 0 / +0.03, accept below +0.15, no probe
within 0.003 ln d of another, model-based first rescue. Probe budget unchanged (3 + 2 rescue per chroma, fail-open
4:4:4, keep-original). The §3.4 loop stays available as `.proxyCurve` with its constants. Evidence: live A/B on the
holdout (`SearchABTests`, ENGINE §3.4): 51.38 MB / 2.53 probes → 50.24 MB / 1.95 probes, 19/19 ≥ 74, outputs
identical between the A/B harness and the pipeline.

## D-ENG-4 · 2026-10-15 · Estimator: real search for resized deliveries (SPEC §3.10 deviation)

Resized deliveries are estimated by running the delivery's DirectSearch on each sample's variant (not one probe at
the prior × κ): the parameter that reaches 70/85 at 2560/1440 px differs from the full-size prior, and 3 of 19
holdout photos reach 85 at 1440 px only with 4:4:4, which no single 4:2:0 probe can see (website 1.315, social 1.434
→ 1.024, 1.038). Full-size JPEG aims the mosaic at T + margin − bias prior (couple 0.947 → 0.996). κ defaults stay
1.0 (fitted ratios within ±4 %). A sample's deliveries run in parallel. Cost: ~19 CPU-s for the holdout's
12 samples × 4 deliveries; 4.2–4.6 s wall at load 6–10 (release, incl. process start and scan).

## D-ENG-5 · 2026-10-15 · WebP prior refitted

`qPrior(T) = clamp(80 + 1.1·(T − 70), 5…100)` from the holdout at 2560 px (median q reaching T: 65 → 72, 70 → 80,
75 → 86, 80 → 90, 85 → 94). Website on the holdout: probes 3.42 → 2.74 mean, bytes +0.2 %.

## D-ENG-6 · 2026-10-15 · `hmb --workers` is honoured (WP5 Q3)

`hmb` reads `HMB_WORKERS` (set by `--workers`) and passes it as `EngineOptions.workerCount`; the app never sets it.
