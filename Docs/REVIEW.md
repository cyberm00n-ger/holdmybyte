# Design and flow review: holdmybyte v2

Final review on `polish-app`, 2026-10-16. All 42 snapshot states were rendered in light and dark, plus the four
780×560 renders. Each of the 92 PNGs was checked against §2 of [`SPEC.md`](SPEC.md) and against current macOS 26
conventions. The three core flows (§1.2) and the flow checklist (§6.4) were traced through `AppModel` and its tests.
Defects were fixed in the UI and in the harness, re-rendered and checked again. The curated README set is in
[`assets/screenshots/`](assets/screenshots/).

## Verdict

**Ready to ship the v1 UI. Two things are still open: a check in a real window, and the owner's sign-off on four
deviations from the spec (listed below).**

The app looks and behaves like a native macOS 26 app:
- System controls throughout: a sidebar with search, a unified toolbar with grouped glass capsules, grouped `Form`s,
  `ContentUnavailableView`, real `NSAlert`s and a plain menu-bar item.
- The teal accent is used sparingly: checkboxes, the primary button, progress, the seal, links and the selected
  delivery switch. Menus, secondary buttons and banners stay neutral.

It also tells a wedding photographer a short, believable story:
- **Drop:** one large, calm target and a single sentence.
- **Setup:** the remembered deliveries are already checked, each with a measured estimate, plus one total and one
  primary button.
- **Running:** the grid turns from grey to colour, with a live "saved so far" figure.
- **Done:** big numbers per delivery, then a proof card with a histogram and the five lowest photos one click away.
  Compare works like Lightroom's.

Every number is formatted for the locale (en_DE: "1,35 GB", "74,0"). Copy matches the spec everywhere. Dark mode
holds up on every screen.

All three core flows are complete in code and covered by tests (details under "Flows" below).

Build and tests:
- `swift build` has 0 warnings.
- With `env.sh` sourced, `swift test` passed 345 tests in 62 suites in 2 min 56 s (load 5.0 → 8.4).
- The snapshot runs exit 0 with 0 blank images.

## Fixed in this review

| # | Screen | Defect | Fix |
|---|---|---|---|
| 1 | S10 done (all) | `checkmark.seal.fill` was rendered hierarchical: a pale seal that read as disabled next to the 26 pt title, and muddy in dark | Default (monochrome) rendering in the accent, as written in S10: a solid seal with the check cut out. The S11 triangle gets the same treatment |
| 2 | S11 done-issues | The 3 pt orange leading edge ran straight past the card's rounded corners (a 3 pt-wide rounded shape clamps its radii) | A plain rectangle, clipped by the card's 16 pt continuous shape |
| 3 | S10 grid header | The delivery picker and sort menu drew their icons in teal | They now use the label colour, like the toolbar and HUD menus (§2.5) |
| 4 | S14 inspector | "25,7 MB · 9504 × 6336" wrapped under its label at 260 pt | Two rows, `Original` and `Pixels` (recorded as a deviation in DECISIONS) |
| 5 | S12 missing folder | The banner read "Last seen at /Users/sebastian/Weddings/…", wrapping over two lines | `AppPlatform.homeDirectory` abbreviates the path to `~/Weddings/…`. The app uses the real home; the harness uses the fixtures' home |
| 6 | Sidebar (every screen with history) | The harness drew secondary captions solid black (light) or solid white (dark), darker than the names above them. The lifetime footer read as primary. Delivery symbols were almost invisible in dark (grey 65 on 51) | The vibrancy flattening now reproduces the plus-darker and plus-lighter blends over the glass stand-in. Glyph `ImageLayer`s and fills get the same treatment. Name, caption and header hierarchy now matches the real sidebar, and dark symbols show at the intended tertiary level |

Commits:
- `7b6e832`: the fixes, plus the rationale in DECISIONS "Final design review".
- The commit after it: this review, the screenshots, README and SNAPSHOTS.

## Per-screen notes (after fixes)

