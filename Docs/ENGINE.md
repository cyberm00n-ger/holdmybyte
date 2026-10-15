# holdmybyte engine (WP2)

How the live engine turns a scanned wedding into verified deliveries. `Docs/SPEC.md` §3 is binding; this file
documents how WP2 implemented it, the constants in use, what was validated and what still has to be fitted
with the live primitives (WP1).

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
- `qPrior(T) = clamp(75 + 1.5·(T − 70), 5…100)` — 75 at T = 70 as specified; the **slope 1.5 is a placeholder**
  until it is fitted on the holdout with live WebP (§7).

### 3.2 `MosaicSearch` (full-size JPEG, image ≥ 2048×1024)

Constants (binding, unchanged): M0 = 0.6, M1 = 0.15, BIAS = −1.5, STOP = 0.5, MAX_FULL = 3, RESCUE = 2,
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

Loop: probe; stop at the first passing probe with s − T < 1.0 or after 5 probes; otherwise a secant step on the
two latest probes (default slope if the secant is not decreasing) aimed at T + 0.5, clamped into the
passing/failing bracket (midpoint when outside; stop when the bracket is one quantum wide). Values within one
quantum of a range bound snap to that exact bound.

- **JPEG:** 4:2:0 search → if nothing passes, an explicit 4:2:0 probe at d = 0.5 → if still nothing, a 4:4:4 search
  from d = 0.5. Nothing at 4:4:4 → `.failed(.qualityUnreachable)` (logged). Full-size small images also apply the
  keep-original rule.
- **WebP:** if nothing passes, q = 100 is probed explicitly; if that fails too, the delivery falls back to the JPEG
  search on the same variant (`encoder = "jpegli (fallback)"`, extension `.jpg`). The sharp-YUV preparation is done
  once per (photo, delivery).

### 3.4 Validation (fakes and measured curves)

| Check | Result |
|---|---|
| **Holdout replay** — `MosaicSearch` on the 19 holdout photos, full-resolution scores/bytes interpolated in ln d between the measured jpegli 4:2:0 points of the v2 experiments, proxy from the measured grid mosaic (`HoldoutReplayTests`, numbers in `HoldoutCurves.swift`, anonymised h01…h19) | **49.74 MB** vs old engine 49.81 MB (−0.13 %), **1.95 full probes mean, max 3**, 19/19 ≥ target, overshoot mean 0.28 / max 0.47 — consistent with sim-B (2.0 mean, max 3) |
| Analytic family, 200 synthetic curves (targets 74…87, slopes 6…14 /ln d, proxy bias −1.5 ± 0.6, noise) | 0 failing results, mean 1.70 probes, ≤ 5 4:2:0 probes, no 4:4:4 when 4:2:0 reaches T |
| Keep-original threshold | triggers at best ≥ 0.95 × source, not 200 bytes below it |
| Fail-open | 4:4:4 only after 4:2:0 + rescue fail; ≤ 10 probes |

The replay's absolute bytes are only as good as the interpolation (the measured points mix two experiment runs), so
the **live** gates remain authoritative: `LiveEngineTests.holdoutBalancedMeetsTargetsProbesAndBytes` (every photo ≥
target, mean ≤ 2.2, max ≤ 5, total ≤ 50.31 MB) runs as soon as WP1's `live()` works.

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
  copied raw, pointers relocated) without the GPS IFD, BodySerialNumber, LensSerialNumber, MakerNote and SubIFDs
  (SubIFDs carry offsets that cannot be relocated). XMP via `CGImageMetadata`: removes `exif:GPS*`,
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
`byteExact = true`. Anything else, or any transcode/verification failure (logged): the original bytes copied,
`.keptOriginal`, encoder `copy`, `byteExact = true`, source extension.

## 7. Estimates (§3.10)

Sample S = min(12, n) at ⌊(i + 0.5)·n/S⌋, processed on up to `estimateConcurrency` threads.

| Kind | Estimate |
|---|---|
| Full-size JPEG | mosaic proxy curve (3 encodes + scores), mosaic encoded at d* = exp(inv(T + M0 − BIAS)), × pixel ratio × κ + marker bytes; capped at the source size when keep-original would apply |
| Full-size WebP | mosaic encoded at qPrior × pixel ratio × κ |
| Resized | real resize + one encode at prior / qPrior × κ |
| Archive | 0.78 × JPEG bytes + 1.0 × other bytes, over all photos |

Totals × n/S. **κ defaults are 1.0 for every kind — not yet fitted** (needs live primitives on the holdout:
median actual/estimate per kind). Seconds per photo default to the §3.11 budgets (full 1.12 s, resized 0.28 s,
archive 0.67 s). Learning (UserDefaults, keys `holdmybyte.estimate.kappa.<kind>` / `.seconds.<kind>`, EMA α = 0.3)
happens after a fresh, complete, finished job whose photo set was estimated in this session; time is attributed to
deliveries by their share of worker seconds (jobs with ≥ 12 photos). `LearnedEstimates.reset()` clears the keys.

## 8. Concurrency (§3.9)

- Workers: `Thread`s with 8 MB stacks pulling photo indices from a locked FIFO; `.automatic` = clamp(cores − 2,
  2…8) at `.userInitiated`, `.gentle` = 2 at `.utility`. A coordinator thread runs the event loop; the cooperative
  pool only sees `AsyncStream` and continuations.
- `MetricLane`: one per `LiveEngine`, shared by the running job and by estimates; one lock around every metric
  call (prepare, score, release). Waiting for the lock polls the cancel token every 20 ms, and the token is checked
  again once the lock is held, so queued workers do not each spend a GPU score after a pause. References above
  8 MP take one of 3 slots (counting semaphore, cancellable wait). A worker holds at most one full-resolution
  reference, and releases its pixels before the archive transcode.
- Determinism: names fixed up front, encoders single-threaded per image (WP1), no randomness or time in outputs;
  1 vs 3 workers produce byte-identical folders (`determinismTwoRunsAreByteIdentical`).

## 9. To do once WP1 lands

1. Run `swift test` with `HMB_HOLDOUT` and `HMB_TEST_PHOTOS` set: the three `LiveEngineTests` (holdout Balanced
   gate, live determinism 6 × 4, estimator ±15 % / ≤ 5 s).
2. Fit and record here: `qPrior(T)` slope (WebP q at which each holdout photo reaches 70 / 85 at 2560 px), κ per kind
   (median actual/estimate on the holdout), and check `prior(T)` against the full-wedding Balanced run.
3. Record live timings with `uptime` load.
