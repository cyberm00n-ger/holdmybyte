# Benchmarks

How holdmybyte v2 is measured, the reference numbers it is measured against, and (after the last merge) the results of
the §6.2 gates. Every timing is reported with the machine state it was taken in.

## Running the gates

```bash
source "$HOME/Library/Application Support/holdmybyte-dev/env.sh"   # HMB_HOLDOUT, HMB_WEDDING, HMB_OLD_ENGINE
Scripts/bench.sh holdout            # G1 + G2: holdout 19, Couple’s Package, 2 repeats, A/B/A/B with the old engine
Scripts/bench.sh wedding-couple --resume-check   # G3 (+ G8)
Scripts/bench.sh wedding-high       # G4: custom High full-size (JPEG, full, ≥ 85)
Scripts/bench.sh wedding-website    # G5: Website alone
Scripts/bench.sh wedding-social     # G5: Social & Blog
Scripts/bench.sh wedding-archive    # G6: Archive alone
Scripts/bench.sh wedding-all        # G7: all four deliveries in one run
```

Each run writes `Benchmarks/runs/<timestamp>-<name>/` (git-ignored): `report.json`, `files.csv`, `summary.txt`, the
outputs under `new/run-N/` and the old engine's under `old/run-N/`. Selected summaries are copied into this file. The
script is a thin wrapper over:

```
hmb bench --set <dir> --out <dir> [--delivery NAME]… [--repeat N] [--old-engine <squeeze>] [--label TEXT]
          [--resume-check] [--set-kind holdout|wedding|other] [--baselines Benchmarks/baselines.json] [--workers N]
```

**Rules built into the bench**
- **Quiet machine (§5.5):** when the 1-minute load average exceeds 3 at start, timing gates are reported as
  `not-evaluated` (the report says why); bytes and scores are still reported. Lightroom running is recorded.
- **Repeats:** timing gates use the fastest holdmybyte run (§6.2). With `--repeat` ≥ 2 the bench also checks that the
  repeats are byte-identical (§3.12 guarantee 5).
- **Old engine A/B:** with `--old-engine`, each repeat runs holdmybyte and then the old `squeeze` (`-p classic` for
  Couple’s Package, `-t 85` for High full-size, `-p web`, `-p social`, `-p archive`) on the same files, alternating.
  Its outputs go to `--out/old/`, and the bench refuses an `--out` inside the old engine's checkout.
- **Timing "alone":** G3, G5 (Website), G6 and G7 count wall time only for runs that contain exactly the gate's
  deliveries.
- **Safety:** `--out` (and every output path) must not be inside the set; the engine's `OutputWriter` guards every
  file as well. The bench also refuses a non-empty `--out`.
- **G8 (`--resume-check`):** after the timed runs, the job runs again into `--out/resume`, is stopped once 40 % of the
  photos are done, resumed (`run(resume: true)`) and compared file by file (SHA-256) with run 1; leftover `*.tmp` or
  `.holdmybyte-partial` fail it. This is an in-process stop/resume; the "quit and relaunch" part of G8 stays a manual
  check (§6.4 item 6).

## Report format

`report.json` (schema 1):

