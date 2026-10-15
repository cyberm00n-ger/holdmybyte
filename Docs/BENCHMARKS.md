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

**Gates** (§6.2): G1 ≤ 50.31 MB, mean probes ≤ 2.2 · G2 ≤ 0.6 × old wall · G3 ≤ 1.37 GB, ≤ 10 min · G4 min ≥ 85.0,
≤ 3.10 GB · G5 Website ≥ 70, ≤ 165 MB, ≤ 2.5 min alone; Social ≥ 85, ≤ 165 MB · G6 535/535 byte-exact, ≤ 8.60 GB,
≤ 6 min alone · G7 ≤ 14 min, estimates ±15 %, peak RSS ≤ 8 GB · G8 resume byte-identical, no `.tmp`.

## Results

_Pending: the gates run on `main` after WP1 (primitives) and WP2 (LiveEngine) are merged; on the WP5 branch
`LiveEngine` is still the WP0 stub, so `hmb bench` stops at the scan._

| Gate | Result | Machine state | Report |
|---|---|---|---|
| G1 | – | – | – |
| G2 | – | – | – |
| G3 | – | – | – |
| G4 | – | – | – |
| G5 | – | – | – |
| G6 | – | – | – |
| G7 | – | – | – |
| G8 | – | – | – |
| G9 | – (manual: `shasum -a 256` manifest of the 535 sources before G3 and after G8) | | |

**Plumbing check, 2026-10-15** (load 9.17 / 15.89 / 18.62, Lightroom state not recorded): the old engine,
`squeeze -p classic`, on 2 holdout photos: 2.15 s wall, 1.80 s user, peak RSS 2.39 GB; outputs byte-identical to the
baseline (1,940,281 and 2,002,271 bytes, scores 74.1 and 74.8). `OldEngineLiveTests` repeats this on one photo.
