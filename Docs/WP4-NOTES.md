# WP4 notes: Compare, Settings, Edit Delivery and the stores

WP4 as specified in `Docs/SPEC.md` §5.4 (S6, S14, S16 and `HMBStore`). This file records what was built, the
measurements (with machine load), every deviation, and the questions for the lead.

## What was built

### HMBStore (`Sources/HMBStore/`)
| Type | Behaviour |
|---|---|
| `JSONHistoryStore` (actor) | `<dir>/<uuid>/record.json`, atomic writes (`Data.write(.atomic)`). `loadAll` decodes all records in parallel (`concurrentPerform`) and sorts newest wedding first (wedding date, then creation date). An undecodable file is renamed `record.json.corrupt` (` 2`, ` 3`… if taken), logged, skipped; `lastQuarantined` lists them. `remove`/`removeAll` only delete folders named like a wedding UUID inside the store directory. Default dir `~/Library/Application Support/holdmybyte/Weddings`. |
| `UserDefaultsPresetStore` | JSON under `holdmybyte.presets.v1` / `holdmybyte.defaultOn.v1`. Order kept exactly; duplicate ids dropped; a missing built-in is appended (built-ins cannot be deleted); `defaultOn` filtered to existing ids, no duplicates. Unreadable data → shipped defaults, bytes kept under `<key>.corrupt`. |
| `UserDefaultsSettingsStore` | JSON under `holdmybyte.settings.v1`; unreadable → `AppSettings()`, bytes kept under `<key>.corrupt`. |
| `DiskThumbnailCache` | `CGImageSourceCreateThumbnailAtIndex` (embedded thumbnail first, transform applied), clamped to ≤ 320 px. Cache file `~/Library/Caches/eu.sebastianhaas.holdmybyte/Thumbnails/<sha256(path|size|mtime)>.jpg`, written atomically (temp + rename). `size` = clamped requested pixel size, `mtime` = `stat(2)` mtime with ns (URL resource values are cached per URL instance and would miss a re-export); if the source is unreachable, `SourcePhoto.modified` stands in so ejected-drive history keeps its thumbnails. NSCache in front, concurrent requests for one key share a single generation, at most 4 generations at once on a utility `OperationQueue`. `statistics` exposes hit/miss counters. |
| `StoreLocations` | The three default locations. |

All store tests use temporary directories and private UserDefaults suites.

