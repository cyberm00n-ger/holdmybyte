# Snapshots

`hmb-snapshot` renders every state of the UI to PNG without the window server (Docs/SPEC.md §5.5). The lead reviews
each image against §2 with the checklist below and records the result per id here (§6.3).

## Running

```bash
Scripts/snapshot.sh                 # all 42 ids × light/dark + 4 ids at 780×560 → Snapshots/index.html
Scripts/snapshot.sh setup-ready,done-three
Scripts/snapshot.sh --self-test     # proves the capture pipeline on a probe view (needs no app view)
Scripts/snapshot.sh --release       # release build of the harness
```

`snapshot.sh` sources `~/Library/Application Support/holdmybyte-dev/env.sh` for `HMB_FIXTURE_PHOTOS` when it is not
set. The binary itself is `swift run hmb-snapshot` and is configured only through the environment:

| Variable | Default | Meaning |
|---|---|---|
| `HMB_SNAPSHOT` | `all` | `all` or a comma-separated list of ids (`hmb-snapshot --list`) |
| `HMB_SNAPSHOT_DIR` | `./Snapshots` | output directory (git-ignored) |
| `HMB_SNAPSHOT_APPEARANCE` | `both` | `light`, `dark` or `both` |
| `HMB_SNAPSHOT_SIZE` | `1120x780` | window size in points |
| `HMB_SNAPSHOT_LOCALE` | `en_DE` | locale (English text, German number formatting) |
| `HMB_SNAPSHOT_SETTLE` | `0.7` | seconds each state runs before capture (animations, `.task`s, thumbnails) |
| `HMB_FIXTURE_PHOTOS` | unset | folder of local photos used as thumbnails (outputs stay local) |
| `HMB_SNAPSHOT_DUMP` | unset | print the view tree before and after the capture rewrites (harness debugging) |

Outputs: `<id>-light.png`, `<id>-dark.png` (at the backing scale, 2×), `<id>@780x560-<appearance>.png` for
`setup-ready`, `running-mid`, `done-three` and `compare-split-fit`, `manifest.json` (per image: id, spec section,
surface, size, pixels, dominant-colour fraction, blank flag, error, time; per run: locale, size, settle time, load
average before and after, macOS) and `index.html`, a contact sheet with light and dark side by side.

Exit status: 0 when every image rendered and none is blank (> 99 % of pixels one colour); 1 otherwise; 64 for usage
errors.

Other modes: `hmb-snapshot --list` prints the catalogue ids; `--render-icon <dir.iconset>` draws the placeholder app
icon (used by `Scripts/make-icon.sh`); `--self-test [dir]` renders a probe view with a glass sidebar, toolbar
platter, vibrant sidebar text, a sheet, materials, the glass-button fallback and a CALayer-backed NSView in both
appearances and checks the pixels where each must show.

## How it renders (and what it cannot show)

Each catalogue entry builds an `AppState` from `HMBFixtures` and hosts the view in a window that is created but never
ordered front: `RootView(model:)` in a titled, unified-toolbar window (so the toolbar, title and subtitle render),
`SettingsView(model:)` at 600 wide with its fitting height, `StatusMenu(model:)` in a borderless panel, and alerts
as real `NSAlert`s. The model is `AppModel(state:engine:history:presetsStore:settingsStore:thumbnails:)` with a
`FixtureEngine` (scripted per entry, e.g. the unavailable compare original), in-memory stores and
`FixtureThumbnails`; `init` has no side effects (§5.0.3). The environment carries the model (also as
`.environment(model)`), `\.isSnapshotRendering = true` and `\.locale`. `Locale.current` is set to the run locale as
well, so `HMBFormat`'s defaults format like the views.

`cacheDisplay(in:to:)` draws the view tree itself; that works while the screen is locked. What the window server
composites is not available that way, so before each capture the harness rewrites (measured on macOS 26.0):

