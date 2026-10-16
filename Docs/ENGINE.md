# holdmybyte engine (WP2)

How the live engine turns a scanned wedding into verified deliveries. `Docs/SPEC.md` §3 is binding; this file
documents how WP2 implemented it, the constants in use and what was validated. Since the integration pass
(2026-10-15, branch `int-engine`) it also records the live fits and the search change of Docs/DECISIONS.md D-ENG-3…5.
Since the engine integration of 2026-10-16 (branch `eng-v3`, D-ENG-11) it also records the speed changes, the tuned
JPEG tables and the post-pass (§3.5, §8, §10). Since D-ENG-13 (branch `eng-highest`) full-size JPEG at fixed floors
≥ 85 runs in a high-target mode (§3.2). Since D-ENG-12 every delivered JPEG is also scored on libjpeg-turbo's
pixels and the lower score counts (decoder guard, §3.6); `eng-r2` (D-ENG-14) integrates both (§11).

Code: `Sources/HMBEngine/{Search,Pipeline,Jobs,IO,Metadata,Estimate,Service}`.
Tests: `Tests/HMBEngineTests/Pipeline` (fakes; live tests gated on `EnginePrimitives.live()` plus `HMB_HOLDOUT` /
`HMB_TEST_PHOTOS`).

## 1. Map of the code

| Component | File | Spec |
|---|---|---|
| `LiveEngine: EngineService` | `Service/LiveEngine.swift` | §3.1 |
| `EngineOptions` (workers, constants, test hooks) | `Service/EngineOptions.swift` | — |
| `PreflightCheck` | `Service/PreflightCheck.swift` | §3.1, S5 |
| `CompareLoader` (`comparePair`) | `Service/ComparePairs.swift` | §3.1 |
| `Scanner` | `IO/Scanner.swift` | §3.8 |
| `OutputWriter`, `SourceGuard` | `IO/OutputWriter.swift` | §3.8 |
| `Targets`, `SearchConstants`, probe types | `Search/SearchModel.swift` | §3.3–3.5 |
| `MosaicSearch`, `ProxyCurve` | `Search/MosaicSearch.swift` | §3.4 |
| `DirectSearch` | `Search/DirectSearch.swift` | §3.5 |
| `PhotoPipeline`, `DeliveryPlan`, `SourceAvailability` | `Pipeline/PhotoPipeline.swift` | §3.3 |
| `MetricLane` | `Pipeline/MetricLane.swift` | §3.9 |
| `JXLArchive` | `Pipeline/JXLArchive.swift` | §3.6 |
| `MetadataEditor`, `TIFFDocument`, `JPEGContainer` | `Metadata/*` | §3.7 |
| `JobRunner`, `Journal`, `ProgressCoalescer`, `PhotoRate` | `Jobs/*` | §3.8 |
| `WorkerPool` (two kinds, admission), `CancelToken`, `Locked` | `Jobs/Concurrency.swift` | §3.9 |
| `MemoryPlan` (workers, archive lanes), `MemoryTrace` (`HMB_MEMTRACE`) | `Jobs/MemoryPlan.swift`, `Jobs/MemoryTrace.swift` | §3.9 |
| Codec arenas (libjxl, jpegli working memory) | `CHMBCodecs/arena.cc` | §3.9 |
| `Estimator`, `LearnedEstimates`, `DeliveryKind` | `Estimate/Estimator.swift` | §3.10 |
| `JPEGTuning` (table shape per search), `JPEGKnobs`, `TunableJPEGEncoding` | `Search/SearchModel.swift`, `Codecs/JpegliEncoder.swift` | §3.4/§3.5, D-ENG-11 |
| `DecoderGuard`, `IslowDecoder` (`hmb_jpeg_decode_islow`: libjpeg-turbo's pixels from jpegli's coefficients) | `Pipeline/DecoderGuard.swift`, `Codecs/IslowDecoder.swift`, `CHMBCodecs/jpegli.cc` | E6, D-ENG-12 |
| High-target mode (`MosaicSearch.searchHigh`, `SearchConstants.highMode`, `Targets.highPrior`) | `Search/MosaicSearch.swift`, `Search/SearchModel.swift` | §3.4, D-ENG-13 |
| `JPEGPostPass` (scan script, lossless rewrite, ±1 zeroing), `WebPTuning` | `Codecs/JPEGPostPass.swift`, `Codecs/LibWebPEncoder.swift` | §3.5, D-ENG-11 |
| `XMPMinify`, `XMPLayout` | `Metadata/XMPMinify.swift` | §3.7, D-ENG-11 |
| `Spans` (`HMB_SPANS`, wall time per pipeline span) | `Jobs/Spans.swift` | — |

## 2. Per-photo pipeline (§3.3)

One worker thread takes one photo end to end:

1. `inspect(url)`. A failure is classified: source root gone → the job pauses with `.sourceUnavailable(volume)`;
   file gone but root present → `.failed(.sourceMissing)`; otherwise `.failed(.unreadable)` for every delivery.
2. CMYK → every lossy delivery `.failed(.cmykUnsupported)`; the archive is still attempted.
3. The source is decoded at most once, lazily (an archive-only job never decodes). Since D-ENG-10 the archive is a
   separate work item of the photo (§8), so "execution order" below applies to the lossy deliveries. Features are computed only
   when a Balanced delivery (or the chroma gate) needs them.
4. Deliveries run in execution order: resized lossy by ascending long edge → full-size lossy → archive.
   Variants are cached per photo: one sRGB conversion, one resize per (colour, long edge).
5. Before a lossy search starts, the delivery's **final metadata** is built (§5) and passed to every probe, so the
   bytes that are scored are the bytes that are written (E3). Proxy (mosaic) encodes carry no metadata.
6. Each result is journaled right after its file's rename; references and variants die with the photo.

Per-delivery failures become results; only `JobCancelled` (pause/stop) and `JobInterruption` (drive gone, disk
full, not writable) leave the pipeline and wind the job down. An unexpected error records the rest of the photo
as `.encodeFailed`, so no pair is ever silently missing.

## 3. Search

### 3.1 Targets and priors

| Quality | Target |
|---|---|
| Highest / High / Web | 90 / 85 / 70 (fixed floors) |
| Balanced | `p50 < 4.5 ? 74 : clamp(88 − 0.62·p50, 75…87)` (verbatim ClassicTarget) |

- `prior(T) = exp(0.693 + 0.06·(74 − T))` (74 → 2.00, 85 → 1.03, 90 → 0.77) — **unchanged from §3.4**.
  The holdout replay (§3.4 below) shows it needs no refit for Balanced; a refit on the full wedding is pending the
  live primitives.
