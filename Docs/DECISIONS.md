# Decisions

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
