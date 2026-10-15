# WP2 notes: search, pipeline, jobs and the live engine

Branch `wp2-pipeline`. Engine design and constants: `Docs/ENGINE.md`. This file: what was built, the acceptance
status, measurements, deviations and questions for the lead.

## What was built

`LiveEngine: EngineService` with every §5.2 component: `Scanner`, `MosaicSearch`, `DirectSearch`, `JXLArchive`,
`MetadataEditor` (+ `TIFFDocument`, `JPEGContainer`), `PhotoPipeline`, `WorkerPool`, `MetricLane`, `OutputWriter`
(+ `SourceGuard`), `Journal`, `Estimator` (+ `LearnedEstimates`), `ProgressCoalescer`, plus `PreflightCheck` and
`CompareLoader`. Files only under `Sources/HMBEngine/{Search,Pipeline,Jobs,IO,Metadata,Estimate,Service}`,
`Tests/HMBEngineTests/Pipeline`, `Docs/ENGINE.md` and this file. No frozen file was changed.

## Acceptance (§5.2)

| # | Criterion | Status | Test(s) |
|---|---|---|---|
| 1 | OutputWriter refuses source file, below root, symlink, case variant, hard link; never overwrites; no .tmp after success/cancel | **met** | `OutputWriterTests` (9) |
| 2 | Resume after stop at 3 random points = uninterrupted run, no duplicates; torn journal line tolerated | **met** (plus a crash-state test: truncated journal, torn line, stray .tmp, renamed-but-unjournaled file) | `JobTests.resumeAfterStop…`, `…SimulatedCrash…`, `truncatedLastJournalLine…` |
| 3 | Pause/stop < 1.5 s with slow fakes, no partial files | **met** (0.22 s with 0.25 s fake encodes) | `JobTests.pauseLatency…` |
| 4 | ENOSPC → paused(diskFull); unmounted source → paused(sourceUnavailable) | **met** (+ EACCES → outputNotWritable, missing file → sourceMissing) | `JobTests` |
| 5 | Search: never failing; ≤ 3 + 2 + fail-open; keep-original at 0.95; 4:4:4 only when 4:2:0 unreachable | **met** | `SearchTests` (10), `HoldoutReplayTests` |
| 6 | Live holdout: all ≥ target, mean ≤ 2.2 / max ≤ 5 probes, ≤ 50.31 MB; fits recorded | **not verifiable yet** (WP1 `live()` still a stub). Test written and gated. Replay on measured curves: 49.74 MB, 1.95 mean, max 3 | `LiveEngineTests.holdout…`, `HoldoutReplayTests` |
| 7 | Metadata policies exact (ImageIO read-back), orientation, lossless rewrite pixel-identical | **met** | `MetadataTests` (7) |
| 8 | Determinism, 2 live runs 6 × 4 byte-identical | **met with fakes** (1 vs 3 workers identical); live test written and gated | `JobTests.determinism…`, `LiveEngineTests.determinism…` |
| 9 | Scanner rules; ≥ 500 files/s on 2000 tiny JPEGs | **met** (984–1007 files/s, debug build, load 9–15) | `ScannerTests` (5) |
| 10 | Estimator live ±15 %, ≤ 5 s | **not verifiable yet**; test written and gated. Fakes: rules, archive formula, cancellation, κ learning | `EstimatorTests` (4), `LiveEngineTests.estimator…` |
| 11 | Results ≤ 10 Hz, progress ≥ 1 Hz | **met** | `JobTests.eventCadence…`, `progressCoalescerUnit` |

`swift build` and `swift test` are green, zero warnings. 62 WP2 tests (59 run with fakes, 3 live tests skipped
until WP1 lands); whole package 126 tests passing.

## Measurements (debug build, shared machine)

| What | Result | Machine |
|---|---|---|
| Holdout replay of MosaicSearch on measured curves | 49.74 MB vs old 49.81 MB (−0.13 %), probes 1.95 mean / 3 max, overshoot 0.28 mean / 0.47 max | CPU-only, ms |
| Analytic family (200 curves) | 1.70 probes mean, 0 failing | — |
| Scanner, 2000 × 16 px JPEGs in 20 folders | 984 files/s (2.03 s) | load 9.4 (`uptime` 19:34: 9.43 18.96 20.00) |
| Pause latency, 0.25 s per fake encode, 3 workers | 0.218 s | load 10.0 |
| Full `swift test` | 20.7 s | load 9.4 |