| Construct | Offscreen without the rewrite | Rewrite |
|---|---|---|
| Liquid Glass (`NSGlassEffectView`: sidebar, toolbar platters) | opaque white, hides its content | a flat stand-in (window background blended 7 % toward the label colour, hairline, same corner radius); the glass's content view moves into it |
| `CABackdropLayer`, `NSScrollPocket` (blur behind bars, scroll-edge effect) | solid blocks | hidden |
| Vibrant text and symbols (`CATintedImage` contents, plus-lighter / plus-darker) | not drawn at all | flattened to plain images in the image's own `tint` × the layer's `contentsMultiplyColor`; plus-lighter/darker text at 88 % white (dark) / black (light), secondary proportionally |
| Glass content moved into the stand-in | constraints to views outside the glass are lost (the search field shrank to a sliver) | frames that changed are pinned back |
| Inactive window look (offscreen windows are never key) | grey traffic lights, grey default buttons and selection | the harness process reports the app active and every window key and main |
| Sheets (`.sheet`) | a separate `SheetPresentationWindow` that never attaches to an invisible parent | captured separately and composited centred under the toolbar with a shadow |
| `hmbGlass` / `hmbGlassButtonStyle` | (WP0) fall back to `.regularMaterial` / `.bordered(Prominent)` under `isSnapshotRendering` | none needed; materials render |

Consequences for review: glass surfaces are flat, vibrancy is approximated (sidebar text contrast is close to, not
exactly, the real one), and there is no desktop behind the window. Layout, copy, typography, symbols, colours and
accent use are exact. Animations do run offscreen (measured: a 0.6 s ease-out finishes after ≈ 0.7 s), hence the
0.7 s settle time.

**Screen lock.** The capture path uses no window-server capture API (`CGWindowListCreateImage`, ScreenCaptureKit,
`screencapture`), only windows that are never shown and `cacheDisplay`, the path that jpegos' harness proved with a
locked screen (LESSONSLEARNED §15). On 2026-10-15 the screen was unlocked (`IOConsoleLocked = false`), so the run
below was not repeated locked; over SSH the process must run in the user's GUI session (`launchctl asuser`), because
`NSApplication` needs a WindowServer connection even when nothing is shown.

## Measurements

| Date | Build | Images | Time | Load (1/5/15) | Notes |
|---|---|---|---|---|---|
| 2026-10-15 | WP5 branch, release, settle 0.7 s | 92 (42 ids × 2 + 4 × 2) | 81.4 s | 7.28 13.71 17.54 → 4.58 11.35 16.29 | WP3/WP4 views still WP0 stubs: 39 light window renders count as blank (the stub is a centred `ContentUnavailableView` on white) |
| 2026-10-15 | WP5 branch, debug, settle 0.45 s | 92 | 67.6 s | 13.99 11.27 9.46 | same stubs |
| 2026-10-15 | `--self-test`, release | 2 renders, 8 checks | 2 s | 4.42 | 8/8 pass |
| 2026-10-15 | `int-app` (all packages merged), release, settle 0.7 s | 92 (42 ids × 2 + 4 × 2) | 102.5 s | 18.41 17.36 17.95 → 15.51 16.64 17.60 (Lightroom and builds running) | exit 0, 0 blank (largest one-colour share 92.2 %); reviewed below |
| 2026-10-15 | `int-app` verification, before fixes, release | 92 | 94.7 s | 14.58 29.72 30.25 → 8.48 23.56 27.81 | exit 0; 30 PNGs reviewed (both appearances, 780×560): teal secondary buttons, truncated sidebar names, cramped tile footers, "533 of 535 met their target" |
| 2026-10-15 | `int-app` verification, after fixes, release | 92 | 96.9 s | 6.80 17.01 23.66 → 5.29 13.65 21.61 | exit 0, 0 blank; the four defects above fixed (Docs/DECISIONS.md) |

## Review checklist (§6.3)

For each image: exact copy · no clipped or truncated numbers · symbols as specified · accent only on the listed
elements · dark mode legible, no hard-coded colours · the 780×560 renders without overlap.