- `qPrior(T) = clamp(80 + 1.1·(T − 70), 5…100)` — **fitted live** on the holdout at 2560 px (median q at which each
  photo reaches T: 65 → 72, 70 → 80, 75 → 86, 80 → 90, 85 → 94). The spec's 75 at T = 70 was 5 q low. A/B on the
  holdout Website delivery (release `hmb compress`, load 5–7): probes 3.42 → **2.74** mean (max 4 → 5), 6.564 → 6.578 MB
  (+0.2 %, different landing points), every photo ≥ 70 (D-ENG-5).
- `prior(T)` for JPEG is unchanged. Resized JPEG lands well below it at high targets (1440 px, median d reaching 85:
  0.60 vs prior 1.03; 3/19 photos need 4:4:4); DirectSearch's secant finds it in 3.6 probes on average (Social,
  holdout). Not refitted: one size and one target are too little data for a size-dependent prior.

### 3.2 `MosaicSearch` (full-size JPEG, image ≥ 2048×1024)

Two aims share the policy around them (rescue budget, fail-open 4:4:4, keep-original, chroma gate):
`SearchConstants.aim = .mosaicExact` (**default since D-ENG-3**) and `.proxyCurve` (the §3.4 loop, below).

#### `.mosaicExact` (default)

Why: jpegli's score falls in **steps** at fixed distances for every photo (largest drops on the holdout between
d 1.221–1.252, 2.065–2.117, 3.158–3.238 and 3.404–3.490, 0.6–1.6 points each), and the mosaic steps at the same
distances. A piecewise-linear curve through 3 mosaic points bridges the steps, so the bias it measures at one probe is
wrong at the next. Measured on dense live curves (`HoldoutMeasureTests`), **full − mosaic at the same distance** is
nearly constant per photo: sd 0.10–0.36 over d 1.4…3.0, about −0.6 per ln d, holdout median −1.1 (range −1.9…−0.1).

```
x = ln d, multiples of 1e-4 (the solver's and the probes' distances are identical → deterministic)
m(x)    : mosaic encoded at d (no markers), scored against the mosaic reference; cached per search
bias(x) : before any probe            −1.1 (exactBiasPrior)
          probes on one side of T     b_ref + (−0.6)·(x − x_ref), ref = probe closest to T   (exactBiasSlope)
          pass P and fail F, x_P<x_F  linear between b_P and b_F                         (final-step interpolation)
          with b_k = s_k − m(x_k) measured at every full probe
solve(g): largest x in [lo, hi] with m(x) + bias(x) ≥ g: bracket from cached mosaic points (3 seeds at
          prior·{0.8, 1, 1.25}), extend by ≥ 0.02 steps, regula falsi (safeguarded 20 %) until the bracket is < 0.004
          or 6 evaluations (exactSolverEvals) → the passing end, else the interpolated root
probe 1 : solve(T + 0)                                        (exactFirstMargin)
loop    : while probes < MAX_FULL (3)
            stop if a passing probe has s − T < 0.15          (exactStop)
            lo = max passing x + 0.003, hi = min failing x − 0.003 (exactMinStep); stop if lo > hi
            x = solve(T + 0.03) in [lo, hi]                    (exactMargin; + exactFailStep·(fails − 1), default 0)
rescue  : nothing passed → first rescue probe solve(T + 0.3) below the smallest failing x (exactRescueMargin),
          then d × 0.8; never below D_MIN; at most RESCUE = 2 (replaces the generic ×0.8 rescue for this aim)
```

Cost: 3 seeds + ≤ 6 mosaic evaluations per aimed probe (holdout mean **12 mosaic encodes per photo**, ~0.03 s each on
2 MP) against one full probe saved (~0.7 CPU-s: encode 0.39 + decode 0.28 + score 0.05).

**Since D-ENG-11** every full-size probe and mosaic encode uses `SearchConstants.jpegTuning = JPEGTuning.fullSize`
(§3.5): the loop above is unchanged, only the tables around d are reshaped (landing distance median 1.90 → 2.12, the
full − mosaic bias unchanged at −1.03). The mosaic is encoded with the proxy scan script (`encodeForScoring`, 4 scans,
same coefficients as level 2), and the first mosaic encode of each subsampling also picks the per-component AC scan
script (`JPEGPostPass.chooseScans`) that every full probe of that subsampling is then encoded with — the delivered
bytes are still exactly the scored bytes (E3).

#### High-target mode (D-ENG-13, `Docs/variants/highest.md`)

