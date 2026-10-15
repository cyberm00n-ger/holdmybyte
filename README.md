# holdmybyte

A macOS app that shrinks a wedding photographer's finished JPEGs as far as they go **without visible loss** —
every delivered photo is verified against its original with a perceptual metric (SSIMULACRA2) — and produces the
usual deliveries in one pass: the couple's full-size package (JPEG), a website set (WebP), social/blog images
(JPEG) and a byte-exact archive (lossless JPEG XL). Originals are never modified. Everything stays on the Mac.

The binding specification is [`Docs/SPEC.md`](Docs/SPEC.md).

## Requirements

- macOS 26 on Apple Silicon, Xcode 26 (Swift 6.2)
- For building the codecs once per machine: `git`, `cmake` and `ninja` (e.g. from Homebrew — used as build tools
  only; nothing from Homebrew is linked)

## Build

```bash
Scripts/build-codecs.sh     # once per machine: libjxl v0.11.2 (+ jpegli) and libwebp v1.6.0 from pinned sources
swift build
swift test
```

`Scripts/build-codecs.sh` clones the pinned tags (verified against the commits in `Vendor/codecs.lock`), builds them
as static libraries, merges them into `Vendor/xcframeworks/HMBCodecs.xcframework` and copies the headers listed in
`Scripts/codec-headers.txt` into `Sources/CHMBCodecs/vendor-include/`. Both outputs are git-ignored. The script
audits the archive (no exported `jpeg_*` symbols, no Homebrew paths) and is a no-op when the output already matches
`OUTPUT_SHA256` in the lock. In a git worktree, clone the main checkout's build instead of rebuilding:

```bash
Scripts/link-codecs.sh ~/Desktop/holdmybyte
```

`Scripts/check-repo.sh` is the repository hygiene gate (no client photos, nothing over 512 KB, no `unsafeFlags`).

## Layout

| Path | Contents |
|---|---|
| `Sources/HMBModel` | Shared value types, `EngineService`, store protocols, `HMBFormat` |
| `Sources/CHMBCodecs` | Plain C bridge (`hmb_codecs.h`) over jpegli, libwebp and libjxl |
| `Sources/HMBEngine` | Primitives (codecs, imaging, Metal metric), search, pipeline, jobs, `LiveEngine` |
| `Sources/HMBStore` | History JSON, presets, settings, thumbnail cache |
| `Sources/HMBFixtures` | Deterministic domain fixtures, `FixtureEngine`, in-memory stores, synthetic thumbnails |
| `Sources/HMBUI` | SwiftUI views, design tokens, `AppState` / `AppModel` |
| `Sources/HoldMyByteApp` | The app (`holdmybyte`) |
| `Sources/hmb` | The command-line tool (`hmb`) |
| `Sources/HMBSnapshot` | Offscreen snapshot harness (`hmb-snapshot`) |
| `Sources/HMBBench` | Benchmark runner and reports |
| `Tests/Fixtures` | Synthetic test images only (regenerate with `swift Tests/Fixtures/generate.swift`) |

## Local test data (never committed)

Tests and benchmarks that need real photos read them from folders named by environment variables
(`HMB_TEST_PHOTOS`, `HMB_HOLDOUT`, `HMB_WEDDING`, `HMB_OLD_ENGINE`, `HMB_FIXTURE_PHOTOS`; see `Docs/SPEC.md` §5.6).
Without them those tests are skipped. On the development Mac:

```bash
source "$HOME/Library/Application Support/holdmybyte-dev/env.sh"
```

## Benchmarks

_To be filled by WP5 (`Docs/BENCHMARKS.md`)._

## Licence

_To be decided._ Vendored codecs: libjxl (BSD-3-Clause), libwebp (BSD-3-Clause), Highway (Apache-2.0 / BSD-3-Clause),
Brotli (MIT), skcms (BSD-3-Clause).
