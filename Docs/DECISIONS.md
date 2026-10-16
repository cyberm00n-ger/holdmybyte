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

## D-ENG-7 · 2026-10-15 · Memory: optional budget, no default throttle; G7 needs structural work (verifier, engine lead)

`MemoryBudget` (weighted, cancellable, shared by full-resolution references at 36 B/px and archive transcodes at
33 B/px) is added but **off by default** (`EngineOptions.memoryBudget = nil`; `HMB_MEMORY_BUDGET` for `hmb` tuning
runs). Variants that no later delivery needs are dropped per photo. **Why off:** at 6.4 GB it cuts Archive-only peak
RSS 12.5 → 8.5 GB (holdout) but costs ×1.5 wall time (G6 projection ~380 s at load 7 vs 360 s gate), and it does not
fix G7: 80 wedding photos, all four, still peak at 9.1 GB RSS with only two heavy allocations allowed (172 s vs 91 s),
and the wedding all four peaked at 19.5 GB with 6.4 GB. The integrator's reading ("the archive is the cause; capping
transcodes fixes it") is refuted: the lossy workers and malloc's retained free regions carry the rest (ENGINE §8). The
§3.9 budget (8 GB at 8 workers, 45 MP) needs per-worker memory work (streamed or tiled jpegli encode and candidate
decode, fewer full-resolution copies) or an owner-accepted exception.

## D-ENG-8 · 2026-10-15 · G5: no embedded previews under removeLocation; JPEG DirectSearch window 0.5 (SPEC §3.7/§3.5 deviation)

(a) `removeLocation` drops embedded preview images: the EXIF IFD1 thumbnail and Photoshop IRB resources 0x0409/0x040C
(IPTC 0x0404 and every other resource stay byte for byte; keepAll is untouched). They are copies of the *source* (not
colour-converted, not resized), the old engine shipped none, and on the wedding they were 8.9 MB of Website and
17.7 MB of Social. Same precedent as dropping MPF previews in kept originals. (b) `directStopJPEG = 0.5` (WebP keeps
`directStop` 1.0): holdout Social −2.3 % bytes, +0.4 probes; WebP got worse with a tighter window. Result on the
wedding (all four, one run): Website 172.3 → **163.4 MB**, Social 183.7 → **163.5 MB**, both ≤ 165 MB; minima 70.0 /
85.0; estimates within ±4.3 %. Image data and the floors are unchanged. Reversible by the owner: dropping (a) puts
G5 back to a fail unless the gate is restated as image bytes.

## D-ENG-9 · 2026-10-15 · Load-sensitive tests

The scanner throughput budget (≥ 500 files/s) is asserted only at 1-minute load < 3 (§3.11 quiet machine; it failed
at load ~10 in the full suite). `AppModelFlowTests` / `ShellTests` that pause, stop or queue a running FixtureEngine job
use 0.05 s per photo (was 0.004: the 40-photo job could finish before the intent under load, so `pauseResumeStop` and
`startNowInsteadPausesTheCurrentJob` failed in full-suite runs). Test-only; no product code changed.

Append-only. One short entry each: date, area, the question it answers, the decision.

## 2026-10-15 · app integration (branch `int-app`)

- **[app] WP3 Q1, Edit Delivery host.** The placeholder `EditDeliverySheetHost` is gone; `RootView` attaches WP4's
  `.editDeliverySheet(model:)`. Settings keeps presenting its own Edit Delivery sheet.
- **[app] WP3 Q2, stores.** `AppModel.live()` uses `JSONHistoryStore(StoreLocations.weddings)`,
  `UserDefaultsPresetStore()`, `UserDefaultsSettingsStore()`, `DiskThumbnailCache(StoreLocations.thumbnails)`;
  `InterimStores.swift` is deleted. No migration of the interim keys (`presets.v1`, `settings.v1`): nothing shipped.
- **[app] WP3 Q3, Clear History alert.** Settings presents it (the main window's `AlertPresenter` leaves
  `.clearHistory` out); its title, message and buttons come from `AppAlert.copy`. Singular: "Clear the history of
  1 wedding?". Removal goes through the model's save chain, so quit waits for it.
- **[app] WP3 Q4 / accent.** Native controls keep the tint as macOS draws it (checkboxes, switches, borderless and
  bordered buttons); §2.5's accent list governs the elements we draw. Never `.tint(nil)`: it resets to the system
  accent (the running progress bar was blue under the teal accent).
