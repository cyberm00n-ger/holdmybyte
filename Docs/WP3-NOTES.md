# WP3 notes: app shell and job-flow UI

Branch `wp3-app-flow-ui`. Scope: `Docs/SPEC.md` §5.3 (S1–S13, S15, S17, S18, S19; the queue; persistence; volumes;
the app target). This file covers what was built, how it was checked, deviations, and questions for the lead.

## What was built

| Path | Contents |
|---|---|
| `HMBUI/State/AppModel.swift` | Every WP3 body of the frozen API. Drop → scan → setup (estimates, debounced preflight, notices) → commit → FIFO queue → run → finished/paused/stopped/failed; Start Now Instead; Try Again (per-delivery batches, so a photo is never redone where it succeeded); Create More Deliveries; relink (≥ 90 %); remove from history (entry only); bootstrap (stores, unfinished jobs → Interrupted, queued weddings re-queued); persistence (every phase change, ≥ every 5 s while running, one serial save chain); volume observation; Dock; quit flow; VoiceOver announcements every 10 %. `init` is still side-effect free. |
| `HMBUI/Shell/` | `RootView` (split view, whole-window drop delegate, alerts, sheets, toast, ⌘F focus), `SidebarView` (In Progress, month groups by wedding date, search over name/month/year/path/camera, lifetime footer, context menu), `AppModel+Bindings` (column visibility remembered, detail path, selection, `compare(…)` helper), `AppPlatform` (all system side effects behind closures: panels, Finder, file checks, volumes, Dock, notifications, terminate reply), `DemoSupport`, `EditDeliverySheetHost` (placeholder, Q1). |
| `HMBUI/Drop/` | S1–S3 drop zone, delivery preview popover, footer note, drop capsule. |
| `HMBUI/Setup/` | S4/S5/S7 header: setup form, delivery rows (estimates, Done-date in Create More, hover Edit…), location and rename rows, notice rows with their actions, bottom bar. |
| `HMBUI/Run/` | `WeddingDetailView` (phase router), S7 queued, S8/S9 run view (header, ETA copy, saved-so-far, banners, delivery strip), S10–S12 done view (result header with draw-on seal, issues card, missing-folder banner, tiles with count-down, proof card with Swift Charts histogram, chart descriptor, lowest five, quality explainer, grid header), S13 failed, the photo grid (Equatable cells). |
| `HMBUI/MenuBar/StatusMenu.swift` | S17 menu content and `StatusItemLabel` (template progress ring + "58 %"). |
| `HMBUI/Alerts/` | `AppAlert.copy(in:)` (single source for S18 and the harness), default/destructive button indices, rename sheet. |
| `HMBUI/Components/` | `Copy.swift` (all S1–S19 strings), `WeddingPresentation` (pure derived numbers, memoised for finished weddings), `ThumbnailView` (+ memory cache; synchronous fixture images while snapshot rendering), shared styles, `WP3StateCatalogue` (every WP3 snapshot id as a ready `AppModel`), `GridScrollProbe`. |
| `HoldMyByteApp/` | `@main` per §2.1 (Window "main", Settings, `MenuBarExtra(isInserted:)`, Help window), `AppDelegate` (keep alive while running, quit alert via `.terminateLater`, Dock drops, reopen), `AppCommands` (§2.8 menus and shortcuts), `DockTile` (6 pt accent bar, badge), `Notifications` (only when not frontmost and bundled; Show in Finder / Compare actions), `LiveWiring` (`AppModel.live()`), `InterimStores` (Q2). |
| `Tests/HMBUITests/AppModel/` | 49 tests (45 always run, 4 gated): `AppModelFlowTests` 23, `DropTests` 10, `ShellTests` 8, `CopyTests` 4 (one table of ~150 spec strings), `PerformanceTests` 2 + 1 probe (gated `HMB_WP3_PERF=1`), `RenderStatesTests` 1 (gated `HMB_WP3_RENDER_DIR`). |