Full-size JPEG with a **fixed** floor (High 85, Highest 90; never Balanced, so Couple's Package is unchanged):

```
mode(T) : T < highCompareFrom (85)                 → tuned search only (everything above)
          highCompareFrom ≤ T < highFirstFrom (85) → tuned and high mode, smaller verified result (empty by default)
          T ≥ highFirstFrom (85)                   → high mode; the tuned search only if it reaches nothing
high    : tables JPEGTuning.highTarget = fullSize shape (chroma × 0.65, tilt 1.6, DC × 0.8), adaptive quantisation OFF,
          progressive (scan script per subsampling from its own first mosaic encode, as above)
          4:2:0: the .mosaicExact loop with prior Targets.highPrior(T, 4:2:0) = 0.39·e^{0.164(90−T)},
                 bias prior −0.3 (highBiasPrior), rescue floor d 0.3 (highDMin)
          4:4:4: if 4:2:0 reached nothing, or T ≥ high444From (89) and the mosaic does not rule it out:
                 b = s(best 4:2:0) − m420(d_best); solve the 4:4:4 mosaic for T + exactFirstMargin − b (start d_best·1.28,
                 steps 0.08, bisection to 0.01, ≤ 8 evaluations); skip when mosaic bytes(4:4:4 there) >
                 1.03 × mosaic bytes(4:2:0 at d_best) (high444Skip); else the .mosaicExact loop seeded at that point
                 with bias prior b
          result: smallest passing probe of both (every probe `highMode`, encoder "jpegli (high)")
```

Mosaic points are cached per (subsampling, distance) in the pipeline, so the preselection and the searches share
encodes. Holdout (release, back to back with main 66e3db0): Highest 191,497,771 → 182,337,941 B (−4.78 %, probes 2.26 →
2.74, 4 photos 4:4:4), High 102,245,961 → 98,776,135 B (−3.39 %, probes 2.00 → 1.74); every file ≥ the floor on ImageIO,
libjpeg-turbo minimum 89.82 / 84.85 (main 89.81 / 84.88). Annex K tables (`HMB_HIGH_TABLES=annexk`, +3.7 %) and
baseline coding (`HMB_HIGH_SCAN=baseline`, −8.6 % on ImageIO but every file 89.2–89.8 under libjpeg-turbo) are
switches, not defaults (D-ENG-13). `HMB_HIGH=off` reproduces main byte for byte; `HMB_HIGH_BAND=<from>,<first>` sets the
band. The high mode's results go through the decoder guard like every full-size result (§3.6): at these targets
jpegli 4:2:0 without AQ is not always read higher by libjpeg-turbo (holdout gap down to −0.075), see §11.

#### `.proxyCurve` (the §3.4 loop)

Constants (binding for this aim, unchanged): M0 = 0.6, M1 = 0.15, BIAS = −1.5, STOP = 0.5, MAX_FULL = 3, RESCUE = 2,
D_MIN = 0.5; bisection over ln d ∈ [ln 0.3, ln 8], 60 iterations.

```
proxy  : mosaic encoded at prior(T)·{0.8, 1.0, 1.25} (no markers), scored against the mosaic reference
curve  : s_m(ln d) piecewise linear through the 3 points, linear extrapolation outside
d1     = exp(inv(T + M0 − BIAS))
loop   : while probes < MAX_FULL
           stop if a passing probe has s − T < STOP
           bias = s_last − s_m(ln d_last); ld = inv(T + M1 − bias)
           clamp above max passing ln d + 0.003, below min failing ln d − 0.003
           both sides known: stop if the bracket is < 0.01 wide; outside the bracket → its midpoint
result : smallest passing probe
rescue : no pass → ≤ 2 probes at d ← min failing d · 0.8 (not below D_MIN; stops at the floor)
fail-open: still no pass → the whole search again with 4:4:4 (proxy recomputed in 4:4:4)
keep-original: JPEG source ∧ keepProfile ∧ (no pass ∨ best ≥ 0.95 · source bytes)
```

Implementation guards (no effect on normal photos): every distance is clamped to [0.1, 25]; a step that lands on an
already probed distance ends the loop. The E2 chroma gate (`SearchConstants.chromaGate`, default **off**) searches
4:4:4 as well when `chromaEnergy ≥ 2.42` and keeps the smaller passing result.

Budget: 3 (4:2:0) + 2 (rescue) + 5 (4:4:4 fail-open) = 10 full probes worst case. `PhotoResult.probes` counts
every full-resolution probe (proxy encodes are not counted).

### 3.3 `DirectSearch` (resized deliveries; full-size images below 2048×1024)

The parameter is mapped to an axis on which the score decreases: JPEG x = ln d, WebP x = −q.

| | JPEG | WebP |
|---|---|---|
| start | ln prior(T) | −qPrior(T) |
| range | ln 0.5 … ln 25 | q 0 … 100 |
| quantum | 0.001 (ln d) | 1 (integer q) |
| default slope until a secant exists | −10 score per ln d | +0.5 score per q |
| max step | 1.0 ln d | 30 q |

Loop: probe; stop at the first passing probe with s − T < stop (WebP `directStop` 1.0, JPEG `directStopJPEG` 0.5,
D-ENG-8) or after 5 probes; otherwise a secant step on the two latest probes (default slope if the secant is not
decreasing) aimed at T + stop/2, clamped into the
passing/failing bracket (midpoint when outside; stop when the bracket is one quantum wide). Values within one
quantum of a range bound snap to that exact bound.

- **JPEG:** 4:2:0 search → if nothing passes, an explicit 4:2:0 probe at d = 0.5 → if still nothing, a 4:4:4 search
  from d = 0.5. Nothing at 4:4:4 → `.failed(.qualityUnreachable)` (logged). Full-size small images also apply the
  keep-original rule. **Since D-ENG-11:** targets ≥ `direct444From` (80) search 4:4:4 from the prior, then d = 0.5
  (no 4:2:0 at all; Social at 85 is 4:4:4); every DirectSearch JPEG uses `JPEGTuning.resized` (chroma 0.7 × d,
  adaptive quantisation off); the result then gets the post-pass (§3.5).
- **WebP (D-ENG-11):** `WebPTuning.default` = method 6, loop-filter strength 40, sharpness 7 on WEBP_PRESET_PHOTO
  (was method 4 and the preset's filter); `HMB_WEBP=spec|m6` for A/B runs.
- **WebP:** if nothing passes, q = 100 is probed explicitly; if that fails too, the delivery falls back to the JPEG
  search on the same variant (`encoder = "jpegli (fallback)"`, extension `.jpg`). The sharp-YUV preparation is done
  once per (photo, delivery).
- **Stop window (D-ENG-8, `DirectSearchABTests`, holdout, release-equivalent live primitives, load 10–24):** Social
  (JPEG 1440 ≥ 85) 1.0 → 0.5: 6.158 → 6.016 MB (−2.3 %), overshoot 0.44 → 0.24, probes 3.58 → 3.95 (0.6, 0.4: 6.039 /
  6.005 MB). Website (WebP) gains nothing from a tighter window (0.4–0.6: +0.7–1.0 %, more probes): integer q steps.

### 3.4 Validation (fakes, measured curves and live A/B)

The tables in this section are the measurements behind D-ENG-3 and use jpegli's own tables; the D-ENG-11 tuning and
its search A/B are in §3.5 and `Docs/variants/search.md`.

**Live A/B (authoritative, D-ENG-3).** `SearchABTests` (opt-in: `HMB_SEARCH_AB='name:key=value,…;…'`) runs the real
`MosaicSearch.search` per variant on the 19 holdout photos with live probes (jpegli + Couple's Package markers +
ImageIO decode + Metal SSIMULACRA2), memoising probes per distance across variants. The `.proxyCurve` row reproduces
the pipeline's `LiveEngineTests` run byte for byte, and the shipped row equals the pipeline's run after the change
(50,239,686 bytes). Release build, load 5–17 (`uptime` 20:48–20:56). Targets: 74 for all 19 (smooth regime).

| Variant | Bytes | Probes mean / max | Overshoot mean / max | Mosaic evals / photo |
|---|---|---|---|---|
| `.proxyCurve`, §3.4 constants (before) | 51.379 MB | 2.53 / 3 | 0.535 / 2.54 | 3 |
| `.mosaicExact`, margins 0 / 0.1, stop 0.3 | 50.472 MB | 2.00 / 3 | 0.201 / 0.56 | 11.4 |
| + no probe within 0.003 ln d (wasted same-step probes) | 50.497 MB | 1.74 / 3 | 0.208 / 0.65 | 11.3 |
| + margin 0.05, stop 0.2 | 50.410 MB | 1.74 / 3 | 0.204 / 0.65 | 11.7 |
| **+ margin 0.03, stop 0.15 (shipped)** | **50.240 MB** | **1.95 / 3** | **0.137 / 0.65** | 12.0 |
| shipped, stop 0.1 | 50.213 MB | 2.05 / 3 | 0.134 / 0.65 | 12.3 |
| shipped, stop 0.2 | 50.280 MB | 1.84 / 3 | 0.150 / 0.65 | 11.4 |
| shipped, bias prior −1.0 / −1.2 | 50.286 / 50.345 MB | 2.05 / 1.84 | 0.177 / 0.191 | 12.5 / 11.7 |
| shipped, bias slope −0.3 / −0.9 | 50.331 / 50.266 MB | 1.89 / 1.95 | 0.174 / 0.162 | 12.2 / 11.9 |
| shipped, first margin +0.1 / −0.1 | 50.345 / 50.286 MB | 1.84 / 2.05 | 0.191 / 0.177 | 11.7 / 12.5 |
| shipped, min step 0.002 / 0.004 / 0.006 | 50.261 / 50.285 / 50.519 MB | 1.95 / 1.95 / 1.68 | — | — |
| shipped, margin 0 (×0.8 rescue) | 50.558 MB | 2.05 / 4 | 0.241 / 2.11 | 12.1 |
| shipped, margin 0 (model rescue, shipped) | 50.276 MB | 2.05 / 4 | 0.151 / 0.65 | 12.3 |
| shipped, fail-step 0.12 / 0.2 | 50.321 / 50.337 MB | 1.95 / 1.95 | 0.168 / 0.173 | 12.1 |
| shipped, max 2 full probes | 50.366 MB | 1.89 / 3* | 0.182 / 0.65 | 11.7 |

\* includes a rescue probe. Neighbouring settings move the total by ±0.1 MB (noise of 19 photos); the shipped point is
in the middle of a flat region rather than the single best row. The remaining overshoot is mostly jpegli's steps:
0042 lands at 74.65 because the step at d ≈ 2.09 jumps from 74.65 to below 74. Below: perfect-search bound 49.91 MB
(interpolated curves, zero overshoot), old engine at the v2 floor 50.30 MB (G1, D-ENG-1).

Live pipeline after the change (`LiveEngineTests.holdoutBalanced…`, debug, load 5.3): **50.24 MB, 1.95 probes mean,
max 3, 19/19 ≥ 74**, wall 17.8 s (before: 51.38 MB, 2.53, 17.8 s at load 26).

**Earlier checks (fakes, curves from the v2 experiments; `.proxyCurve` unless noted)**

| Check | Result |
|---|---|
| **Holdout replay** — `MosaicSearch` on the 19 holdout photos, full-resolution scores/bytes interpolated in ln d between the measured jpegli 4:2:0 points of the v2 experiments, proxy from the measured grid mosaic (`HoldoutReplayTests`, numbers in `HoldoutCurves.swift`, anonymised h01…h19) | **49.74 MB** vs old engine 49.81 MB (−0.13 %), **1.95 full probes mean, max 3**, 19/19 ≥ target, overshoot mean 0.28 / max 0.47 — consistent with sim-B (2.0 mean, max 3) |
| Analytic family, 200 synthetic curves (targets 74…87, slopes 6…14 /ln d, proxy bias −1.5 ± 0.6, noise) | 0 failing results, mean 1.70 probes, ≤ 5 4:2:0 probes, no 4:4:4 when 4:2:0 reaches T |
| Keep-original threshold | triggers at best ≥ 0.95 × source, not 200 bytes below it |
| Fail-open | 4:4:4 only after 4:2:0 + rescue fail; ≤ 10 probes |

The replay's absolute bytes are only as good as the interpolation (the measured points mix two experiment runs, and
their scores are on the old libjpeg-turbo reading), which is why it is pinned to `.proxyCurve`: it predicted 49.74 MB,
the live run of the same algorithm gave 51.38 MB. The analytic family also runs with `.mosaicExact` (2.17 probes mean,
0 failing, ≤ 3 + 2 per chroma). The **live** gate is `LiveEngineTests.holdoutBalancedMeetsTargetsProbesAndBytes`:
every photo ≥ target, mean ≤ 2.2, max ≤ 5, total ≤ 50,301,670 bytes (D-ENG-1).

### 3.5 Table tuning and post-pass (D-ENG-11, branches `eng-search` and `eng-postpass`)

**Tables.** `hmb_jpegli_encode_opts` takes every table from jpegli's own `jpegli_set_distance` (same base matrices,
same 4:2:0 rescale, ≤ 255) and only changes which distance each part comes from; jpegli derives zero bias and AQ from
the final tables. Every output is a standard progressive JPEG. `JPEGTuning.jpegli` is the identity and byte-identical
to the frozen call.

