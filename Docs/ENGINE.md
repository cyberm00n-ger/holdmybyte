# holdmybyte engine (WP2)

How the live engine turns a scanned wedding into verified deliveries. `Docs/SPEC.md` §3 is binding; this file
documents how WP2 implemented it, the constants in use and what was validated. Since the integration pass
(2026-10-15, branch `int-engine`) it also records the live fits and the search change of Docs/DECISIONS.md D-ENG-3…5.

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
| `WorkerPool`, `CancelToken`, `Locked` | `Jobs/Concurrency.swift` | §3.9 |
| `Estimator`, `LearnedEstimates`, `DeliveryKind` | `Estimate/Estimator.swift` | §3.10 |

## 2. Per-photo pipeline (§3.3)

One worker thread takes one photo end to end:

1. `inspect(url)`. A failure is classified: source root gone → the job pauses with `.sourceUnavailable(volume)`;
   file gone but root present → `.failed(.sourceMissing)`; otherwise `.failed(.unreadable)` for every delivery.
2. CMYK → every lossy delivery `.failed(.cmykUnsupported)`; the archive is still attempted.
3. The source is decoded at most once, lazily (an archive-only job never decodes). Features are computed only
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
  keep-original rule.
- **WebP:** if nothing passes, q = 100 is probed explicitly; if that fails too, the delivery falls back to the JPEG
  search on the same variant (`encoder = "jpegli (fallback)"`, extension `.jpg`). The sharp-YUV preparation is done
  once per (photo, delivery).
- **Stop window (D-ENG-8, `DirectSearchABTests`, holdout, release-equivalent live primitives, load 10–24):** Social
  (JPEG 1440 ≥ 85) 1.0 → 0.5: 6.158 → 6.016 MB (−2.3 %), overshoot 0.44 → 0.24, probes 3.58 → 3.95 (0.6, 0.4: 6.039 /
  6.005 MB). Website (WebP) gains nothing from a tighter window (0.4–0.6: +0.7–1.0 %, more probes): integer q steps.

### 3.4 Validation (fakes, measured curves and live A/B)

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
  `aux:SerialNumber`, `aux:LensSerialNumber`, `exifEX:BodySerialNumber` (matched by namespace URI); untouched XMP
  stays byte-identical.
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
RSS, identical output), 2.4–2.7 CPU-s per transcode + verification at load 6–9. With an optional `MemoryBudget`
(D-ENG-7) the transcode and its verification reserve 33 B/px. Anything else, or any transcode/verification failure (logged): the original bytes copied,
`.keptOriginal`, encoder `copy`, `byteExact = true`, source extension.

## 7. Estimates (§3.10)

Sample S = min(12, n) at ⌊(i + 0.5)·n/S⌋, processed on up to `estimateConcurrency` threads; within a sample the
variants are made first (one sRGB conversion, one resize per size) and the deliveries are then estimated in parallel.

| Kind | Estimate |
|---|---|
| Full-size JPEG | mosaic proxy curve (3 encodes + scores), mosaic encoded at d* = exp(inv(G)), × pixel ratio × κ + marker bytes; G = T + exactMargin − exactBiasPrior (= T + 1.13) for `.mosaicExact`, T + M0 − BIAS for `.proxyCurve`; capped at the source size when keep-original would apply |
| Full-size WebP | mosaic encoded at qPrior × pixel ratio × κ |
| Resized (and small full-size) | **the delivery's real DirectSearch on the sample's variant** (WebP with its JPEG fallback; JPEG 4:2:0 → d 0.5 → 4:4:4), best passing bytes × κ (D-ENG-4) |
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
  again once the lock is held, so queued workers do not each spend a GPU score after a pause. References above
  8 MP take one of 3 slots (counting semaphore, cancellable wait). A worker holds at most one full-resolution
  reference, and releases its pixels before the archive transcode.
- `MemoryBudget` (D-ENG-7, `EngineOptions.memoryBudget`, `HMB_MEMORY_BUDGET` for `hmb`; **off by default**): one
  weighted, cancellable budget shared by full-resolution references (36 B/px, 1.6 GB at 45 MP) and archive
  transcodes (33 B/px, 1.5 GB). A worker holds at most one reservation, so it cannot deadlock; a reservation larger
  than the budget runs alone. Measured (release, 8 workers, `/usr/bin/time -l`):

  | Job | Budget | Wall | Peak RSS | Peak footprint | Load |
  |---|---|---|---|---|---|
  | Holdout, Archive only | none | 8.8–8.9 s | 12.29–12.54 GB | 11.38–11.83 GB | 5.0–7.9 |
  | Holdout, Archive only | 9.6 GB | 10.6 s | 11.38 GB | 10.80 GB | 6.8–7.7 |
  | Holdout, Archive only | 6.4 GB | 13.6 s | 8.39–8.70 GB | 6.81–7.83 GB | 6.8–7.9 |
  | 80 wedding photos, all four | none | 91 s | 12.14 GB | 11.86 GB | 4.9–6.9 |
  | 80 wedding photos, all four | 3.2 GB | 172 s | 9.09 GB | 9.21 GB | 6.4–7.6 |
  | Wedding 535, all four | none | 475 s | 18.54 GB | 18.01 GB | 7.1–10.7 |
  | Wedding 535, all four | 6.4 GB | 625 s | 19.49 GB | 13.63 GB | 6.2–8.3 |

  So the budget fixes the Archive-only peak at ×1.5 wall time (a G6 risk), but **does not bring the all-four job
  under 8 GB** even at two heavy allocations: the lossy workers themselves (45 MP source 180 MB, sRGB copy, candidate
  decodes, jpegli's float planes; Couple only on the holdout: 5.2 GB RSS, 7.8 GB footprint) and macOS malloc's
  retained free regions (vmmap mid-run: 1.5 GB "MALLOC_LARGE (empty)" + 2.4 GB "MALLOC_SMALL (empty)" resident,
  not released by `malloc_zone_pressure_relief`; a per-item autorelease pool changed nothing) account for the rest.
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