| Id | Section | Light | Dark | 780×560 | Notes |
|---|---|---|---|---|---|
| `empty` | S1 | pass | pass |  |  |
| `empty-error-raw` | S2 | pass | pass |  |  |
| `empty-error-none` | S2 | pass | pass |  |  |
| `drag-target` | S3 | pass | pass |  |  |
| `preparing` | S4 | pass | pass |  | scan shimmer in the mosaic and estimate column |
| `setup-ready` | S4 | pass | pass | pass | notices now sit under the header; bottom bar opaque offscreen |
| `setup-estimating` | S4 | pass | pass |  |  |
| `setup-warn-precompressed` | S5 | pass | pass |  |  |
| `setup-blocked-disk` | S5 | pass | pass |  | the block is visible next to the disabled button (was below the fold) |
| `setup-create-more` | S4, F3 | pass | pass |  | was the empty drop zone (wrong selection in the harness) |
| `drop-on-setup` | S3 | pass | pass |  |  |
| `edit-delivery` | S6 | pass | pass |  | WP4's sheet, composited; "Size" and "px" were white (tint fix) |
| `queued` | S7 | pass | pass |  |  |
| `running-early` | S8 | pass | pass |  | queued/working cells greyscale (saturation filter does not render offscreen) |
| `running-mid` | S8 | pass | pass | pass | progress bar teal (was the system blue: `.tint(nil)`); sidebar counts no longer truncate at 780 |
| `paused-user` | S9 | pass | pass |  |  |
| `paused-drive` | S9 | pass | pass |  | Resume disabled (drive not mounted) |
| `paused-disk` | S9 | pass | pass |  |  |
| `stopped` | S9 | pass | pass |  |  |
| `interrupted` | S9 | pass | pass |  |  |
| `done-single` | S10 | pass | pass |  | one tile spans the width |
| `done-three` | S10 | pass | pass | pass | tiles fill the row (3 → 3 columns; 2 × 2 at 780); size lines wrap instead of truncating |
| `done-issues` | S11 | pass | pass |  |  |
| `done-kept-original` | S10 | pass | pass |  | showed done-issues' issues before (presentation memo); now the kept-original note |
| `done-missing-folder` | S12 | pass | pass |  | banner shown (harness marks the folder missing); Compare/Finder/Spot-Check disabled |
| `failed` | S13 | pass | pass |  |  |
| `compare-split-fit` | S14 | pass | pass | pass | the photo was missing (pair not preloaded); duplicate title removed |
| `compare-split-100` | S14 | pass | pass |  | inspector beside the canvas; capture date in the app's date style |
| `compare-side` | S14 | pass | pass |  |  |
| `compare-original-held` | S14 | pass | pass |  |  |
| `compare-diff` | S14 | pass | pass |  |  |
| `compare-no-original` | S14 | pass | pass |  | Split, Side by Side and Differences disabled |
| `compare-spotcheck-toast` | S14, F2 | pass | pass |  | "Hardest 12 of 12" |
| `history-search` | S15 | pass | pass |  | search text itself not drawn offscreen (see limits) |
| `history-empty-search` | S15 | pass | pass |  |  |
| `settings-general` | S16 | pass | pass |  |  |
| `settings-deliveries` | S16 | pass | pass |  |  |
| `settings-advanced` | S16 | pass | pass |  |  |
| `menubar-extra` | S17 | pass | pass |  | laid out like the menu (AppKit draws the real one) |
| `alert-stop` | S9, S18 | pass | pass |  | copy from `AppAlert.copy` |
| `alert-quit` | S18 | pass | pass |  |  |
| `alert-remove` | §2.3, S18 | pass | pass |  | Cancel default, Remove destructive |

Reviewed on 2026-10-15 (run above) by the integration lead, every PNG against §2 (layout, copy, symbols, tokens, light
and dark). Defects found and fixed are in the notes and in `Docs/DECISIONS.md`.