No live timings exist yet (no live primitives). Machine load during the session ranged from 9 to 58 (1-minute).

## Deviations and decisions (please confirm)

1. **`LiveEngine.init`**: kept WP0's `init(primitives:supportDirectory:)` (+ `options: EngineOptions = .init()`)
   and `convenience init(supportDirectory:) throws` (uses `.live()`); a default argument cannot `try`.
2. **Journal layout**: besides `request.json` and `journal.jsonl`, a `layout.json` stores the resolved delivery
   folder names (so a resume writes into "Couple 2" if that is what the first run used) and `finished` is an empty
   marker file written last.
3. **Fresh run into an existing non-empty output folder** fails (`.failed(reason:)`). Preflight already resolves
   " 2"; the engine cannot move the job elsewhere because `PhotoResult.outRelativePath` is relative to the
   request's folder. An existing *empty* folder is used.
4. **Appending modes** (resume, `appendToExistingFolder`, `onlyPhotos` retry) reuse existing delivery folders;
   only fresh runs add " 2". Retries therefore land in the original "Couple" folder.
5. **Crash between rename and journal**: on resume a byte-identical file at the planned name is adopted, not
   rewritten as "… 2" (guarantee 6: no duplicates). Never deletes or overwrites anything.
6. **Keep-original**: `keepAll` copies the source bytes verbatim (no COM marker added); other policies rewrite the
   segments losslessly and drop source COM segments. Result: `score = nil`, `target` set, `encoder = "copy"`.
7. **Archive copies** keep the source's extension (`.jpg`, `.png`, …), not `.jxl`.
8. **Capture order** also uses `SubsecTimeOriginal` (bursts within one second), then the relative path.
9. **Scanner**: a dropped " – Deliveries" folder itself is scanned (so §6.4's "holdmybyte output" warning can fire);
   nested ones are skipped. `convertedToJPEG` is emitted whenever non-JPEG sources exist (the scanner does not know
   the deliveries; the UI may hide it when no JPEG delivery is checked).
10. **`comparePair`** applies the EXIF orientation to both images (`ComparePair` has no orientation field) and throws
    for the archive delivery (non-goal).
11. **One job at a time**: a second `run` while one is active ends at once with `.failed("Another job is running…")`.
    `pause`/`stop` return after the job has wound down (journal synced, terminal phase emitted).
12. **Nothing delivered** (every pair failed) ends with `.failed(reason)` (S13) instead of `.finished`.
13. **`removeLocation`** also drops the SubIFDs pointer (0x014A; its offsets cannot be relocated). Pixel dimension
    tags are not rewritten for resized outputs.
14. **Scanner DQT estimate** reuses `JPEGMarkerScan.estimateQuality` from the WP0 fakes file (internal helper).
15. `MetricLane` gates only references above 8 MP with the 3 slots (resized and mosaic references are small).

## Open questions for the lead

1. **Reset Learned Estimates**: κ and timing live in UserDefaults under `holdmybyte.estimate.*`
   (`LearnedEstimates.reset(suite:)` in HMBEngine). `AppModel.resetLearnedEstimates()` (WP4, module HMBUI) cannot
   call HMBEngine (no dependency). Options: WP4 removes keys with that prefix itself, or `AppModel.live()` (WP3)
   injects a closure. Please decide.
2. **κ / qPrior fits** need `EnginePrimitives.live()`. After WP1 merges I can run the gated live tests and record
   the fits in `Docs/ENGINE.md` (§9 there lists the steps).
3. **Marker placement contract with WP1**: the engine passes JPEG markers in final order (APP1 Exif, APP1 XMP, APP2
   ICC chain, APP13, COM) and expects `JPEGEncoding.encode` to write them right after SOI/APP0 in that order.
   `SourceInfo.markers` must include APP13 and extended-XMP segments for the policies; HEIC/PNG sources may have
   `exif == nil` (orientation is then synthesised from `SourceInfo.orientation`).
4. **Fresh run into an existing non-empty folder** (decision 3): OK to fail, or should the engine pick " 2" and
   report it somehow?