| Tuning | Used by | Chroma tables | DC entries | Luma AC at f = row + col ≥ 4 | AQ |
|---|---|---|---|---|---|
| `fullSize` | MosaicSearch (Couple, High/Highest full), its mosaic, the estimator | d × 0.65 | d × 0.8 | × exp(1.6·(f − 3)/11), up to × 4.95 | on |
| `resized` | DirectSearch JPEG (Social, WebP fallback, small full-size) | d × 0.7 | jpegli | jpegli | **off** |

Found by a frontier survey over chroma ratio, sampling, AQ, luma/chroma tilt and DC ratio (`KnobSurveyTests`), then
confirmed with the real searches (`SearchABTests`, `DirectSearchABTests`): full size −3.4 % on the holdout, −3.6 % on
19 validation photos never used for tuning, −6.6 % at T 85; 4:4:4 at full size is +7 %, coarser chroma loses
everywhere. Resized: 1440 px T 85 −12.4 % with 4:4:4 + chroma 0.7 + AQ off (4:2:0 cannot reach 90 at 1440 px).
Details and the rejected settings: `Docs/variants/search.md`.

**Post-pass.** Lossless unless stated; every part has its own switch (`SearchConstants.optimizeScans`,
`.zeroingAttempts`, `.xmpLayout`, `WebPTuning`; `hmb`: `HMB_OPTIMIZE_SCANS=0`, `HMB_ZEROING=0`,
`HMB_XMP_LAYOUT=verbatim|minified`, `HMB_WEBP=spec|m6|postpass`).
- **Scan script, full size:** chosen per component from the first mosaic encode (four AC scripts: jpegli's
  `1-2, 3-63 Al 2→1→0`, `Al 1→0`, one `3-63` scan, one `1-63` scan; estimated from the coefficients with libjpeg's
  progressive token rules and optimal 16-bit Huffman codes), then used for every full probe. Same coefficients, so the
  scores are bit-identical and delivered = scored. −0.25 % (Couple); cost one coefficient read + estimate on 2 MP.