Run the app without the engine: `HMB_FIXTURE_ENGINE=1 swift run holdmybyte` (FixtureEngine, fixture history, everything
in memory; nothing is read from or written to the real history or any photo folder).

## Acceptance criteria (§5.3)

| # | Criterion | Status |
|---|---|---|
| 1 | Intent tests (drop → … → record saved; queue order; pause/resume/stop; interrupted at bootstrap; Create More; relink ≥ 90 %; remove leaves files) | **Met.** `AppModelFlowTests` (23), all with FixtureEngine + in-memory stores; "remove leaves files" uses a real temp folder. |
| 2 | Copy table test | **Met.** All S1–S18 copy (plus S19, toolbar help, accessibility strings) in `Components/Copy.swift`; `CopyTests` checks each against the spec text in en_US and en_DE, with pluralised and interpolated variants; S18 via `AppAlert.copy`. |
| 3 | Drag and drop states | **Met.** `DropTests`: folder / files / mix summaries, targeted states per screen, only-RAW, nothing usable, scan error, add to setup, drop over Done starts a new wedding, setup within 100 ms (measured < 1 ms: setup is synchronous, the scan streams in). |
| 4 | Closing and menu bar | **Met** at the model level (`ShellTests`): running + window closed → status item inserted; removed when the job ends; `isRunning` drives `applicationShouldTerminateAfterLastWindowClosed`; quit alert → pause → Interrupted → terminate reply. The AppKit wiring itself was smoke-tested by launching the app (demo mode); a manual close/quit pass on the bundled app belongs to §6.4. |
| 5 | Performance | **Grid: met** (proxy). **Done view: borderline, see measurements.** |
| 6 | Visual review in WP5's harness, light + dark, 1120×780 and 780×560 | **WP3 side done**: all 31 WP3 ids rendered in both appearances and both sizes (124 PNGs) with `RenderStatesTests` and reviewed; fixes made (see below). The official run is WP5's harness; `WP3StateCatalogue` gives it ready models. |

`swift build` and `swift test`: green, 120 tests in the package (WP3: 52 run + 4 gated), zero warnings in WP3 files
(verified by touching all WP3 files and rebuilding).

## Measurements (shared machine; `uptime` load given with each)

| What | Result | Load (1/5/15 min) |
|---|---|---|
| History Done view load (select a finished wedding → layout → display, 38-wedding sidebar, Finn und Lissy 535 × 4), debug | median **103 ms** (95.5–104.5 after warm-up; first cold load 245 ms) | 7.1 / 7.5 / 9.1 |
| same, before memoisation | median 141 ms | 5.7 / 7.2 / 9.3 |
| same, release (`-c release -Xswiftc -enable-testing`), before memoisation | median 128 ms | 6.9 / 8.9 / 12.3 |
| Framework floor (Done view replaced by one `Text`) | 21 ms | 6.0 / 7.0 / 9.1 |
| 2000-photo grid, scripted scrolling 3 s (`GridScrollProbe`: 24 pt/frame, layout + display per frame) | **231 fps** (695 frames, worst 41 ms); 149–188 fps in other runs | 6.4 / 7.3 / 9.4 |
| Setup appears after drop | < 1 ms (synchronous; test asserts < 100 ms) | — |
| Derived numbers for 535 × 4 (debug): latest map 0.8 ms, 4 summaries 5.6 ms, grid cells 1.3 ms, lowest five 4 ms → now cached per finished record | | 6.3 |

The ≤ 100 ms Done-view budget is not proven: 103 ms median at load 7 on a 10-core machine shared by five engineers.
The gated test asserts the budget only when the 1-minute load is < 3 (the §5.5 quiet-machine rule). Remaining cost is
SwiftUI layout of the tiles and proof card (sampled with `sample`: no app code above 10 % after memoisation).
The grid figure is a CPU-side proxy (layout + draw into the backing store), not a display-linked signpost; WP5's
harness should call `GridScrollProbe.run(window:hosting:seconds:)` on a real window for the official number.