**S1–S3 Empty, errors, drag target**
- Calm and centred: a 64 pt hierarchical `photo.stack`, a 28 pt title, a glass "Choose Photos…" button, the
  "Creates:" line and the quiet lock footnote.
- The error state switches cleanly to orange `photo.badge.exclamationmark`.
- The drag target uses the accent stroke and fill as specified. It reads well in both appearances.

**S4–S6 Setup, notices, Edit Delivery**
- The grouped form sits at 760 pt and is well balanced.
- The estimate skeletons line up exactly with the values that replace them.
- Notices sit under the header (a decision from earlier in this branch), so a blocked disk is visible without
  scrolling.
- Create More: the completed rows are checked, disabled and marked "Done 14. Jul". Change… is disabled.
- Edit Delivery is a proper grouped sheet with its own title.
- The bottom bar's summary changes as the spec describes. The primary button is disabled while a block is shown.

**S7–S9 Queued, running, banners**
- "Waiting to start" uses the system empty-state style.
- Running: a large live counter, the teal progress bar, delivery capsules with live sizes, and grey-to-colour grid
  cells with mini spinners.
- Banners use the right symbols. The progress bar turns grey while paused. Resume is disabled while the drive is
  missing, and the toolbar's play button follows it. Stopped disables Stop.

**S10–S13 Done, issues, missing folder, failed**
- The result story reads top to bottom:
  - the seal and title;
  - tiles with 34 pt numbers and size bars (resized deliveries show "2560 px · WebP · 159 MB for 535 photos"; the
    archive tile shows its byte-exact line);
  - the proof card, with the delivery switch, the histogram with the Balanced band, and the lowest five with score
    capsules;
  - the grid header.
- Issues: the orange card is grouped by cause, with retry where it makes sense. The tiles' "533 of 535 photos
  delivered" is in orange and has no seal.
- Missing folder: Compare, Show in Finder and Spot-Check are disabled.
- Failed: the system empty-state style, with the title wrapping before the quoted name.

**S14 Compare**
- The divider spans only the photo. The knob sits mid-photo.
- The side labels and the HUD capsule match the spec ("42 of 535", score pill, "25,7 MB → 3,8 MB · −85 %", order
  menu).
- The inspector has clean grouped sections.
- The Differences legend and the "Original" capsule are present.
- With no original: Split, Side by Side and Differences are disabled, and a "Connect “Wedding SSD” to compare."
  capsule is shown.
- The spot-check toast sits just above the HUD.

**S15–S18 History search, Settings, menu bar, alerts**
- The search filters to "July 2026 › Finn und Lissy". A miss shows `ContentUnavailableView.search`.
- Settings uses three grouped pages at 600 pt.
- The menu-bar menu has a status line, Pause, Stop… and Open holdmybyte.
- Alerts use the new glass icon. The default button is in the accent; Remove is destructive red.

**780×560**
- Nothing overlaps in setup, running or done: tiles reflow to two columns, and sidebar names middle-truncate while
  the counts stay whole.

## Flows (§1.2, §6.4)

All three core flows, the error paths and the interrupt flow are complete in `AppModel`, and each step has a test.

**F1: Drop to deliveries.**

| Step | Where it happens | Test |
|---|---|---|
| Setup opens on the drop, before the scan finishes | `handleDrop` → `newDraft` is synchronous | `dropFolderOpensSetupImmediately` |
| A generic folder name ("fertig") takes the parent's name | `WeddingNaming` | `NamingTests` |
| The remembered deliveries are checked | — | `toggleDeliveryAndRememberDefaults` |
| Return works even while scanning | `startPending` | `startWhileScanningStartsWhenScanEnds` |
| The sidebar appears with the first job | `commit` | — |
| Closing the window keeps the job running and shows the menu-bar item | — | `closingTheWindowWhileRunningShowsTheStatusItem` |
| Dock progress | — | `progressIsAnnouncedAndShownInTheDock` |
| A notification with Show in Finder and Compare | `Notifications.swift` | — |
| Show in Finder selects the first delivery folder (`Couple`) | `revealInFinder(nil)` | — |