- **DirectSearch JPEG:** the final file is rewritten with the estimated script and kept only if ImageIO decodes it to
  identical pixels (else the scored bytes are kept and logged); then up to 4 rewrites that zero isolated ±1 AC
  coefficients (zigzag ≥ K, zero runs ≥ 2 on both sides, bisection over K) are **each re-scored** and the smallest
  passing one is delivered. Social −0.32 % + −1.82 % (on `eng-postpass`); the re-scores are counted in `probes`.
- **XMP** without layout whitespace under `removeLocation`/`removeAll` (only if CGImageMetadata reads exactly the same
  tags back; packets with `parseType="Literal"` are left alone); `keepAll` stays verbatim. −1.3 % on Website/Social.
- **Not adopted:** zeroing on full-size (−0.66 % more for ~6.7 s per 45 MP photo), the full rewrite at 45 MP (~0.55
  CPU-s per photo for −0.04 % over the mosaic choice), JXL effort 8/9 (−0.29 / −0.40 % at ×2.8 / ×18 time).

**Combined, holdout (release, A/B with d42cb2d):** Couple 50,239,686 → 48,365,625 B (−3.73 %), Website 6,265,646 →
5,555,974 (−11.33 %), Social 6,015,880 → 5,319,707 (−11.57 %), Archive identical. With every switch off the build
reproduces d42cb2d byte for byte, with only the post-pass on it reproduces `eng-postpass`, with only the tuning on
`eng-search` (19/19 SHA-256 each, `Docs/variants/eng-v3.md`).

### 3.6 Decoder guard (D-ENG-12, branch `eng-safety`; integrated in `eng-r2`, D-ENG-14)

ImageIO stays the scoring decoder (D-ENG-2). Browsers decode JPEG with libjpeg-turbo, whose pixels differ from
ImageIO's by up to ±0.5 points on the same file. `IslowDecoder` reproduces libjpeg-turbo's default decompressor
(ISLOW IDCT, fancy upsampling with context rows, `jdcolor.c` fixed-point colour) from jpegli's coefficients, in process,
pixel-identical to `djpeg` 3.2 (`IslowDecodeTests`); layouts other than 8-bit YCbCr 4:4:4 / 4:2:0 return nil and keep
the ImageIO score.

```
guarded(c) = ImageIO(c) < T or chroma not covered → ImageIO(c)
             else min(ImageIO(c), score(IslowDecoder(c), same reference))
DirectSearch (resized): every passing JPEG probe and post-pass rewrite is guarded (≈ 0.02 s per 1440 px decode)
MosaicSearch (full size): probes scored by ImageIO; the result r is guarded (≈ 0.4 s per 45 MP decode + one score);
             guarded(r) < T → the next-smallest passing probe the same way; none → the whole search again
             (tuned and high mode) with every passing probe guarded; mosaic points stay cached
modes      : .all (default) every JPEG; .chroma444 4:4:4 only; .off = eng-v3 (`HMB_DECODER_GUARD`)
```

The viewer decoder comes from the primitives (`EnginePrimitives.viewerDecoder`: `IslowDecoder` in `live()`, nil in
`fakes()`, whose "JPEGs" are not JPEGs, so fake-based tests run unguarded). The second decode takes the decode slot of
the first, after the ImageIO candidate is released. WebP is not guarded:
ImageIO's WebP pixels are libwebp's (19/19 identical). Audit tool: `DecoderAuditTests` (opt-in, `HMB_DECODER_AUDIT*`,
Couple / Website / Social / High / Highest folders, `HMB_DECODER_AUDIT_FAST=1` = in-process libjpeg-turbo only).

## 4. Writing, journal and resume (§3.8)

**Source protection.** `SourceGuard` stores the (device, inode) of every source file, every source root and every
source photo's folder. A target is refused if it, or any existing ancestor, is one of them. Identity comparison
covers symlinks (stat follows them), APFS case variants and hard links. The guard is consulted for the output
folder chain, every delivery folder, the partial folder, every `.tmp` and every final name. Preflight additionally
compares paths case-insensitively against the roots (for roots that are not reachable).

**Staging.** `<delivery>/.holdmybyte-partial/<UUID>.tmp`, `O_CREAT|O_EXCL`, written fully, `fsync`, then
`renamex_np(RENAME_EXCL)`; on `EEXIST` it retries " 2", " 3", …. A cancelled or failed write unlinks its `.tmp`.
Partial folders are emptied at resume start and removed when a job ends (finished, paused or stopped).

**Names.** File stems are fixed up front for all photos of the request in capture order (`{wedding}-{number}`, or the
original base name), de-duplicated case-insensitively with " 2", so names never depend on worker timing. The
extension follows what is written: `.jpg`, `.webp`, `.jxl`, or the source's own extension for an archive copy.

**Folders.** A fresh run creates the output folder (it must not exist or must be empty) and each delivery folder
(" 2" if it exists). The resolved names are stored in `layout.json`. Resume, Create More
(`appendToExistingFolder`) and retries (`onlyPhotos`) first use the folder names an earlier run of the wedding
recorded there ("Couple 2"); otherwise resume and retries reuse an existing delivery folder of the preset's name,
while Create More never writes into an existing folder it has no record of (" 2", §2.0 principle 5). The new
`layout.json` keeps the earlier entries, so a later retry still finds every delivery's folder.

**Journal.** `<support>/Jobs/<weddingID>/request.json` (the `JobRequest`), `layout.json`, `journal.jsonl` (one
`PhotoResult` per line after the rename; `fsync` every 10 lines, at pause/stop and at the end) and the empty
`finished` marker written last. A torn last line is skipped when reading and cut off before the next append.

**Resume.** A pair is skipped when its latest journal entry is done/kept and the file exists with `outBytes`.
Everything else is redone. If a crash happened between a rename and its journal line, the redo finds a file at the
planned name; resume adopts it when its bytes are identical (determinism makes this exact) instead of writing
"… 2". Previously journaled results are re-emitted in the first `.results` event.