## Deviations from the spec text

| # | Spec | Code | Why |
|---|---|---|---|
| D1 | `AppAlert.copy: (title:, message:, buttons:)` | `AppAlert.copy(in: AppState, locale:) -> AlertCopy` plus `defaultButtonIndex` / `destructiveButtonIndex` | The copy needs the wedding name and counts, which live in `AppState`. |
| D2 | `.safeAreaInset(edge: .bottom) { LifetimeFooter() }` on the sidebar List | footer in a `VStack` below the List | With the inset, rows scrolled under the footer text with no edge effect (unreadable overlap in renders). |
| D3 | Views get the model via `.environment(model)` | `RootView(model:)` / `StatusMenu(model:)` (WP0 stubs) inject the environment themselves | WP0's stub signatures; WP5's harness builds `RootView(model:)`. |
| D4 | Detail column width unspecified | `.navigationSplitViewColumnWidth(min: 520, ideal: 860)` on the detail; banners limit their lines | NSHostingView measures the window's minimum size at the narrowest detail width (~120 pt): unbounded text then made the minimum height > 1000 pt, and the window content was clipped/shifted (stopped, interrupted). |
| D5 | Drop zone as a plain `ZStack` + `.padding(20)` | same, sized by a `GeometryReader` | Same min-size effect: the zone's ideal height (906 pt) overflowed the window. |
| D6 | State morph `matchedGeometryEffect` (title, mosaic → grid) and the 15 ms scan stagger (§2.7) | 0.35 s crossfade between phases only; mosaic shows the first four photos | Not done in v1 of WP3; cosmetic. |
| D7 | Remembered default deliveries change only via the S1 popover | also when a new wedding starts with a different set | Principle 2 ("every other control has a remembered default"); uses WP4's `setDefaultOn`. |
| D8 | — | Queued weddings found at launch start automatically; jobs that were running become Interrupted and wait for Resume; a user-paused job keeps holding the queue | The quit alert only covers the running job, so queued weddings were still wanted. |
| D9 | `TrailingAccessory` has no case for Failed | Failed weddings sit in their month section with the orange triangle | |
| D10 | Dates | English month names with the region's conventions even when the Mac's language is German (`Copy.uiLocale`) | The UI is English (§2.5); the demo app showed "Oktober 2026". |

## Questions for the lead

- **Q1 (merge step, Edit Delivery sheet).** `RootView` presents `AppSheet.editDelivery` with
  `Shell/EditDeliverySheetHost.swift`, a placeholder (name, spec line, Cancel). WP4's sheet type is unknown on this
  branch. At merge, replace that body with WP4's view (one line). Until then, Setup's `Edit…` / `Add Delivery…` call
  WP4's still-empty `editDelivery`/`addDelivery` stubs.
- **Q2 (merge step, stores).** HMBStore is empty on this branch, so `AppModel.live()` uses `InterimHistoryStore`
  (same layout as §5.4: `Weddings/<id>/record.json`, atomic, `.corrupt` quarantine), `InterimPresetStore`,
  `InterimSettingsStore`, `InterimThumbnails`. Four lines marked `// WP4` in `HoldMyByteApp/LiveWiring.swift` switch
  to WP4's types; then delete `InterimStores.swift`. If the live engine cannot start, `UnavailableEngine` makes every
  scan fail visibly (no fake outputs).
- **Q3 (Clear History alert).** `RootView` presents every `AppAlert` except `.clearHistory`, so it is not shown twice
  when Settings (WP4) triggers it. WP4 can present it in the Settings window with
  `.modifier(AlertPresenter(model: model) { $0 == .clearHistory })` or its own `.alert` using `AppAlert.copy`; `confirmAlert()`
  already routes `.clearHistory` to WP4's `clearHistory()`. Please confirm who presents it.