### AppModel extensions (`Sources/HMBUI/State/AppModel+Compare.swift`, `AppModel+Settings.swift`)
All frozen members implemented. Additions (public, for CompareView and for WP3's `AppCommands`):
- Compare: `compareState(for:records:previous:)` (static, pure), `compareRecord`, `setCompareOrder(_:)`,
  `setCompareDelivery(_:)`, `toggleCompareMode()` (Y), `toggleCompareDifferences()` (D), `toggleCompareInspector()`
  (I, ⌥⌘I), `toggleCompareOriginalLatch()` (menu "Show Original"), `compareOriginalKeyDown()` /
  `compareOriginalKeyUp(heldFor:pressStarted:)` (`\` hold vs latch), `toggleCompareZoom(center:)` (Z, ⌘+/⌘−),
  `setCompareOriginalAvailable(_:)`.
- Settings: `clearableHistoryCount`, `newCustomPreset(existing:)` (static), `showLogsInFinder()`,
  `chooseSaveLocation()`, `learnedEstimatesKeyPrefix`, `learnedEstimatesResetNotification`.

Rules worth knowing:
- `openCompare` resolves a non-lossy delivery (Archive) to the first lossy one; a wedding without lossy deliveries
  does not open Compare. Spot-check → Lowest Score First, otherwise capture order. Sequence = photos with a delivered
  result (`done`/`keptOriginal`, last result per photo); failed photos are excluded; kept originals (no score) come
  last in Lowest Score First. Mode/zoom/centre/divider/inspector carry over when re-opening the same wedding.
- `stepCompare` keeps zoom, centre, mode and the `\` latch; clamps at both ends. The spot-check toast fires once,
  when stepping forward from the K-th photo (also on "next" at the last photo when the wedding has only K photos).
  Counter: "Hardest n of K" while spot-checking in Lowest Score First within the first K, else "n of N".
- `updateCompare` re-establishes invariants (no original ⇒ no Show Original/latch/Differences; divider and centre
  clamped; position in range). Y/D/`\` are no-ops without the original; the mode picker is disabled.
- `savePreset` refuses invalid presets, appends new ones (and checks them in an open setup draft), closes a matching
  `state.sheet`, persists. `deletePreset` refuses built-ins. `movePresets`/`setDefaultOn` keep `defaultOn` in preset
  order. `restoreDefaultDeliveries` restores the four built-ins (shipped definitions and order) and
  `defaultOn = [couple, website]`; **custom deliveries are kept** (after the built-ins, unchecked) — nothing is
  deleted by a restore. `clearHistory` removes finished/failed records only (in-progress stay), fixes the selection,
  closes Compare if it showed one of them, and removes the entries from the history store.

### Compare (`Sources/HMBUI/Compare/`)
- `CompareView(model:)` (stub signature kept), `CompareView(model:route:)` for
  `.navigationDestination(for: CompareRoute.self)`, `CompareView(model:initialPair:)` for the harness.
- `CompareCanvas` (NSViewRepresentable): layer-hosting `CompareCanvasView`, four clip slots (left original, original,
  delivered, differences) each with one image layer; `CATransaction` with actions disabled. Show Original hides the
  delivered slot (a visibility flip; no decode, no frame change — tested on the plan). Split divider, drag-to-pan at
  100 %, drag-anywhere-moves-divider at Fit, double-click zoom at the point, two-finger scroll pans, pinch switches
  Fit/100 %, cursor tracking for `Z`.
- `CompareGeometry` (pure): panes (2 pt gap), Fit below the 52 pt toolbar inset and never above 100 %,
  100 % = 1 image px per device px, zoom-in keeps the point under the cursor, centre clamped so the image covers the
  pane. `CompareCanvasPlan` (pure) decides what is visible where; both live and snapshot paths use it.
- `ComparePairLoader`: cached grid thumbnail placeholder at once → `comparePair(maxPixelSize: 2 × view long edge)` →
  `comparePair(maxPixelSize: nil)`; HUD mini spinner until full; next photo preloaded at screen resolution
  (cache of 3 screen pairs + the current full pair); differences computed off-main, recomputed when the full pair
  arrives; `timings` for the harness.
- `CompareDifferences`: Core Image (`CIDifferenceBlendMode` → `CIColorMatrix` → clamp → over the original's
  Rec. 709 luma at 30 %), sRGB (gamma-encoded) working space, amplification 10×, colour = the accent (teal under
  Multicolor, else `controlAccentColor`). Inputs are flattened over black first.
- `CompareKeyboard`: a local `NSEvent` monitor (installed while Compare is on screen) handles Z, `\` (key-down and
  key-up, 200 ms latch), D, Y, I, ←, →, Esc — only when the canvas window is key, no sheet is attached and no text
  field is being edited. Menu key equivalents could not deliver the `\` key-up; the monitor runs before the menu, so
  WP3's menu items stay for discoverability and still work when clicked.
- HUD (glass capsule 44 tall), side labels, centred capsules ("Original", "Connect “Wedding SSD” to compare."),
  legend, toast (2.5 s auto-dismiss), `PhotoInspector`, toolbar (Back with the wedding name, Split │ Side by Side,
  Delivery menu when > 1 lossy delivery, Differences, Zoom menu, fixed spacer, Inspector). Divider knob is interactive
  glass with `accessibilityAdjustableAction` (10 % steps), value "Divider at 50 percent", action "Show Original".
- `WP4StateCatalogue`: AppState, engine, model and view for every WP4 snapshot id (`edit-delivery`, the seven
  `compare-*`, the three `settings-*`). WP5 can use it directly.

### Edit Delivery (`Sources/HMBUI/EditDelivery/`)
`EditDeliveryForm` (pure) + `EditDeliverySheet` (500 × 560, Form(.grouped), native menu/radio pickers, long-edge
field 72 wide with monospaced digits beside the "Long edge:" radio, Cancel (Esc) / Save (Return, glass prominent),
Restore Default bottom-left for built-ins, validation message beside the buttons with a warning symbol).
Invalid options are disabled (`selectionDisabled`), an already-chosen invalid combination is shown with the exact
`validationError` message and Save is disabled — never corrected. JPEG XL shows Quality "Lossless" (disabled); the
lossy quality chosen before comes back when switching to a lossy format. `.editDeliverySheet(model:)` presents the
sheet for `state.sheet == .editDelivery`.

### Settings (`Sources/HMBUI/Settings/SettingsView.swift`)
TabView with General (gearshape), Deliveries (square.stack), Advanced (wrench.and.screwdriver), 600 wide, each tab a
non-scrolling Form(.grouped) whose height fits its content; tab = `state.settingsTab`. Deliveries: List with
checkbox/symbol well/name/spec line, drag to reorder, +, − (disabled for built-ins), Edit… (also double-click and
context menu), Restore Default Deliveries bottom-left. Advanced: Clear History… alert "Clear the history of all 38
weddings?" / "Delivered photos are not touched." [Clear] [Cancel].

## Tests and acceptance

`swift test`: **123 tests in 21 suites, all green** (repo-wide, including WP0's), zero warnings in WP4 files
(`swift build --build-tests` after touching every WP4 file). WP4 adds 4 store suites (20 tests incl. WP0's
in-memory suite) and 6 UI suites under `Tests/HMBUITests/Compare/`.

| §5.4 criterion | Status | Evidence |
|---|---|---|
| 1 Compare state machine | met | `CompareStateTests` (16): next/prev keep zoom+centre (and mode, divider, latch); K = clamp(ceil(0.03 n), 5, 12) incl. edge counts; toast once after K; `\` hold vs latch at 200 ms incl. repeat and release press; archive excluded; no-original disables Split, `\`, D (and the plan shows the delivered alone). |
| 2 Compare performance | met for flip and full pair; first frame over budget **under load** (see below) | `ComparePerformanceTests` (gated by `HMB_TEST_PHOTOS`) |
| 3 Stores | met | 2000-photo record (8000 results, 2.77 MB JSON) round-trips exactly; corrupt → `.corrupt`; presets order + defaultOn; mtime invalidation; orientation; shared generation |
| 4 Settings and Edit Delivery | met | `EditDeliveryFormTests`: every rule → exact message + Save disabled; Restore Default == shipped built-in for all four; `SettingsModelTests` persist through the stores |
| 5 Visual review | met (renders) | `WP4RenderTests` renders all 11 WP4 ids × light/dark offscreen like the harness (NSHostingView, borderless window never ordered front, `cacheDisplay`), non-blank check. Set `HMB_WP4_RENDER_DIR` to keep the PNGs. Reviewed by eye: layout, copy, dark mode. |

## Measurements (debug build, `swift test`; load average printed with every number)

| What | Result | Load (1/5/15 min) |
|---|---|---|
| History: `loadAll` of one 2000-photo record (2,765,740 bytes), median of 5 | 79 ms / 81 ms / 82 ms / 93 ms (four runs) | 5.68 / 10.63 / 7.27 / 15.99 |
| Compare, 45 MP (8256×5504) pairs, median of 3 photos: first frame (screen pair 2240 px + layer commit) | 166 ms; 179 ms (alone); 202 ms (inside the full parallel `swift test`) | 9.66; 15.75; 7.27 |
| … full-resolution pair (both decoded, `ShouldCacheImmediately`) | 362 ms; 348 ms; 376 ms | 9.66; 15.75; 7.27 |
| … Show Original flip (update + `CATransaction.flush`) | 0.05–0.06 ms | 9.66; 15.75 |

- The machine never got quiet (load 5–46 during this work; five engineers building). The compare first-frame and
  full-pair budgets and the 100 ms history budget are asserted only when the 1-minute load is < 3 (§3.11 rule);
  otherwise the tests report and only assert the flip (≤ 16 ms) and a 300 ms sanity bound for history.
- First frame at load 9.7–16 is 166–179 ms against a 150 ms budget. Both 2240 px thumbnails come from
  `CGImageSourceCreateThumbnailAtIndex` at 1/2 DCT scale on a CPU with every core busy; it needs a quiet re-run. If
  it still misses: (a) WP2's `comparePair` can use the 1/4 DCT scale (max pixel size ≤ long edge / 4 ≈ 2064 for
  45 MP — slightly under 2× a 1120 pt window), or (b) the cached grid thumbnail (shown at once by the loader) counts
  as the "embedded preview" frame. Lead to decide.
- Compare timings use a stand-in engine (`ImageIOCompareEngine` in the test: ImageIO thumbnails / full decodes, the
  "delivered" file is an ImageIO JPEG re-encode written to a temp folder), because WP2's `LiveEngine.comparePair` is
  a stub in this branch. The flip is measured on the committed layer tree; the GPU composite itself happens in the
  render server and is not part of the number.
- Debug build: Codable decoding is unoptimised; release will be faster.

## Deviations

| # | Spec | Code | Why |
|---|---|---|---|
| V1 | §2.1: `CompareView(route: $0)` with the model from the environment | `CompareView(model:route:)` (+ `init(model:)` from the WP0 stub, + `init(model:initialPair:)`) | WP0's stub takes `model:`; views do not read the model from the environment. |
| V2 | §5.4: "CALayers, tiled for 100 %" | one CALayer per image slot with the full image as `contents` (trilinear minification) | 45 MP (≤ 9504 px) fits Apple Silicon's 16384 px texture limit; the flip and pan measured well within budget. A `CATiledLayer` would add redraw latency on pan. Revisit only if > 16k px sources matter. |
| V3 | §2.5 "views never use literal colours outside Tokens.swift" | `CompareStyle.dividerLine = .white`, `.dividerShadow = black 60 %` in `CompareHUD.swift` | §2.4 S14 prescribes a white line with a dark shadow; Tokens.swift is frozen. **Question Q1.** |
| V4 | S14 Differences "overlays" | Split: the differences image covers the whole frame (divider hidden); Side by Side: it replaces the delivered pane | Half a difference map at the divider is hard to read; the left pane keeps the original in Side by Side. |
| V5 | S14 no-original: "Split is disabled" | the whole mode picker is disabled and the canvas shows the delivered photo full frame in one pane | Side by Side has nothing to show on the left either. |
| V6 | S14 fit | Fit never enlarges beyond 100 % (small resized deliveries show 1:1) | upscaling would hide exactly what Compare is for. |
| V7 | S16 Settings rendering | while snapshot rendering, `SettingsView` shows the selected tab alone (no tab strip) | the offscreen harness renders the TabView strip as opaque white; in the app the Settings scene shows toolbar tabs. |
| V8 | S14 inspector | snapshot path lays the inspector out beside the canvas (260 wide) instead of `.inspector` | the inspector column renders blank offscreen. |
| V9 | S16 Advanced | row labels "Logs", "Estimates", "History" added in front of the buttons | grouped forms need a label column; the button titles are verbatim. |
| V10 | S6 Colour footer | shown as a caption under the Colour radios inside the section, not as a section footer | keeps the whole sheet (incl. Folder name) inside 560 pt without scrolling. |
| V11 | §2.8 `\` | also key code 42 without modifiers (the key left of Return on ISO keyboards, `#` on German) | `\` is ⌥⇧7 on the owner's German keyboard; holding a three-key chord is unusable. |

## Hand-over / requirements for other packages

- **WP3 (RootView):** attach `.editDeliverySheet(model: model)` once to the main window root (Setup's Edit… and
  Add Delivery… set `state.sheet`). Settings presents its own sheet and its own Clear History alert (not
  `state.alert`), so the main window never shows them twice. Route Compare with
  `.navigationDestination(for: CompareRoute.self) { CompareView(model: model, route: $0) }`, open it with
  `model.openCompare(route)` (it pushes `detailPath`). `CompareView` renders `state.toast` while Compare is shown —
  please don't overlay the same toast in RootView while `state.compare != nil`. Menu commands can call the compare
  additions listed above. After `savePreset` adds/edits a preset during setup, the draft's estimate for it is not
  refreshed by WP4 — please re-estimate on `state.presets` changes (a new preset is already checked in the draft).
- **WP2 (`comparePair`):** (1) return images with the EXIF orientation applied (display orientation, like the
  thumbnails) — the UI has no orientation info for a photo; (2) return fully decoded images
  (`kCGImageSourceShouldCacheImmediately` or bitmap-backed), otherwise Core Animation decodes 45 MP on the main
  thread at the first commit; (3) honour `maxPixelSize` with a subsampled ImageIO decode (see first-frame note).
  (4) Learned estimates: please store them under UserDefaults keys starting with `holdmybyte.learned.` and observe
  `AppModel.learnedEstimatesResetNotification` (name `holdmybyte.learnedEstimatesReset`) — or see Q2.
- **WP5 (harness):** `WP4StateCatalogue.model(id)` + `await WP4StateCatalogue.view(id, model:)` give every WP4 state;
  compare views get their pair through `CompareView.preload(_:wedding:photo:delivery:)` so the first frame has the
  photos even when CompareView is created inside RootView. Set `\.isSnapshotRendering = true`: the canvas then draws
  with Core Graphics (`cacheDisplay` does not capture layer-hosted content) and computes Differences inline.
  `Tests/HMBUITests/Compare/WP4RenderTests.swift` shows the exact hosting sequence that works.

## Questions for the lead

- **Q1** Add `Tokens.Palette.compareDivider` (white) and `compareDividerShadow` (black 60 %) to the frozen
  Tokens.swift so `CompareStyle` can go?
- **Q2** "Reset Learned Estimates" has no engine API (`EngineService` is frozen and HMBUI does not import
  HMBEngine). WP4 clears UserDefaults keys with the prefix `holdmybyte.learned.` and posts a notification. Either
  confirm this contract to WP2, or add `func resetLearnedEstimates() async` to `EngineService`.
- **Q3** First frame 166–179 ms measured only under load 9.7–16 (budget 150 ms, quiet machine): accept the
  cached-thumbnail placeholder as the first frame, or require the 1/4-scale preview (see Measurements)?
- **Q4** `restoreDefaultDeliveries` keeps custom deliveries (restores built-ins and the default set only). Confirm,
  or should it delete custom presets too (would need a confirmation alert)?
