# WP0 notes: deviations, additions and hand-over

WP0 (scaffold and shared types) as specified in `Docs/SPEC.md` §5.0. This file records every place where the code
differs from the spec text, every addition beyond it, and what WP1–WP5 need to know.

## Deviations from the verbatim text

| # | Where | Spec | Code | Why |
|---|---|---|---|---|
| D1 | `Sources/HMBEngine/Interfaces/Primitives.swift` | declares `public enum ChromaSubsampling` (same cases as HMBModel's) | not redeclared; `HMBModel.ChromaSubsampling` is used | Two public types of the same name: every module importing both `HMBEngine` and `HMBModel` (app, `hmb`, tests) would get "ambiguous type" errors, and `PhotoResult.chroma` (HMBModel) would need conversions from the engine's type. §5.1 already says WP1 consumes `ChromaSubsampling` from HMBModel. |
| D2 | `Sources/CHMBCodecs/include/hmb_codecs.h` | bare declarations | adds an include guard and `extern "C"` guards | The implementations are `.cc` files: without `extern "C"` the symbols get C++ mangling and Swift (which imports the header as C) cannot link them. Declarations are unchanged. |
| D3 | `Primitives.swift`: `EnginePrimitives` | `live()` / `fakes()` shown inside the struct without bodies | `live()` lives in `Primitives+Live.swift` (WP1), `fakes()` in `Primitives+Fakes.swift` (WP0), both as `extension EnginePrimitives` | Bodiless functions inside a struct do not compile; this is the split §5.0 item 6 describes. |
| D4 | `Primitives.swift`: `PixelImage` | `init` and `deinit` without bodies | implemented (64-byte aligned, zero-filled, `bytesPerRow = width*4` rounded up to 64; `precondition(width > 0 && height > 0)`) | needed to compile |
| D5 | `Scripts/build-codecs.sh` | outline | additionally: `cmake --build … --target jpegli-static` | upstream marks `jpegli-static` `EXCLUDE_FROM_ALL`; the default build target does not build it |
| D6 | `Scripts/build-codecs.sh` | outline | adds `-ffile-prefix-map=$WORK=/hmb-codecs` to C/C++ flags, `ZERO_AR_DATE=1` | reproducible archive (same SHA-256 from any checkout path; no home-folder paths in the binary) |
| D7 | `Scripts/build-codecs.sh` audits | `nm -gU … \| grep -E ' _jpeg_'` | symbol table written to a file first, then grepped; also requires `jpegli_CreateCompress`, `jpegli_set_distance`, `JxlEncoderCreate`, `JxlDecoderCreate`, `JxlThreadParallelRunner`, `WebPEncode`, `WebPNewInternal` (`WebPMuxNew` is an inline wrapper), `SharpYuvConvert` | `nm \| grep -q` SIGPIPEs `nm` under `pipefail` |
| D8 | `AppModel.swift` | `public var showsTransientStatusItem: Bool { get set }` | stub uses a stored property (`= false`) | stub; WP3 may make it computed |
| D9 | `LiveEngine` | `init(primitives: EnginePrimitives = try .live(), supportDirectory:)` | stub has `init(primitives:supportDirectory:)` plus `convenience init(supportDirectory:) throws` (uses `.live()`) | a default argument cannot `try`; WP2 owns the file and may choose otherwise |

## Decisions where the spec leaves room (WP0-owned bodies)

- **`DeliveryPreset.specLine`:** a built-in returns its fixed §2.6 line only while `format`, `size`, `quality`,
  `colour` and `metadata` equal the shipped definition (renaming does not matter). An *edited* built-in describes
  itself with the custom rule, so the Setup row never lies.
- **`validationError`:** rules are checked in the order listed; the first violation wins. A `.longEdge` outside
  400…12000 fails, `.full` never does.
- **`WeddingNaming.suggestedName`:** with several folders, uses their deepest common ancestor. Generic names walk up
  repeatedly (`…/Anna und Ben/Export/JPG` → "Anna und Ben"), stopping at `/` or `/Volumes`. Fallback when nothing is
  usable: **"Untitled Wedding"**. `slug` collapses whitespace runs to one "-".
- **`DeliverySummary.make`:** only results with `delivery == preset.id` for photos in `photos` count; the last result
  per photo wins (a retry replaces a failure); `total = photos.count`; the median of an even count is the mean of
  the two middle values; `targetRange` only for Balanced; a delivered result without `outBytes` counts as 0.
- **`WeddingRecord.savedBytesFullSize`:** Σ over full-size deliveries of (Σ inBytes − Σ outBytes) over *delivered*
  photos (done + kept original).
- **`HMBFormat`:**
  - `bytes`: `ByteCountFormatStyle(style: .file, spellsOutZero: false)` → "0 bytes", never "Zero kB".
  - `savedPercent`: rounded to whole percent, U+2212 for savings, "+5 %" for growth, "0 %" at zero; spacing from the
    locale (en_DE/de_DE use a no-break space U+00A0: "−88 %").
  - `statusLine`: precedence finishing → nothing done → < 10 done or no ETA → < 60 s → ≤ 60 min → hours; minutes
    are rounded. **Addition:** an overload `statusLine(…, locale:)`; the verbatim signature uses `Locale.current`.
    The snapshot harness should call the locale overload with `HMB_SNAPSHOT_LOCALE` so counts read "1.800" in en_DE.
  - `duration`: "4 min" on the minute, "2 h" on the hour, seconds dropped from 1 h.
  - `folderName`: `{date}` = ISO `2026-07-12`, `{year}` = `2026` (current time zone); without a date the tokens and
    dangling separators are dropped; `/` and `:` become `-`.
  - `fileName`: `{wedding}` is slugged; `{number}` is zero-padded to max(4, digits of `count`).

## Additions (public API beyond the spec)

- `HMBModel`: `HMBFormat.statusLine(done:total:etaSeconds:finishing:locale:)`.
- `HMBEngine`: `EnginePrimitives.init(decoder:processing:jpeg:webp:jxl:metric:)` (public memberwise, so tests and the
  bench can mix fakes and live parts); `PrimitiveError` (message error for primitives);
  `EnginePrimitives.codecVersions` (`hmb_codec_versions()` as a String, in `Interfaces/CodecVersions.swift`); the
  public fake types `FakeDecoder`, `FakeProcessing`, `FakeJPEGEncoder`, `FakeWebPEncoder`, `FakeWebPPrepared`,
  `FakeJXLTranscoder`, `FakeMetric`, `FakeMetricReference`, `FakeCodecContainer`.
- `HMBUI`: `Tokens` (palette, spacing, radii, layout sizes, typography, motion), `View.hmbAccent()` (root tint rule),
  `View.hmbGlassButtonStyle(prominent:)` (`.glass`/`.glassProminent`, falling back to `.bordered`/`.borderedProminent`
  while snapshot rendering — the harness cannot render glass buttons either), `EnvironmentValues.isSnapshotRendering`
  (`@Entry`, default false; SwiftUI has no such value, so WP0 defines it).
- `HMBFixtures`: `FixtureFactory` (deterministic building blocks), `FixtureRandom`, `Fixtures.inProgress(_:done:…)`,
  `Fixtures.failed(_:reason:)`, `Fixtures.only(_:of:)`, `Fixtures.historySavedBytes`, `TestFixtureFiles` (paths of
  `Tests/Fixtures/*`, located via `#filePath` since v1 has no SwiftPM resources).

## Placeholders outside the §5.0 stub list

SwiftPM requires at least one source file per target, so WP0 also created:
- `Sources/HMBStore/HMBStore.swift` (`public enum HMBStore {}`) — WP4 deletes or replaces it.
- `Sources/HMBBench/HMBBench.swift` (`public enum HMBBench {}`) — WP5.
- `Tests/HMBBenchTests/Scaffold/ScaffoldTests.swift` — WP5 may delete it once it has tests.
- `Tests/HMBStoreTests/Scaffold/InMemoryStoreTests.swift` — tests HMBFixtures' in-memory stores; WP0-owned.
- `Tests/HMBEngineTests/Interfaces/FakePrimitivesTests.swift` — tests the fakes and the codec link; WP0-owned.
- `Tests/HMBUITests/Fixtures/FixturesTests.swift`, `Tests/HMBUITests/Design/ScaffoldUITests.swift` — WP0-owned.
- `Sources/CHMBCodecs/stub_error.h` — private helper of the WP0 `.cc` stubs; WP1 deletes it with the stubs.

## Hand-over

### Everyone
- Build: `Scripts/build-codecs.sh && swift build && swift test`. In a worktree: `Scripts/link-codecs.sh ~/Desktop/holdmybyte`.
- Local data was copied to `~/Library/Application Support/holdmybyte-dev/data/` (`sample/` 6 photos,
  `holdout/` 19, `old-holdout/` 19 plus `old-holdout-{own,ref}scores.txt` and `old-holdout.log`).
  `source "$HOME/Library/Application Support/holdmybyte-dev/env.sh"` exports the §5.6 variables. The old-holdout
  folder is `$HMB_HOLDOUT/../old-holdout`.
- Tests use swift-testing (`import Testing`).
- `Tests/Fixtures/` holds synthetic images only: `gradient-srgb.jpg`, `ramps-p3.jpg` (Display P3 ICC), `pattern.png`,
  `orientation-6.jpg` (640×427 stored, EXIF orientation 6), `cmyk.jpg`, `arithmetic.jpg` (SOF9),
  `holdmybyte-output.jpg` (COM "holdmybyte v2 · test fixture"), `mosaic-2400x1600.jpg`. None carries an EXIF Make.

### WP1
- The CHMBCodecs `.cc` files are stubs returning −1 with a message, except `hmb_buffer_free` (real) and
  `hmb_codec_versions` (real: reads `JxlEncoderVersion()` and `WebPGetEncoderVersion()`, so the archive is linked
  and checked by `FakePrimitivesTests.codecArchiveIsLinked`).
- Include paths inside `.cc`: `"lib/jpegli/encode.h"` (needs `lib/jxl/base/include_jpeglib.h` → `<jpeglib.h>`,
  both copied), `<jxl/encode.h>`, `<jxl/decode.h>`, `<jxl/thread_parallel_runner.h>`, `<webp/encode.h>`,
  `<webp/mux.h>`. The jpegli stub already compiles against them. `jpeglib.h` is libjxl's copy configured for
  `JPEG_LIB_VERSION 62`.
- The archive contains libjxl, libjxl_cms (with skcms), libjxl_threads, libjpegli-static, libhwy, brotli
  (common/dec/enc), libwebp, libsharpyuv, libwebpmux. `libwebpdemux` and `libwebpdecoder` are not included
  (decoding goes through ImageIO, E6); add to `Scripts/codec-libs.txt` via the lead if needed.

### WP2
- Develop against `EnginePrimitives.fakes()`: JPEG step = round(distance × 4), WebP step = round((100 − q)/8), both
  at least 1; output size is non-increasing in the step; fake 4:4:4 is `width×height/16` bytes larger; metric =
  100 − 2.5 × RMSE (R, G, B); JXL = "HMBX" + JPEG. `FakeDecoder.inspect` parses real JPEG markers (EXIF, XMP, ICC,
  COM, DQT quality, CMYK, SOF9+) so scanner tests can use the synthetic fixtures.

### WP3 / WP4 / WP5
- `AppModel` stubs have empty bodies; `init` has no side effects. Views: `RootView`, `StatusMenu`, `CompareView`,
  `SettingsView` take `model:`.
- Fixtures: `Fixtures.finnUndLissy` (finished, 4 deliveries), `.annaUndBen` (queued), `.history` (38 incl. Finn und
  Lissy, newest first, 1.24 TB), `.scanResult`, `.estimates`, `.withIssues(_:)`, `.keptOriginal(_:)`,
  `.inProgress(_:done:inFlight:phase:)` (record + `JobProgress` for running/paused/stopped/interrupted states),
  `.failed(_:reason:)`, `.only(_:of:)` (e.g. a single-delivery Done view). Paths are under `/Users/sebastian/Weddings`.
- `FixtureEngine(.init(…))` scripts scans, estimates, preflight notices, replay speed, per-photo failures, a pause
  point (e.g. drive disconnected after N photos), job failure, unfinished jobs and an unavailable compare original.
- `FixtureThumbnails()` uses `HMB_FIXTURE_PHOTOS` if set; `FixtureThumbnails(photoFolder: nil)` is always synthetic.
- Set `\.isSnapshotRendering = true` in the harness; use `.hmbGlass` / `.hmbGlassButtonStyle` for every glass surface.