| Field | Contents |
|---|---|
| `set` | path, kind (`holdout` / `wedding` / `other`, detected from the baseline's file names or photo count and size), photos, source bytes |
| `deliveries` | the `DeliveryPreset`s that ran |
| `runs[]` | engine (`holdmybyte` / `old`), repeat, wall s, CPU s (`getrusage`; children for the old engine), s/photo, CPU-s/photo, peak RSS (process peak so far), final phase, per-delivery totals, load before and after |
| `runs[].deliveries[]` | photos, delivered, kept original, failed, byte-exact, source and output bytes, saved fraction, min/median/max score, photos below target, mean/max probes, the engine's estimate and its error |
| `rows[]` | per file and run (also `files.csv`): name, source bytes, output bytes, score, target, probes, seconds, encoder, chroma, status, byte-exact |
| `machineBefore` / `machineAfter` | load averages, thermal state, `hw.model`, cores, physical and available memory, Lightroom running, macOS |
| `provenance` | git commit (and whether the tree is dirty), linked codec versions |
| `deterministic` | repeats byte-identical (with ≥ 2 repeats) |
| `resumeCheck` | G8 details |
| `gates[]` | G1–G8: `pass` / `fail` / `not-evaluated` / `not-applicable` with the measured numbers |

## Reference numbers (`Benchmarks/baselines.json`)

Copied as numbers from jpegos `Benchmarks/DATENLAGE.md` and the old-holdout files; no photo or output is committed.

**Wedding "Finn und Lissy"** (535 × 45 MP, 10.95 GB):

| | Bytes | Saved | Scores min / median / max | Wall |
|---|---|---|---|---|
| JPEGmini Pro 5 | 5.36 GB | −50.0 % | 75.0 / 89.9 / 93.5 | 226 s (0.42 s/photo, 2.3 CPU-s/photo) |
| Old engine, Couple (Classic) | 1.35 GB | −87.7 % | 74.0 / 74.5 / 76.2 | 17.4 min |
| Old engine, ≥ 85 full size | 3.05 GB | −72.1 % | 85.0 / 85.5 / 87.3 | 31.7 min |
| Old engine, Website (WebP 2560, ≥ 70) | 159 MB | −98.5 % | ≥ 70 | 3.7 min |
| Old engine, Social (JPEG 1440, ≥ 85) | 155 MB | −98.6 % | ≥ 85 | 7.1 min |
| Old engine, Archive (JXL lossless) | 8.55 GB | −21.9 % | 535 byte-exact | 11.3 min |
| Old engine, all four (four runs) | 10.21 GB | | | 39.5 min |

**Holdout** (19 photos from the wedding, 400.28 MB): old engine 49,806,559 bytes (49.81 MB) at Balanced, 42.6 s wall,
3.79 full probes per photo; per file: source bytes, old bytes, libjxl reference score, old engine score.

**Gates** (§6.2): G1 ≤ 50,301,670 bytes (the old engine held to v2's measured floor, Docs/DECISIONS.md D-ENG-1; the
spec's 50.31 MB was old + 1 % on the old engine's own scale), mean probes ≤ 2.2 · G2 ≤ 0.6 × old wall · G3 ≤ 1.37 GB, ≤ 10 min · G4 min ≥ 85.0,
≤ 3.10 GB · G5 Website ≥ 70, ≤ 165 MB, ≤ 2.5 min alone; Social ≥ 85, ≤ 165 MB · G6 535/535 byte-exact, ≤ 8.60 GB,
≤ 6 min alone · G7 ≤ 14 min, estimates ±15 %, peak RSS ≤ 8 GB · G8 resume byte-identical, no `.tmp`.

## Results

**2026-10-15, branch `int-engine`** (commits 2e4c7e0 / 398cda1), release `hmb`, MacBookPro18,4 (M1 Max, 10 cores,
64 GB). The machine was **never quiet**: Lightroom ran throughout and other engineers were building (1-minute load 7.7
to 48 during the runs), so every timing gate is `not-evaluated` and the times below are upper bounds. Bytes, scores,
probes and estimate errors do not depend on load (outputs are deterministic). Reports and outputs:
`~/Library/Application Support/holdmybyte-dev/runs/` (never inside a source folder).

| Gate | Result | Machine state | Report |
|---|---|---|---|
| G1 | **pass** — 50,239,686 bytes ≤ 50,301,670 (old engine held to the v2 floor, D-ENG-1); 19/19 ≥ 74; probes 1.95 mean, max 3; two repeats byte-identical | load 16.1 → 38.0, Lightroom running | `runs/20261015-212903-holdout` |
| G2 | not evaluated (load). Same session, alternating: holdmybyte 13.0 s / 16.6 s, old `squeeze -p classic` 53.4 s / 63.9 s (ratio 0.24 / 0.26; gate ≤ 0.6) | load 16.1 → 38.0 | same |
| G3 | bytes **pass** — 1,352,439,246 bytes ≤ 1.37 GB; 535/535 ≥ 74 (min 74.00, median 74.11, max 75.29), 0 kept original, 0 failed; probes 1.96 mean (1: 100, 2: 356, 3: 79); timing not evaluated: **375.1 s** (0.70 s/photo, 1.93 CPU-s/photo; gate 600 s; old 1044 s); peak RSS 5.73 GB | load 29.1 → 9.0, thermal nominal, Lightroom running | `runs/20261015-211016-wedding-couple` |
| G4 | not run | | |
| G5 | **fail on bytes** — Website 172.3 MB (> 165), min 70.00, probes 2.87; Social 183.7 MB (> 165), min 85.00, probes 3.56, 171/535 at 4:4:4. Image data alone: 152.0 MB and 154.4 MB (see below) | load 7.7 → 35.5, thermal fair | `runs/20261015-211705-wedding-all` |
| G6 | bytes **pass** — 8.559 GB ≤ 8.60 GB, 535/535 byte-exact; time alone not run | same | same |
| G7 | **fail on memory** — peak RSS **18.36 GB** (gate 8 GB); estimates **pass**: couple −3.1 %, website +2.0 %, social −0.3 %, archive +0.2 % (estimate 4.09 s); wall 613.1 s not evaluated (gate 840 s; old 2370 s in four runs) | same | same |
| G8 | not run | | |
| G9 | **pass** — `shasum -a 256` of all 535 sources before the first and after the last run: identical; no file added to the source folder | 21:32 | `runs/wedding-sha256-{before,after}.txt` |

**Couple's Package against the baselines (535 photos, 10.95 GB):**

| | Bytes | vs old engine | Floor (as measured) | Metadata kept | Wall |
|---|---|---|---|---|---|
| holdmybyte v2 | **1.352 GB** (image data 1.324 GB) | +0.2 % (image data −1.1 %, old metadata ≈ 11 MB) | ≥ 74.0 on v2's ImageIO reading | EXIF, XMP, IPTC, ICC (28.1 MB) | 375 s at load 29 → 9 |
| old engine (Classic) | 1.35 GB (DATENLAGE §8; §1b measured 1.37 GB) | — | ≥ 74.0 on libjpeg-turbo; reads 0.29 lower on v2 (5/19 holdout outputs < 74) | EXIF, ICC | 1044 s (17.4 min) |
| old engine held to the v2 floor | ≈ 1.364 GB (holdout +1.0 %, extrapolated — not run on the wedding) | | ≥ 74.0 on v2 | EXIF, ICC | |
| JPEGmini Pro 5 | 5.36 GB | ×3.96 | 75.0 min (DATENLAGE) | | 226 s |

At the same verified quality as v2 measures it, v2 is about 0.8 % smaller than the old engine on the wedding
(extrapolated from the holdout, where it is measured: 50.24 vs 50.30 MB) while keeping 17 MB more metadata. "High
full-size, 85" (old 3.05 GB) was not run.

**All four deliveries in one run** (couple, website, social, archive): 613.1 s wall (1.15 s/photo, 6.43 CPU-s/photo),
10.27 GB written in total; old engine 39.5 min in four separate runs, 10.21 GB. Couple's bytes are identical to the
Couple-only run (determinism across delivery sets).

**G5 analysis.** Website and Social keep EXIF (with its thumbnail), XMP, IPTC and the sRGB ICC under the built-in
`removeLocation` policy (SPEC §1.4/§3.7); the old engine stripped EXIF entirely for both. Measured in the outputs:
Website 20.3 MB of metadata (38 KB per file), Social 29.3 MB (55 KB). Image data alone is 152.0 MB (old 159 MB) and
154.4 MB (old 155 MB). The gate as written compares unequal content; whether Website/Social should drop the EXIF
thumbnail or IPTC is a product decision for the owner, not an engine change. Website also overshoots by 0.65 on
average (DirectSearch accepts s − T < 1.0, WebP q is an integer).

**G7 memory analysis.** Peak RSS comes from the archive: `hmb compress` of the 19 holdout photos with Archive only
peaks at **12.5 GB** (11.3 GB footprint, 8 workers, load 18), Couple only at 4.9 GB. One libjxl lossless JPEG
transcode of a 45 MP photo at effort 7 holds about 1.4 GB, and with 8 workers 8 transcodes can coincide. Not fixed in
this pass: a transcode gate (at most 3–4 concurrent) trades against G6's 6-minute budget and needs a quiet-machine
measurement; recorded as an open item for the lead.

**Holdout before/after this pass** (Couple's Package, 19 photos, target 74 for all):

| | Bytes | Probes mean / max | Overshoot mean / max | Below target |
|---|---|---|---|---|
| WP2 engine (`.proxyCurve`, §3.4 constants) | 51.38 MB | 2.53 / 3 | 0.54 / 2.54 | 0 |
| this pass (`.mosaicExact`, D-ENG-3) | **50.24 MB** | **1.95 / 3** | **0.14 / 0.65** | 0 |
| G1 basis: old engine held to the v2 floor | 50.30 MB | (old: 3.79) | | 0 |
| old engine as delivered (Classic) | 49.81 MB | 3.79 | | 5 of 19 on v2's reading |

**Plumbing check, 2026-10-15** (load 9.17 / 15.89 / 18.62, Lightroom state not recorded): the old engine,
`squeeze -p classic`, on 2 holdout photos: 2.15 s wall, 1.80 s user, peak RSS 2.39 GB; outputs byte-identical to the
baseline (1,940,281 and 2,002,271 bytes, scores 74.1 and 74.8). `OldEngineLiveTests` repeats this on one photo.