**Error mapping.** `ENOSPC`/`EDQUOT` → `.paused(.diskFull(volume, needed))` (needed = average output per finished
pair × open pairs, rough estimate before the first result); `EACCES`/`EROFS`/`EPERM` →
`.paused(.outputNotWritable(path))`; a read failure with the source root missing →
`.paused(.sourceUnavailable(volume))` ("Wedding SSD" from `/Volumes/Wedding SSD/…`, else the volume's name).
Nothing delivered at all (every pair failed) → `.failed(reason)`.

**Pause/stop.** Cooperative: `CancelToken` is checked before every probe, every encode, every score, every write and
before every rename; slot waits poll it. Workers stop taking photos. `pause()`/`stop()` return after the terminal
phase has been emitted.

**Events.** `.phase(.running)`, then `.results` at most every 100 ms (the final flush waits out the interval),
`.progress` with every results event and at least every 0.5 s, then exactly one terminal phase. ETA: EMA (α = 0.1)
over completion intervals, seeded with the first interval / worker count; nil until 10 photos finished in this run.

## 5. Metadata (§3.7)

- `keepAll`: EXIF, XMP (+ extended XMP), IPTC verbatim; ICC verbatim or sRGB when converted.
- `removeLocation`: the EXIF is rebuilt by `TIFFDocument` (IFD0 → Exif → Interop → GPS → IFD1 + thumbnail, values
  copied raw, pointers relocated) without the GPS IFD, BodySerialNumber, LensSerialNumber, MakerNote, SubIFDs
  (SubIFDs carry offsets that cannot be relocated) and, since D-ENG-8, without IFD1 and its thumbnail. APP13 keeps
  every Photoshop image resource byte for byte except the preview images 0x0409/0x040C (IPTC 0x0404 verbatim). On
  the wedding the two previews were 16.6 KB per file each (Website 8.9 MB, Social 17.7 MB of the G5 totals). XMP via `CGImageMetadata`: removes `exif:GPS*`,
  `aux:SerialNumber`, `aux:LensSerialNumber`, `exifEX:BodySerialNumber` (matched by namespace URI). Since D-ENG-11
  the packet is then written without layout whitespace (`XMPMinify`, kept only when CGImageMetadata reads the same
  tags back); under `keepAll` XMP stays byte-identical.
- `removeAll`: new EXIF with Orientation, Artist, Copyright; XMP with only `dc:rights`, `dc:creator`; no IPTC.
- Orientation is preserved under every policy; a source without EXIF but with an orientation gets a minimal EXIF.
- JPEG order: APP1 Exif, APP1 XMP, APP2 ICC chain, APP13, `COM "holdmybyte 2.0"`. WebP: icc/exif/xmp to the encoder.
- Keep-original: `keepAll` → the source bytes verbatim; other policies → `JPEGContainer.rewrite` (SOI, APP0, new
  segments, every non-metadata segment in order, then SOS…EOI byte for byte). Data after EOI (MPF/CIPA preview
  images, which carry their own unfiltered EXIF and GPS) and the APP2 MPF index are dropped under these policies.
  Tests prove identical decoded pixels.
- EXIF larger than one APP1 segment (a huge MakerNote) loses the MakerNote, then the thumbnail, then everything but
  Orientation/Artist/Copyright, so the orientation always survives in JPEG outputs.

## 6. Archive (§3.6)

Huffman JPEG sources: `transcodeLossless(effort: 7)`, `reconstructJPEG`, SHA-256 compare → `.jxl`, `.done`,
`byteExact = true`. libjxl holds ~1.4 GB for a 45 MP JPEG whatever the effort (cjxl 0.12 e3/e5/e7: 1.39 GB max
RSS, identical output), 2.4–2.7 CPU-s per transcode + verification at load 6–9. Since D-ENG-11 the transcode and the verification run
on up to 4 threads per call (`hmb_jxl_*_threads`, a `JxlParallelRunner` whose helper threads adopt the caller's arena;
`HMB_JXL_THREADS`); libjxl's output does not depend on the thread count (all 535 wedding archives identical). Since D-ENG-10 all of libjxl's
working memory comes from a per-call arena that is returned when the call ends (peak 1.32 GB, nothing retained),
and archives are their own work items, at most `MemoryPlan.archiveLanes` at once (§8). With an optional `MemoryBudget`
(D-ENG-7) the transcode and its verification reserve 33 B/px. Anything else, or any transcode/verification failure (logged): the original bytes copied,
`.keptOriginal`, encoder `copy`, `byteExact = true`, source extension.

## 7. Estimates (§3.10)

Sample S = min(12, n) at ⌊(i + 0.5)·n/S⌋, processed on up to `estimateConcurrency` threads; within a sample the
variants are made first (one sRGB conversion, one resize per size) and the deliveries are then estimated in parallel.

| Kind | Estimate |
|---|---|
| Full-size JPEG | mosaic proxy curve (3 encodes + scores, `JPEGTuning.fullSize`, proxy scan script), mosaic encoded at d* = exp(inv(G)) with the tuning at level 2, × pixel ratio × κ + marker bytes; G = T + exactMargin − exactBiasPrior (= T + 1.13) for `.mosaicExact`, T + M0 − BIAS for `.proxyCurve`; capped at the source size when keep-original would apply. Fixed floors in the high mode (D-ENG-13): the same with `highTarget` at 4:2:0 (and 4:4:4 from `high444From`, the smaller), its prior and bias prior −0.3 (holdout actual / estimate: Highest 1.030, High 1.044) |
| Full-size WebP | mosaic encoded at qPrior × pixel ratio × κ |
| Resized (and small full-size) | **the delivery's real DirectSearch on the sample's variant** (WebP with its JPEG fallback and `WebPTuning.default`; JPEG with `JPEGTuning.resized` and the 4:4:4-first rule), best passing bytes × κ (D-ENG-4). The post-pass (scan rewrite, zeroing) is not modelled; live test after D-ENG-11 (holdout, all four, actual / estimate): couple 0.998, website 1.010, social 1.000, archive 1.000 |
| Archive | 0.78 × JPEG bytes + 1.0 × other bytes, over all photos |

Totals × n/S. **κ defaults stay 1.0** — fitted on the holdout (all 19 photos, 12 sampled), actual / estimate:

| Delivery | Before (one probe at the prior; G = T + 2.1) | After | |
|---|---|---|---|
| Couple's Package (full JPEG) | 0.947 | **0.996** | per-photo sd of the full-size ratio 3 % (dense curves) |
| Website (WebP 2560) | 1.315 | **1.024** | prior q 75 vs ~80 needed; search overshoot (directStop 1.0) |
| Social (JPEG 1440, 85) | 1.434 | **1.038** | 3/19 photos reach 85 only with 4:4:4 |
| Archive | 1.000 | 1.000 | |

Time (`hmb estimate`, release, wall incl. process start, Metal set-up and scan of 19 files): all four deliveries
4.15–4.53 s at load 5.7–5.8 (19.4 CPU-s), Couple + Website 3.98–4.63 s, Couple alone 0.98 s, Website alone 3.61 s
(14.6 CPU-s: ~2.7 WebP encodes of 0.27 s per sample). Before the change all four took about 2.5 s; the WebP search is
the price of the accuracy. The test gate (≤ 5 s) only applies on a quiet machine (load < 3), which this session never
had; `LiveEngineTests` measured 5.28 s in a debug build at load 6.2 and 11.9 s at load 69.

Seconds per photo default to the §3.11 budgets (full 1.12 s, resized 0.28 s, archive 0.67 s). Learning (UserDefaults,
keys `holdmybyte.estimate.kappa.<kind>` / `.seconds.<kind>`, EMA α = 0.3) happens after a fresh, complete, finished
job whose photo set was estimated in this session; time is attributed to deliveries by their share of worker seconds
(jobs with ≥ 12 photos). `LearnedEstimates.reset()` clears the keys.

## 8. Concurrency (§3.9)

- Workers: `Thread`s with 8 MB stacks pulling photo indices from a locked FIFO; `.automatic` = clamp(cores − 2,
  2…8) at `.userInitiated`, `.gentle` = 2 at `.utility`. A coordinator thread runs the event loop; the cooperative
  pool only sees `AsyncStream` and continuations.
- `MetricLane`: one per `LiveEngine`, shared by the running job and by estimates; one lock around every metric
  call (prepare, score, release). Waiting for the lock polls the cancel token every 20 ms, and the token is checked
  again once the lock is held, so queued workers do not each spend a GPU score after a pause. Full-size searches
  (references above 8 MP) take one of 3 slots and full-size decodes one of 2 (counting semaphores, cancellable
  waits; since D-ENG-11 the number of full-size slots comes from the memory plan, below). Since D-ENG-10 references above 3 MP are **deferred**: the handle keeps only the caller's pixels and every
  score rebuilds the GPU pyramid under the lane, into pooled storage, right before scoring (bit-identical scores;
  ~35 ms GPU per full-size score). The 2048×1024 mosaic keeps a live reference.
- Memory plan and work items (D-ENG-10, `Jobs/MemoryPlan.swift`, `Jobs/Concurrency.swift`): a job's work is split
  into two kinds, a photo's **archive** (file bytes only) and its **lossy deliveries** (one decode shared by all),
  pulled by the same worker threads. `MemoryPlan` models the peak per pixel of the largest photo — base 0.3 GB,
  metric pools 32 B/px, archive transcode 30 B/px, lossy worker 6 B/px, + 6 B/px for each of ≤ 3 full-size searches —
  against a budget of 8 GB but at most half the Mac's memory, gives archives ~3/8 of the workers (all of them in an
  archive-only job) and drops workers until the model fits. At 45 MP with 8 processor workers: **7 workers, 3 archive
  lanes**, model 7.75 GB. While lossy work is queued an archive starts only in a free lane and the worker takes lossy
  work instead (no idling); when the last lossy item ends the metric pools are drained and archives may take what
  lossy work and the pools gave back (tail). `EngineOptions.archiveConcurrency` / `HMB_ARCHIVE_LANES` override the
  lanes for tuning runs (and keep the worker count as given).