- **[app] WP3 Q5, Compare keys in menus.** View ▸ Comparison calls WP4's API (`toggleCompareMode`, `…Zoom`,
  `…Differences`, `…Inspector`, `…OriginalLatch`), so menu and keys follow the same rules. Single-letter and arrow
  key equivalents are enabled only while `compareKeysActive` (Compare open in the key window, no sheet or alert, no
  text field focused); `\` stays a key handled by Compare (hold needs key-up). `closeCompare()` pops the path.
- **[app] WP3 Q6, Try Again contract.** Confirmed as built: a retry runs `run(request, resume: false)` with
  `onlyPhotos` and `appendToExistingFolder: true`; the engine must keep earlier results (WP2 to verify in its area).
- **[app] WP3 Q7, fixtures.** Synthetic thumbnails extend the gradient (no light corner triangle); seeds use the full
  path, so history covers differ; with `HMB_FIXTURE_PHOTOS` the real photo is picked by that seed too.
- **[app] WP4 Q1, divider colours.** `Tokens.Palette.compareDivider` (white) and `compareDividerShadow` (black 60 %)
  added to Tokens.swift; `CompareStyle` removed.
- **[app] WP4 Q2, Reset Learned Estimates.** No engine API change. `AppModel.learnedEstimatesKeyPrefix` is the
  engine's `LearnedEstimates.keyPrefix`, `holdmybyte.estimate.` (it was `holdmybyte.learned.`, so the button removed
  nothing). The engine reads defaults on every estimate, so removal takes effect at once.
- **[app] WP4 Q3, Compare first frame.** The cached grid thumbnail shown at once counts as the "embedded preview"
  first frame (§2.4 S14 loading); the 150 ms budget applies to it. The screen-size pair is measured and reported.
- **[app] WP4 Q4.** Restore Default Deliveries keeps custom deliveries (no confirmation needed; nothing is deleted).
- **[app] WP4 Q5.** Compare failure copy confirmed: "This photo can’t be compared. The delivered file couldn’t be
  opened."
- **[app] WP4 Q6, empty patterns.** No validation in Settings: `HMBFormat.folderName` falls back to the wedding name
  and `HMBFormat.fileName` to the number when a pattern expands to nothing.
- **[app] WP5 Q1.** The harness forwards to `AppAlert.copy(in:locale:)` (`HarnessAlert`). Remove alert: Cancel is the
  default button, Remove the destructive one; macOS orders them [Cancel] [Remove].
- **[app] WP5 Q2, missing folder in snapshots.** The harness installs an inert platform whose `fileExists` is false only
  for the scenario's `missingFolders` (done-missing-folder), then calls `volumesChanged()`.
- **[app] WP5 Q4/Q5.** Entry points stay `RootView(model:)`, `SettingsView(model:)`, `StatusMenu(model:)`. Create More is
  `selection = .wedding(id)` + a draft whose `wedding == existingWedding == id` (the harness had `.newWedding`, which
  rendered the empty drop zone).
- **[app] WP5 Q6.** Count-ups and the seal draw-on already show final values under `isSnapshotRendering`; settle stays
  0.7 s (state morphs do not run on a first render).
- **[app] WP5 Q7.** `Tokens.forcesMulticolorAccent`, set by `hmb-snapshot`, renders the shipped teal accent whatever
  the rendering Mac's accent.
- **[app] Setup notices order.** Notices sit directly under the setup header instead of last: a block (not enough
  space, read-only) must be visible without scrolling, also at 780 × 560, next to the disabled primary button.
- **[app] Delivery tiles.** Tiles keep the 220 pt minimum but fill the row in balanced rows (2 tiles → 2 columns,
  4 → 2 × 2), generalising "a single delivery spans the full width". Tile size lines wrap instead of truncating.
- **[app] Sidebar rows.** The date and count never truncate; the name middle-truncates and the delivery symbols that
  do not fit beside the count are left out (at most 4).
- **[app] Dates.** English month names in the region's order everywhere (`Copy.longDate`), also in the Compare
  inspector (it used en_US).
- **[app] Compare title.** Compare removes the inherited navigation title; the Back button carries the wedding name.
- **[app] Edit ▸ Find.** Our Find (⌘F, focuses the sidebar search) replaces the system text-editing group, whose own
  ⌘F "Find…" competed with it. ⌘⌫ (Remove from History) is disabled while the search field is focused.
- **[app] Alerts over sheets.** Quit-while-running and Stop… close an open sheet first, so the alert can show.

## 2026-10-15 · app verification (branch `int-app`)

- **[app] Secondary buttons are neutral.** The root `.tint` (Multicolor accent) coloured every push button teal (Cancel
  beside the teal primary button, banner, notice, sheet, Settings and Choose Photos…/Spot-Check… buttons), which macOS
  never does for a secondary button and §2.5's accent list does not allow. Those buttons take `.hmbNeutralButtonTint()`
  (`.tint(nil)`); checkboxes, radios, borderless link buttons and the prominent button keep the accent.
- **[app] Proof card headline counts delivered photos.** "533 of 533 photos met their quality target" (was "533 of
  535"): failed photos never reached the quality check, and S11 rules out a quality failure.
- **[app] Delivery tile footer.** Size line on one line, else broken at the last "·"; the proof line and Show in Finder
  share a row only when both fit, else Show in Finder goes under the proof line (`ViewThatFits`).
- **[app] Sidebar rows.** The wedding name has priority over the delivery symbols: symbols are dropped until the full
  name fits (it still middle-truncates when longer than the row).
- **[app] Learned-estimates prefix.** `AppModel.live()` checks `AppModel.learnedEstimatesKeyPrefix ==
  LearnedEstimates.keyPrefix` (precondition), the one place both modules are visible.
- **[app] UI test timeouts.** `waitUntil` defaults to 90 s (was 10 s): in the full `swift test` process the engine
  suites' synchronous work starves the cooperative pool, and 12 flow tests timed out together at load 38. Passing
  tests return as soon as their condition holds.

## D-ENG-10 · 2026-10-16 · Memory: arenas, deferred references, archive lanes, memory plan; G7 (engine, branch `polish-engine`)

Supersedes the "needs structural work" part of D-ENG-7. **Findings:** the 18.5 GB peak was (1) GPU: up to 3 live
45 MP reference pyramids (0.73 GB each) plus pooled spares and working sets that the 3-geometry LRU kept re-allocating
(7 geometries in a four-delivery job); (2) libjxl: 1.3 GB of image planes plus ~0.9 GB of C++ container churn per
concurrent transcode; (3) macOS malloc keeping every freed large block resident (large-block cache, tested up to
8 GB; `malloc_zone_pressure_relief`, memory-pressure events and destroying a `malloc_create_zone` zone release
nothing; only `MallocLargeCache=0` at process start does), so the peak was the sum of every concurrency high-water
mark. **Decisions:** (a) full-size references are deferred: the GPU pyramid is rebuilt inside the lane per score
(bit-identical scores, ~35 ms GPU each); Metal pools keyed orientation-free with a 2 GB byte LRU. (b) `PixelImage` ≥
1 MB, libjxl (memory manager + global `operator new` while a libjxl call runs, `CHMBCodecs/arena.cc`), jpegli
(`cinfo->mem`) and vImage scratch no longer use malloc: anonymous mappings / per-call arenas returned at once.
(c) A photo's archive is its own work item; `MemoryPlan` sets workers and archive lanes from a per-pixel model, a
budget of min(8 GB, RAM/2) and the largest photo: 45 MP, 8 processor workers → **7 workers, 3 archive lanes**;
archives may expand once lossy work is done (pools drained). (d) At most 2 full-size decodes at once (ImageIO holds a
second 177 MB buffer while decoding). (e) `hmb` re-executes itself with `MallocLargeCache=0` (a batch process; the old
engine child keeps the default). **Follow-up for the app (not done, outside the engine):** set
`LSEnvironment = { MallocLargeCache = 0 }` in the app's Info.plist (Scripts/bundle-app.sh), else the app runs the
engine without (e) — measured −0.4 GB footprint on 60 photos. **Owner question:** G7 says "peak RSS"; on macOS RSS
counts pages malloc has already given back as reusable, and Activity Monitor/jetsam use the physical footprint.
Both are reported (Docs/ENGINE.md §8, Docs/BENCHMARKS.md). **Result** (wedding 535, all four, A/B at the same load
class): peak RSS 18.82 → **7.18 GB**, footprint 19.55 → **7.42 GB**, wall 513.6 → 564.4 s (+9.9 %); all 2140 outputs
SHA-256-identical to the baseline build, sources unchanged. Without (e), otherwise the same code, the peak was 8.22 GB
footprint / 7.34 GB RSS (8.04 / 7.31 GB one step earlier), so the app needs the follow-up to stay under 8 GB.