**F2: Spot-check the hardest photos.**
- Lowest score first, with K = clamp(ceil(3 %), 5, 12) (`spotCheckStartsLowestScoreFirst`, `spotCheckCount`).
- `Z`, hold or latch `\`, and `→` keep zoom and pan (`nextAndPreviousKeepZoomCentreModeAndLatch`,
  `showOriginalHoldVersusLatch`).
- `D` shows the differences.
- The toast appears once, after the K-th photo (`toastFiresOnceAfterTheKthPhoto`).

**F3: Find a past wedding and add a delivery.**
- ⌘F calls `focusSearch` and shows the sidebar. The search matches name, month, year, path and camera
  (`sidebarSearchMatchesNameMonthYearPathAndCamera`).
- ⌘R reveals the folder (AppCommands).
- Create More reuses the same sources and folder, and the completed deliveries are disabled
  (`createMoreDeliveriesUsesTheExistingFolder`, `cancelCreateMoreReturnsToDone`).

**§6.4 error paths**

| Path | Test or mechanism |
|---|---|
| The drive is ejected mid-run, then resumed | `driveDisconnectPausesUntilMounted` |
| The output disk fills up | `.paused(.diskFull)` |
| The output is read-only, or blocked in setup | preflight block notices; `blockingNoticeDisablesStart` |
| A RAW-only drop | `dropOnlyRawShowsTheRawError` |
| Dropping holdmybyte's own output | the scan notice |
| Interrupted, then resumed | `quitWhileRunningAsksAndInterrupts`, `unfinishedJobBecomesInterruptedAndResumes` |

## Not fixed / open

1. **Real-window check (§6.4, owner).** The harness cannot show:
   - Liquid Glass and blur: the sidebar, toolbar capsules, HUD, knob, side labels and toasts are flat stand-ins;
   - Dock progress, the notification, VoiceOver, Reduce Motion and Increase Contrast.

   §6.4 items 1–8 still need a run of the real app on the real wedding.
2. **Harness limits that remain** (the app itself is right; see SNAPSHOTS.md):
   - the light sidebar search field does not draw its text (dark does);
   - the sidebar's running ring is a white disc with a dark wedge;
   - Settings has no toolbar tab bar;
   - queued and working grid cells use a greyscale thumbnail because `.saturation(0)` does not render;
   - dark sheets have little edge contrast without the window server's shadow.
3. **Compare at 780×560 with the sidebar open.** The toolbar overflows: Zoom and Inspector move into the `»` menu.
   This is standard AppKit behaviour and every action keeps its shortcut, but a photographer at minimum width would
   do better with the sidebar collapsing automatically on entering Compare. That is a behaviour change, so it is left
   for the owner.
4. **Locale-correct dates differ from the spec's en_US examples.** en_DE shows "12. July 2026" and "Done 14. Jul"
   where the spec shows "July 12, 2026" and "Done Jul 14". This is Foundation's correct output for English
   (Germany), so it was left as is.
5. **Spec deviations that need the owner's acceptance (§6.4 last line):**
   - the dark accent is #15948C instead of #3CC8BF, for contrast (app polish);
   - the Edit Delivery sheet is 500 × 600 instead of 500 × 560 (app polish);
   - setup notices sit under the header instead of last (integration);
   - the inspector shows Original and Pixels as two rows (this review).
6. **Small things left as designed:**
   - banner actions (Resume) are plain buttons, as the spec says, not prominent ones;
   - the Balanced band shows through the translucent histogram bars;
   - an archive tile's Show in Finder drops to its own line under the long byte-exact proof line.
7. **Curated screenshots use synthetic thumbnails.** The renders made with `HMB_FIXTURE_PHOTOS` contain real client
   photos and stay local in `Snapshots/`. Gradients made the full-size PNGs too big, so images are 1120 px (1000 px
   for running) wide to stay under 500 KB.