- Allocation (D-ENG-10). macOS malloc keeps freed blocks resident: large blocks dirty in its large-block cache (a
  200 MB block freed stays in the footprint; tested up to 8 GB on this 64 GB Mac, `malloc_zone_pressure_relief`,
  memory-pressure events and a destroyed `malloc_create_zone` zone release nothing), small regions as "reusable"
  pages that still count as resident. Only `MallocLargeCache=0` at process start returns them, which an engine
  library cannot set. So the large buffers no longer come from malloc:
  - `PixelImage` ≥ 1 MB: its own anonymous mapping, unmapped in deinit (also skips the 180 MB memset; the kernel
    zero-fills).
  - libjxl: `JxlMemoryManager` (image planes) and libjxl's C++ containers (global `operator new`, replaced in
    `CHMBCodecs/arena.cc`) are served from a per-call **arena** while a transcode or reconstruction runs on that
    thread: one slot of a reserved address range, size classes and coalesced page runs, all pages dropped when the
    call ends. Outside a scope the replacement is exactly malloc/free; `operator delete` recognises arena blocks by
    address. A 45 MP transcode now peaks at 1.32 GB and leaves 0 bytes behind (was 1.56 GB peak, 0.9 GB left in
    malloc per concurrent transcode).
  - jpegli: `cinfo->mem` allocations (coefficient planes, ~140 MB at 45 MP 4:2:0) come from the same arena.
  - vImage's Lanczos scratch (56 MB at 45 MP → 2560 px) is a mapping passed as `tempBuffer`.
  - Metal pools are keyed orientation-free (landscape and portrait share one working set and one reference) with a
    2 GB LRU byte limit instead of 3 geometries, which the 7 geometries of a four-delivery job kept evicting.
- Remaining footprint at 45 MP (vmmap/footprint mid-run, 7 workers): metric pools ~1.65 GB (GPU), archive arenas
  up to 3 × 1.3 GB, decoded sources and candidates ~1 GB, ImageIO/CMPhoto decode buffers and surfaces ~0.3–0.5 GB.
- `HMB_MEMTRACE=<file>` (diagnostics, `Jobs/MemoryTrace.swift`): samples footprint, resident size and the number of
  workers per phase every 0.25 s, plus marks around decodes, deliveries and archives.
