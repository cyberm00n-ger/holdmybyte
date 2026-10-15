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
| Vibrant text and symbols (`CATintedImage` contents, plus-lighter / plus-darker) | not drawn at all | flattened to plain images: primary labels at 88 % white (dark) / black (light), secondary proportionally |
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

## Review checklist (§6.3)

For each image: exact copy · no clipped or truncated numbers · symbols as specified · accent only on the listed
elements · dark mode legible, no hard-coded colours · the 780×560 renders without overlap.

| Id | Section | Light | Dark | 780×560 | Notes |
|---|---|---|---|---|---|
| `empty` | S1 | pending | pending | | |
| `empty-error-raw` | S2 | pending | pending | | |
| `empty-error-none` | S2 | pending | pending | | |
| `drag-target` | S3 | pending | pending | | |
| `preparing` | S4 | pending | pending | | |
| `setup-ready` | S4 | pending | pending | pending | |
| `setup-estimating` | S4 | pending | pending | | |
| `setup-warn-precompressed` | S5 | pending | pending | | |
| `setup-blocked-disk` | S5 | pending | pending | | |
| `setup-create-more` | S4, F3 | pending | pending | | |
| `drop-on-setup` | S3 | pending | pending | | |
| `edit-delivery` | S6 | pending | pending | | sheet composited over setup |
| `queued` | S7 | pending | pending | | |
| `running-early` | S8 | pending | pending | | |
| `running-mid` | S8 | pending | pending | pending | |
| `paused-user` | S9 | pending | pending | | |
| `paused-drive` | S9 | pending | pending | | |
| `paused-disk` | S9 | pending | pending | | |
| `stopped` | S9 | pending | pending | | |
| `interrupted` | S9 | pending | pending | | |
| `done-single` | S10 | pending | pending | | |
| `done-three` | S10 | pending | pending | pending | |
| `done-issues` | S11 | pending | pending | | |
| `done-kept-original` | S10 | pending | pending | | |
| `done-missing-folder` | S12 | pending | pending | | see WP5-NOTES Q2 |
| `failed` | S13 | pending | pending | | |
| `compare-split-fit` | S14 | pending | pending | pending | |
| `compare-split-100` | S14 | pending | pending | | inspector shown |
| `compare-side` | S14 | pending | pending | | |
| `compare-original-held` | S14 | pending | pending | | |
| `compare-diff` | S14 | pending | pending | | |
| `compare-no-original` | S14 | pending | pending | | |
| `compare-spotcheck-toast` | S14, F2 | pending | pending | | |
| `history-search` | S15 | pending | pending | | search "lissy" |
| `history-empty-search` | S15 | pending | pending | | search "Amsterdam" |
| `settings-general` | S16 | pending | pending | | |
| `settings-deliveries` | S16 | pending | pending | | |
| `settings-advanced` | S16 | pending | pending | | |
| `menubar-extra` | S17 | pending | pending | | |
| `alert-stop` | S9, S18 | pending | pending | | |
| `alert-quit` | S18 | pending | pending | | |
| `alert-remove` | S2.3, S18 | pending | pending | | |

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
- **Other:** `menubar-extra` = `StatusMenu` for the running job with the window closed; alerts from the alert copy
  (WP5-NOTES Q1).