- **Q4 (accent rule vs. borderless buttons).** The spec's code uses `.buttonStyle(.borderless)` (Add Delivery…,
  Edit…, Show in Finder, Show Original, Try Again); on macOS 26 these draw in the accent colour, which §2.5's
  "accent only on…" list does not include. Kept native; say if they should be tinted `.secondary`.
- **Q5 (Compare keys in menus).** `AppCommands` declares View ▸ Comparison items calling WP4's frozen API, enabled only
  while Compare is open, so single letters never steal typing. `\` is **not** a key equivalent: a menu key equivalent
  fires on key-down only, which would break hold-to-show. WP4 should handle `\` (down/up) in the canvas. Also,
  `closeCompare()` should clear `state.detailPath` (the menu's Back calls only `closeCompare()`).
- **Q6 (engine contract for Try Again).** A retry runs `run(request, resume: false)` with `onlyPhotos` and only the
  deliveries that failed for those photos (`appendToExistingFolder: true`). WP2's journal must not drop the earlier
  results of the job on such a run.
- **Q7 (fixtures, WP0).** Synthetic thumbnails have a light triangle in the top-left corner (the linear gradient is
  drawn without extend options), and all history covers look alike (every history record starts at `DSC00001.jpg`, so
  the seeds collide). Cosmetic, visible in every snapshot.
- **Q8 (snapshot harness, for WP5).** Findings while rendering offscreen on macOS 26: `cacheDisplay` does not draw the
  content of scroll views (Form, List, ScrollView); compositing each scroll view's `documentView` over its clip view
  fixes it (`RenderStatesTests.png`). The window background must be painted first. The most faithful capture is the
  window server (`screencapture -l <windowNumber>`) of a window ordered in *below the desktop window level* with
  `ignoresMouseEvents` — invisible to the person at the Mac. Never order a titled window "offscreen" without overriding
  `constrainFrameRect`: AppKit moves it onto the screen. Alerts: add the default button first to `NSAlert`.

## Review fixes (independent review)

Covered by `Tests/HMBUITests/AppModel/ReviewFixTests.swift` (7 tests; the first five fail on the pre-review model).

- **Stale preflight on Return:** typing a name and pressing Return within the 250 ms debounce committed the previous
  preflight's output folder (old name). `startDraft` now commits only a preflight computed for the current request.
- **Create More ran with `resume: true`:** the original journal is discarded at finish, so Create More (also when found
  queued at launch) now runs as a new job (`resume: false`, `appendToExistingFolder: true`).
- **Leftover journal of a finished/failed wedding:** bootstrap no longer turns it into Interrupted; the journal is
  discarded. A queued Try Again found at launch (its photo list is not persisted) returns to Finished.
- **Idle quit dropped pending saves:** `requestQuit` now answers `.terminateLater` until the save chain is written.
- **Start Now Instead:** if the running job finished/stopped before the pause arrived, the target stayed recorded and
  could later jump the queue; it is now placed first however the job ended, then cleared.
- **Drag summary race:** the async URL load on drag-enter could re-target the zone after the drag left or dropped.
- **Single delivery tile** now spans the full width (S10); an adaptive grid kept it one column wide.
- **Try Again while the delivery folder is missing** is disabled (it would recreate the folder at the old path).
- **Notifications:** the `UNUserNotificationCenterDelegate` callback is nonisolated and hops to the main actor (a
  main-actor conformance traps if UserNotifications calls it off the main thread).
- `start()` saves the record when it switches to Running (before the engine's first event).

## How to reproduce

```bash
swift build && swift test                                              # 120 tests
HMB_WP3_PERF=1 swift test --filter 'PerformanceTests/'                 # timings (+ uptime in the output)
HMB_WP3_RENDER_DIR=/tmp/wp3 swift test --filter RenderStatesTests      # 62 PNGs (+ HMB_WP3_RENDER_SMALL=1: 780×560;
                                                                       #   HMB_WP3_RENDER_ORDER=1: window-server capture)
HMB_FIXTURE_ENGINE=1 swift run holdmybyte                              # the app on FixtureEngine
```
