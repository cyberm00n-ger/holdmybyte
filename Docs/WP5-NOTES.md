# WP5 notes: snapshot harness, CLI, benchmarks and bundling

Branch `wp5-harness-cli-bench`. What was built, how it was measured, where it deviates from `Docs/SPEC.md` §5.5, and
the questions for the lead. Everything below was measured on 2026-10-15 on the shared M1 Max while other engineers
were building (load averages are given with each timing).

## What was built

| Path | Contents |
|---|---|
| `Sources/HMBSnapshot/main.swift` | `hmb-snapshot`: options (§5.5 variables + `HMB_SNAPSHOT_SETTLE`), run loop, manifest, exit status; `--list`, `--render-icon`, `--self-test` |
| `Sources/HMBSnapshot/StateCatalogue.swift` | the 42 §5.5 ids with spec section, surface (window, settings, menu bar, alert), the 4 extra 780×560 renders, and a builder per state from `HMBFixtures` |
| `Sources/HMBSnapshot/SnapshotRenderer.swift` | `AppModel(state:…)` with `FixtureEngine`, in-memory stores and `FixtureThumbnails`; hosts `RootView`, `SettingsView`, `StatusMenu`; NSAlert rendering; sheet compositing |
| `Sources/HMBSnapshot/OffscreenCapture.swift` | never-ordered-front windows, `cacheDisplay`, the glass/backdrop/vibrancy rewrites and the active-window look (see `Docs/SNAPSHOTS.md`) |
| `Sources/HMBSnapshot/SnapshotOutput.swift` | PNG writer, blank check (> 99 % one colour), `manifest.json`, `index.html` contact sheet |
| `Sources/HMBSnapshot/AlertCopy.swift` | the S9/S18/§2.3 alert copy (stand-in for WP3's `AppAlert.copy`, Q1) |
| `Sources/HMBSnapshot/HarnessSelfTest.swift` | pipeline proof on a probe view (8 pixel checks) |
| `Sources/HMBSnapshot/AppIconArt.swift` | the placeholder icon (white print on a teal glass slab), drawn in CoreGraphics |
| `Sources/HMBBench/*` | `HMBCommand` (parsing), `CommandRunner` (compress / estimate / bench over any `EngineService`), `PrimitiveCommands` (score / inspect), `EngineJobRunner`, `OldEngineRunner`, `PathSafety`, `DeliveryCatalog` + `BalancedTarget`, `BenchReport` + CSV, `MachineState` / `ResourceUsage` / `Provenance`, `Baselines`, `GateEvaluator` (G1–G8), `OutputDigest` |
| `Sources/hmb/main.swift` | wiring only: `LiveEngine` (support folder in `$TMPDIR/holdmybyte-cli-<pid>`, never the app's), `EnginePrimitives.live()` |
| `Tests/HMBBenchTests/*` | 34 tests (below); `Scaffold/` deleted as WP0 allowed |
| `Scripts/bundle-app.sh` `make-icon.sh` `snapshot.sh` `bench.sh` `check-repo.sh` `notarize.sh` | §4.2, §5.5, §6 |
| `Benchmarks/baselines.json` | DATENLAGE §1b/§7/§8 totals and times, JPEGmini, holdout per-file numbers, gate thresholds |
| `Docs/SNAPSHOTS.md`, `Docs/BENCHMARKS.md` | how to run, rendering notes, review checklist, report format, reference numbers |

## Acceptance criteria (§5.5)

| # | Criterion | Status |
|---|---|---|
| 1 | `swift run hmb-snapshot` renders all catalogue ids in both appearances without the window server in ≤ 120 s | **Met for the harness, not yet for the views.** All 42 ids × 2 + 4 × 2 = 92 images render in 81.4 s (release, settle 0.7 s, load 7.3 → 4.6) with no window-server capture API. On this branch the views are WP0 stubs: 39 light window renders are flagged blank (a centred `ContentUnavailableView` on white is > 99 % one colour), so the run exits 1 until WP3/WP4 merge — the blank check doing its job. `--self-test` (glass sidebar, toolbar, vibrant text, sheet, materials, glass-button fallback, CALayer view) passes 8/8 in both appearances. The screen was **unlocked** during these runs (`IOConsoleLocked = false`); the locked-screen run is still to be done (Q9). |
| 2 | `bundle-app.sh` produces a launchable `.app`; audit passes; `codesign --verify --deep` succeeds | **Met.** `Scripts/bundle-app.sh --smoke`: 43.6 s (release builds incremental, load 12.9), `build/holdmybyte.app` 5.3 MB, `otool -L` system libraries only, no Homebrew strings, `codesign --verify --deep --strict` valid, the app was still running after 4 s, bundled `hmb --version` prints the codec versions. |
| 3 | `HMBBenchTests`: CSV/JSON schema; gate evaluation against a synthetic baseline; refusal when `-o` is inside a source | **Met.** 34 tests: CSV columns/escaping, JSON round trip and required keys, totals maths, G1–G8 pass/fail/not-evaluated (incl. the quiet-machine rule) on a synthetic baseline, set-kind detection, `-o`/`--json`/`--out` refusal (inside, equal, loose file's folder, case variant, symlink) before the engine is even created, bench end-to-end over a file-backed fake engine (repeats, determinism, stop/resume), the repo `baselines.json`, catalogue ids == §5.5 (parsed from `SPEC.md`), the old-engine parser, and one live old-engine run (gated by `HMB_OLD_ENGINE` + `HMB_HOLDOUT`). |
| 4 | `check-repo.sh`: no photos, no `unsafeFlags`, no Homebrew strings in `Package.swift`/scripts except the audit regex | **Met**, plus: tracked generated outputs, `_jpeg_` exports in the codec archive (B3), and the B5 network audit (`nm -u` + `otool -L` of the bundle's binaries) — green on the bundle above. |
| 5 | `baselines.json` with DATENLAGE §1b/§8 totals and times, JPEGmini, holdout per-file old bytes and reference scores | **Met.** Holdout sum = 49,806,559 bytes (= "49.81 MB"), checked by a test. |

`swift build` (debug and release) and `swift test` are green with zero warnings: 97 tests in 18 suites (34 of them
WP5's), with the `env.sh` variables set.

## Measurements

| What | Result | Load (1/5/15 min) |
|---|---|---|
| Full snapshot run, release, settle 0.7 s | 92 images in 81.4 s (≈ 0.88 s per image; alerts ≈ 0.29 s) | 7.28 13.71 17.54 → 4.58 11.35 16.29 |
| Full snapshot run, debug, settle 0.45 s | 92 images in 67.6 s | 13.99 11.27 9.46 |
| Offscreen animation check | a 0.6 s ease-out is complete after ≈ 0.7 s in a never-shown window → default settle 0.7 s | — |
| `bundle-app.sh --smoke` | 43.6 s, 5.3 MB bundle | 12.85 18.71 19.87 |
| Old engine `squeeze -p classic`, 2 holdout photos | 2.15 s wall, 1.80 s user, peak RSS 2.39 GB, bytes identical to the baseline | 9.17 15.89 18.62 |
| `hmb bench` / gates | not runnable yet: `LiveEngine` and `EnginePrimitives.live()` are WP0 stubs on this branch | — |

## Deviations and additions

1. **Titled windows instead of "borderless".** §5.5 says borderless; the harness uses a titled, unified-toolbar
   window (never ordered front) so the toolbar, title and subtitle — part of every §2.2 state — are in the image.
   Settings is a titled window too; the menu-bar extra a borderless panel.
2. **Capture rewrites** (glass stand-ins, hidden backdrops/scroll pockets, flattened `CATintedImage` vibrancy,
   active-window look via swizzled `NSWindow`/`NSApplication` appearance queries, sheet compositing). All measured,
   all harness-only (the swizzles live in the `hmb-snapshot` process). Limits are listed in `Docs/SNAPSHOTS.md`.
3. **Additions:** `HMB_SNAPSHOT_SETTLE`; `hmb-snapshot --list`, `--render-icon`, `--self-test`; `manifest.json` also
   records the dominant-colour fraction and per-image time.
4. **`hmb bench` extras:** `--resume-check` (in-process G8), `--set-kind`, `--baselines`, `--workers`; writes
   `report.json`, `files.csv`, `summary.txt`; refuses a non-empty `--out`. Old-engine mapping: Couple → `-p classic`,
   High full-size → `-t 85`, Highest → `-t 90`, Website → `-p web`, Social → `-p social`, Archive → `-p archive`.
5. **`hmb` delivery names** `high-full` / `highest-full` are custom presets (`DeliveryCatalog`), ids `high-full` /
   `highest-full`, folders `High` / `Highest`.
6. **`check-repo.sh`** allows Homebrew paths on lines that `grep` for them (audits) and in
   `CMAKE_IGNORE_PREFIX_PATH` (WP0's `build-codecs.sh` needs both).
7. **CLI path guard** is stricter than "inside a source root": for loose source files their folder counts as a root
   (mirrors what the scanner will report as `sourceRoots`). It compares resolved paths case- and
   normalisation-insensitively and device/inode of every existing ancestor.
8. **Peak RSS** in reports is the process's lifetime peak (`ru_maxrss` cannot be reset), so with `--repeat` it is the
   peak up to that run.

## Open questions for the lead

- **Q1 — `AppAlert.copy`.** The harness needs WP3's single source of alert copy (§5.3). It does not exist on this
  branch, so `Sources/HMBSnapshot/AlertCopy.swift` carries the spec strings in the same `(title, message, buttons)`
  shape. The copy needs context (wedding name, done/total counts), so a plain property on `AppAlert` cannot produce
  it; I suggest WP3 exposes `AppAlert.copy(in: AppState)` (or `AppModel.copy(for:)`). After WP3 merges,
  `AlertCopy.copy(for:in:)` becomes a forward to it. Also: which button is the default in "Remove from history"
  (the spec marks none; the harness uses Remove, destructive)? macOS places Cancel/Esc buttons on the left, so the
  rendered order is `[Cancel] [Remove]`, not the listed `[Remove] [Cancel]`.
- **Q2 — "folder missing" in done states.** Fixture output folders (`/Users/sebastian/Weddings/…`) never exist on a
  build machine, so if WP3 decides S12 by checking the file system, *every* done state renders the missing-folder
  banner and `done-missing-folder` cannot be told apart. Proposal: WP3 adds an injectable check on `AppModel`
  (e.g. `public var folderExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }`); the harness
  then sets `{ _ in true }` except for `done-missing-folder`. Needs a two-line harness change once the member exists.
- **Q3 — `--workers N`.** `JobRequest` has only `processorUse`. `hmb` maps N ≤ 2 to `.gentle`, otherwise
  `.automatic`, and exports `HMB_WORKERS=N`. WP2 could honour `HMB_WORKERS` in `WorkerPool` (CLI/bench only), or the
  lead drops the flag.
- **Q4 — view entry points.** The harness calls `RootView(model:)`, `SettingsView(model:)` and `StatusMenu(model:)`
  (the WP0 stub signatures) and also injects `.environment(model)`. If WP3/WP4 change these initialisers, the harness
  needs the matching one-line change.
- **Q5 — state the views must read.** The catalogue drives views only through `AppState`: setup is
  `selection = .newWedding` + `draft` (also for Create More, with `draft.existingWedding`), sheets from `state.sheet`,
  Compare from `detailPath` + `compare`, the toast from `state.toast`, the Settings tab from `state.settingsTab`, the
  drop-over-setup capsule from `draft.isDropTargeted`. WP3/WP4 please confirm or tell me where they differ.
- **Q6 — `isSnapshotRendering` and motion.** Count-ups (0.6 s), draw-on, stagger and the 0.35 s morphs run offscreen,
  which is why the settle time is 0.7 s. If WP3/WP4 show final values when `\.isSnapshotRendering` is true, the settle
  time can go back to ≈ 0.45 s (the debug run above took 67.6 s with it) and no frame can be caught mid-animation.
- **Q7 — accent colour.** `Tokens.usesMulticolorAccent` reads the build machine's `AppleAccentColor`, so the
  snapshots' accent depends on who renders them. Should the harness force the Multicolor (teal) accent? That needs a
  hook in `Tokens` (frozen, WP0).
- **Q8 — G8 and G9.** `--resume-check` covers stop → resume → byte-identical in one process; "quit and relaunch" and
  G9 (source SHA-256 manifest) stay manual (§6.4).
- **Q9 — locked-screen proof.** Not yet run with the screen locked (it was unlocked all session). The path uses no
  window-server capture API; please lock the screen and run `Scripts/snapshot.sh --self-test` once (2 s).

## README sections (for the lead to paste; the README is WP0's)

**Build** (append after the existing block):

```markdown
Release bundle, icon and audits:

```bash
Scripts/bundle-app.sh            # build/holdmybyte.app (ad hoc signed; hmb in Contents/Helpers); --smoke launches it
Scripts/check-repo.sh            # hygiene + network audit of the built binaries
Scripts/notarize.sh              # Developer ID + notarytool (DEVELOPER_ID, NOTARY_PROFILE; owner only)
```

Screenshots of every UI state, rendered offscreen (works with the screen locked):

```bash
Scripts/snapshot.sh              # → Snapshots/index.html (see Docs/SNAPSHOTS.md)
```
```

**Benchmarks** (replace the placeholder):

```markdown
`hmb bench` measures holdmybyte on a folder of photos and compares it with the old engine, JPEGmini's numbers and the
v2 gates (`Benchmarks/baselines.json`). `Scripts/bench.sh holdout | wedding-couple | wedding-all | …` runs one gate
set into `Benchmarks/runs/`; results, with the machine state of every timing, are in
[`Docs/BENCHMARKS.md`](Docs/BENCHMARKS.md). Timing gates are only reported on a quiet machine (1-minute load < 3).
```