- `MemoryBudget` (D-ENG-7, `EngineOptions.memoryBudget`, `HMB_MEMORY_BUDGET`; off by default) is kept for tuning;
  with deferred references only archive transcodes reserve from it.

  **Measured** (wedding, 535 × 45 MP, all four deliveries, release `hmb compress`, `/usr/bin/time -l`, outputs
  SHA-256-identical to the baseline in every row; GB = 10⁹ bytes; machine never quiet, Lightroom running):

  | Build (cumulative) | Workers / archive lanes | Wall | CPU user + sys | Peak RSS | Peak footprint | 1-min load |
  |---|---|---|---|---|---|---|
  | baseline (f8c2e1f) | 8 / – | 501 s | 3118 + 237 s | 19.39 GB | 21.30 GB | 7.2 → 15.5 |
  | baseline, `MallocLargeCache=0` only | 8 / – | 551 s | 3155 + 447 s | 13.03 GB | 10.61 GB | 6.1 → 21.2 |
  | + deferred references, orientation-free pools, mapped `PixelImage`, mapped JXL manager | 8 / – | 513 s | 3135 + 266 s | 14.70 GB | 9.38 GB | 11.7 → 17.6 |
  | + archive items, 3 lanes, `MallocLargeCache=0` | 8 / 3 | 564 s | 3181 + 439 s | 10.62 GB | 6.42 GB | 9.3 → 10.9 |
  | + codec arenas (libjxl, jpegli), no env | 8 / 3 | 518 s | 3104 + 364 s | 7.87 GB | 8.56 GB | 8.4 → 10.3 |
  | + memory plan, pool drain | 7 / 3 | 522 s | 3041 + 332 s | 7.31 GB | 8.04 GB | 7.9 → 8.1 |
  | + 2 decode slots, vImage scratch | 7 / 3 | (slept) 645 s awake | 3173 + 356 s | 7.34 GB | 8.22 GB | 30 → 19, swapping |
  | **+ `hmb` re-exec with `MallocLargeCache=0` (shipped)** | **7 / 3** | (slept) 573 s awake | 3278 + 396 s | **6.87 GB** | **7.24 GB** | 11 → 20, swapping |
  | A/B 11:00, baseline | 8 / – | 513.6 s | 3148 + 255 s | 18.82 GB | 19.55 GB | 14.4 → 10.2 |
  | A/B 11:06, shipped | 7 / 3 | **564.4 s (+9.9 %)** | 3123 + 410 s | **7.18 GB** | **7.42 GB** | 6.1 → 13.2 |

  "Slept": from 01:00 the Mac went into maintenance sleep repeatedly and swapped (16.4 of 17.4 GB swap used by other
  processes), so wall clock includes sleep; "awake" is `mach_absolute_time` across the run. Timing comparisons use
  the A/B pair in Docs/BENCHMARKS.md. 60-photo screens (same outputs) gave the same ordering: 8 / 3 lanes without the
  plan 8.26–8.63 GB footprint, 7 / 3 7.52–7.74 GB, + `MallocLargeCache=0` 7.15 GB; 2 lanes 7.21 GB at +15 % wall.
- **Speed (D-ENG-11, `eng-speed`; outputs byte-identical):** `MemoryPlan` gives every lossy worker a full-size search
  slot while the model fits (otherwise slots drop to the old 3 before a worker is dropped; `EngineOptions.maxLiveReferences`
  nil = from the plan, `HMB_FULL_SLOTS`, `HMB_DECODE_SLOTS`): a Couple's Package job ran 3 searches on 8 workers before.
  Candidates of exactly 8-bit RGBX layout are wrapped zero-copy (`ImageIODecoder.wrapDecoded`). Mosaic and ≤ 3 MP
  scores no longer take the lane lock (each caller has its own pooled working set); a deferred 45 MP score builds the
  pyramid and scores in one command buffer. The jpegli progressive tokenisers skip zero coefficients through two
  64-bit masks per block (`Vendor/patches/libjxl/0001-jpegli-tokenize-masks.patch`, applied by
  `Scripts/build-codecs.sh`; `Vendor/codecs.lock` pins the patched archive, since D-ENG-12 with normalised ar headers
  (`6e8cf4a9…`, same members as `3e81407d…`); `EncoderGoldenTests` compares 784 outputs
  with the unpatched build). Couple-only jobs now peak at 5.2–6.0 GB footprint (was 3.8–4.2 GB); four-delivery jobs are
  unchanged.
- Variants no later delivery needs are dropped before each delivery: the full-resolution sRGB copy made for Website
  and Social no longer lives through the Couple's Package search (180 MB per worker at 45 MP).
- Determinism: names fixed up front, encoders single-threaded per image (WP1), no randomness or time in outputs;
  1 vs 3 workers produce byte-identical folders (`determinismTwoRunsAreByteIdentical`).

## 9. Live status (2026-10-15, integration pass)

All three `LiveEngineTests` pass with `HMB_HOLDOUT` and `HMB_TEST_PHOTOS` set: holdout Balanced (50.24 MB, 1.95 / 3
probes, 19/19 ≥ 74), live determinism 6 × 4 (byte-identical), estimator (±4 %). Fits recorded in §3.1 and §7; the
full-wedding runs are in `Docs/BENCHMARKS.md`. Opt-in measurement tools: `HoldoutMeasureTests` (`HMB_CURVES_OUT`,
`HMB_RESIZED_OUT`: dense live curves as JSON) and `SearchABTests` (`HMB_SEARCH_AB`, optional `HMB_SEARCH_AB_TRACE`);
run them in release (`swift test -c release -Xswiftc -enable-testing --filter …`).

## 10. Engine integration `eng-v3` (2026-10-16, D-ENG-11)

Adopted: all of `eng-speed`, all of `eng-search`, all of `eng-postpass` (lab tests included, opt-in). Rejected:
`eng-dct` (DCT-domain recompression: +2.8 % / +4.5 % bytes at the same floor, not faster; its one gain, chroma × 0.75,
is contained in `JPEGTuning.fullSize`'s chroma 0.65). `eng-research` changed no code; its recommendation 1 (Highest:
4:4:4 with standard tables, AQ off) is an open item (D-ENG-11). Interactions resolved in code: one C entry
(`hmb_jpegli_encode_opts`) carries the tuned tables, the proxy scan script and the post-pass scan choice; the mosaic is
tuned and in the proxy script; the scan choice is read from the tuned proxy mosaic's coefficients.
`ScanScriptEquivalenceTests.tunedTablesDecodeToTheSamePixelsInEveryScript` checks that all three scripts decode to the
same pixels with both tunings. Measurements: `Docs/variants/eng-v3.md`, `Docs/BENCHMARKS.md`.

## 11. Engine integration `eng-r2` (2026-10-16, D-ENG-14)

`eng-safety` (decoder guard, `IslowDecoder`, reproducible codec lock 6e8cf4a9) and `eng-highest` (high-target mode)
merged in that order. The high mode's oracle runs inside the full-size search that the guard wraps, so the guard covers
high-mode results at 4:2:0 and 4:4:4. Holdout, release, all six deliveries in one job, back to back with main
(`Docs/BENCHMARKS.md`): Couple, Website, Archive byte-identical; Social −315 B (7 files moved by the guard); High
−3.39 %; Highest −4.72 % (182,463,652 B: the guard moved one high-mode 4:2:0 file that libjpeg-turbo read at 89.998 to
4:4:4, +125,711 B against `.chroma444`). Every delivered JPEG ≥ target under ImageIO and libjpeg-turbo. CPU +13 %,
wall +22 % on the six-delivery job (load 5–8); about 28 s CPU of the +34 s are the 57 full-size guard decodes
(`.chroma444` run: 259.7 s).