**Known limits of the offscreen renders** (the app is right; verified against a window-server capture):
- the sidebar search field's text is not drawn (the clear button shows that it has text);
- SwiftUI materials (`.ultraThinMaterial` score pills on the lowest-five thumbnails, the drop capsule, the Compare HUD
  and side labels) render without their blur, so their text sits on the photo;
- the sidebar's running ProgressView ring draws in the label colour, and `.tertiary` delivery symbols are faint in
  dark;
- `.saturation(0)` does not render: queued/working grid cells get a greyscale thumbnail while snapshot rendering.
- Settings renders the selected tab without its toolbar tab bar (`SettingsView`'s snapshot path skips the `TabView`);
- NSAlert's default button is the system blue (no `AccentColor` asset; see Docs/DECISIONS.md), as in the real app.

## What each state contains

All states use `Fixtures` (Finn und Lissy: 535 photos, 10.95 GB, ILCE-7RM5, July 12, 2026) and the en_DE locale.

- **Empty and drop:** empty history, sidebar hidden (`.detailOnly`); `dropZone` idle, `.error(.onlyRaw("Finn und Lissy", 535))`,
  `.error(.noPhotos)`, `.targeted(.folder("Finn und Lissy"))`.
- **Setup:** `selection = .newWedding`, a `SetupDraft` named "Finn und Lissy" with Couple’s Package and Website on.
  `preparing`: scanning, 212 found, estimates pending. `setup-ready`: scan done, `Fixtures.estimates`, preflight to
  `…/Finn und Lissy – Deliveries`. `setup-estimating`: scan done, estimates pending. `setup-warn-precompressed`: scan
  notice `.alreadyCompressed(312 of 535)`. `setup-blocked-disk`: preflight notice `.notEnoughSpace("Macintosh HD",
  1.9 GB, 0.8 GB)`. `setup-create-more`: `existingWedding` = Finn und Lissy (Couple + Website done on Jul 14), Archive
  ticked, sidebar with history. `drop-on-setup`: `draft.isDropTargeted` and `dropZone = .targeted(.photos(24))`.
  `edit-delivery`: `sheet = .editDelivery(Couple’s Package, isNew: false)`.
- **Jobs:** Finn und Lissy with Couple + Website via `Fixtures.inProgress`, history in the sidebar, grid delivery
  Couple. `running-early`: 6 done (no ETA). `running-mid` and the banners: 312 done; phases `.paused(.user)`,
  `.paused(.sourceUnavailable("Wedding SSD"))`, `.paused(.diskFull("Macintosh HD", 0.6 GB))`, `.stopped`,
  `.interrupted`. `queued`: Anna und Ben (412 photos) waits behind the running Finn und Lissy.
- **Results:** `selection = .wedding(Finn und Lissy)`. `done-single`: Couple only. `done-three`: Couple, Website,
  Social. `done-issues`: `Fixtures.withIssues` (2 unreadable, 1 Website encode failure). `done-kept-original`:
  `Fixtures.keptOriginal(7)`. `failed`: `Fixtures.failed` ("“Wedding SSD” was disconnected before any photo was
  finished.").
- **Compare:** Couple’s Package, photo 42 of 535, capture-time order; `compare-split-100` at 100 % around (0.42, 0.38)
  with the inspector; `compare-no-original` with the engine reporting "Wedding SSD" unavailable;
  `compare-spotcheck-toast`: lowest-score order, position K − 1 = 11 and the toast.
- **History:** search "lissy" (match) and "Amsterdam" (no match).
- **Settings:** `settingsTab` general / deliveries / advanced, history of 38 weddings.
- **Other:** `menubar-extra` = `StatusMenu` for the running job with the window closed; alerts from `AppAlert.copy`.
- **Harness hooks:** a scenario's `missingFolders` make the inert platform report those folders missing
  (`done-missing-folder`); Compare states get their pair from the scenario's FixtureEngine before the first frame
  (`CompareView.preload`); `Tokens.forcesMulticolorAccent` renders the teal accent; `HMB_SNAPSHOT_DUMP=1` prints the
  view tree before and after the capture rewrites.
