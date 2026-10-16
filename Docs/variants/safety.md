# Variant "safety": decoder-robust floors and a reproducible codec lock

Branch `eng-safety` (worktree `hmb-eng-safety`), base `main` at 66e3db0 (eng-v3 merged). 2026-10-16, MacBookPro18,4
(M1 Max, 10 cores, 64 GB), shared with other agents and never quiet: every timing carries its load and is an upper
bound. Quality is always v2's metric (Metal SSIMULACRA2) on the delivered bytes; no floor and no metric was changed.
Decision record: Docs/DECISIONS.md D-ENG-12. Raw logs, JSON and hashes:
`~/Library/Application Support/holdmybyte-dev/runs/safety-audit/` (outputs deleted after hashing and scoring).

## 1. Question

Since eng-v3 the floors are met with almost no margin (Social median 85.02, lowest wedding Couple margin +0.0002),
and the margin is measured on Apple ImageIO's decode (SPEC E6). Browsers decode JPEG with libjpeg-turbo, WebP with
libwebp. Does any delivered file fall below its target when a common viewer decodes it?

## 2. Method

`DecoderAuditTests` (opt-in, test-only tools, nothing vendored) re-scores every delivered lossy file of a
`hmb compress` run against the engine's own reference pipeline (decode → sRGB if converted → resize) with:

| Decoder | Who uses it | Tool |
|---|---|---|
| ImageIO | Safari, Preview, Photos, Finder; **the engine** | in process |
| libjpeg-turbo default (ISLOW IDCT, fancy upsampling) | Chrome, Firefox, Edge, most libjpeg-based software | `djpeg` 3.2.0; in process `IslowDecoder` (identical pixels, below) |
| libjpeg-turbo `-dct float`, `-dct fast`, `-nosmooth` | rare: speed or memory modes | `djpeg` |
| libwebp default (fancy upsampling) / `-nofancy` | Chrome, Firefox / rare | `dwebp` 1.x |
| ffmpeg's own mjpeg/webp decoders + swscale default | video tools, not image viewers | `ffmpeg` |

Lightroom and Windows (WIC) decoders are closed and were not measured.

Three pairings per file: **engine** (ImageIO source / ImageIO candidate, reproduces the journaled score), **mixed**
(engine reference / candidate decoded by X: what viewer X shows against the reference the engine certified) and
**same** (source and candidate both decoded by X). The **floor** column scores the *original* decoded by X against
the engine reference: it is what the decoder change alone costs before any compression.

## 3. Results on main (eng-v3), holdout, all lossy deliveries (19 × 3)

Margins are score − target; "gap" is X − ImageIO on the same candidate.

| Delivery | Decoder | mixed min / median | below (mixed) | gap min / median / max | same min | below (same) | floor min |
|---|---|---|---|---|---|---|---|
| Couple (4:2:0, 45 MP) | ImageIO (engine) | +0.020 / +0.090 | 0 | — | — | — | 100 |
| | libjpeg-turbo | **+0.134** / +0.295 | **0** | **+0.020** / +0.180 / +0.479 | +0.017 | 0 | 93.03 |
| | libjpeg-turbo float | +0.126 / +0.294 | 0 | +0.023 / +0.173 / +0.484 | +0.022 | 0 | 93.17 |
| | libjpeg-turbo `-nosmooth` | −0.007 / +0.082 | 2 | −0.062 / −0.017 / +0.066 | −0.149 | 9 | 93.03 |
| | libjpeg-turbo IFAST | −0.081 / +0.071 | 5 | −0.247 / −0.031 / +0.329 | −2.912 | 19 | 87.36 |
| | ffmpeg | −1.255 / −0.107 | 16 | −1.448 / −0.224 / −0.080 | −1.644 | 19 | 92.33 |
| Website (WebP 2560) | ImageIO (engine) | +0.034 / +0.672 | 0 | — | — | — | 100 |
| | libwebp | **+0.034** / +0.672 | **0** | **0 (identical pixels)** | −0.283 | 6 | 93.98 (turbo source) |
| | libwebp `-nofancy` | −3.095 / −0.355 | 13 | −3.146 / −0.825 / −0.490 | −3.072 | 18 | |
| | ffmpeg | −60.0 / −1.99 | 19 | | | | |
| Social (4:4:4, 1440) | ImageIO (engine) | +0.002 / +0.024 | 0 | — | — | — | 100 |
| | libjpeg-turbo | **−0.153** / +0.042 | **2** | **−0.155** / +0.015 / +0.273 | −0.084 | 4 | 94.67 |
| | libjpeg-turbo float | −0.152 / +0.039 | 2 | −0.154 / +0.016 / +0.274 | −0.068 | 4 | 94.70 |
| | libjpeg-turbo `-nosmooth` | = libjpeg-turbo (no chroma upsampling at 4:4:4) | 2 | | | 4 | |
| | libjpeg-turbo IFAST | −0.426 / −0.166 | 18 | −0.431 / −0.222 / +0.025 | −1.484 | 19 | 92.49 |
| | ffmpeg | −0.030 / +0.077 | 3 | −0.125 / +0.058 / +0.323 | −0.318 | 13 | 94.42 |

Wedding, 535 photos, main, libjpeg-turbo (in process, mixed pairing):

| Delivery | ImageIO min margin | libjpeg-turbo min / median margin | below | gap min / median / max | same min / below |
|---|---|---|---|---|---|
| Couple (4:2:0) | +0.0002 | TBD-WC | TBD | TBD | TBD |
| Social (4:4:4) | +0.0000 | TBD-WS | TBD | TBD | TBD |

Readings:
1. **Couple (jpegli 4:2:0, progressive): ImageIO is the lowest common reading.** libjpeg-turbo (ISLOW or float)
   reads every file higher (gap ≥ +0.020 on the holdout, TBD on the wedding); D-ENG-2's assumption holds here.
2. **Website: ImageIO's WebP pixels are libwebp's** (bit-identical on 19/19), so browsers see exactly the scored
   pixels.
3. **Social (4:4:4 since D-ENG-11): ImageIO is not the lowest reading.** libjpeg-turbo reads 2 of 19 holdout files
   below 85 (−0.153) and TBD of 535 wedding files. D-ENG-2's "ImageIO reads lowest" was measured on 4:2:0 and does
   not carry over to 4:4:4 (research F4 warned about this). This is the one real gap.
4. Decoders that trade accuracy for speed (IFAST, box upsampling of chroma, ffmpeg's swscale default) read the
   *original itself* 2–13 points below the reference (floor 87–94); no delivery can be certified against them and the
   engine does not try. ffmpeg's WebP decoder failed on one file (−60).
5. The **same** pairing is not a better yardstick: decoding the original with libjpeg-turbo instead of ImageIO already
   costs 4–7 points (floor 93–96), because ImageIO's baseline 4:4:4 path (the Lightroom originals) differs from
   libjpeg-turbo's. A delivery certified against ImageIO's original then reads up to 0.3 lower against
   libjpeg-turbo's original (Website, Social), which says more about the two decodes of the original than about the
   compression.

## 4. `IslowDecoder`: libjpeg-turbo's pixels in process

To score with a second decoder in the product without vendoring libjpeg-turbo (E6 rejected it for the symbol clash),
`hmb_jpeg_decode_islow` reads the quantised coefficients with jpegli (`jpegli_read_coefficients`) and reimplements
what libjpeg-turbo does after entropy decoding: jpeg-6b's integer ISLOW IDCT with its 1024-entry range-limit table,
h2v2 "fancy" upsampling with libjpeg's context rows (top and bottom rows duplicated; box upsampling when the chroma
plane is ≤ 2 samples wide, as `jdsample.c` does) and the fixed-point `jdcolor.c` YCbCr → RGB tables. Supported:
8-bit YCbCr 4:4:4 and 4:2:0 (every jpegli output); anything else returns "unsupported" and the ImageIO score stands.

`IslowDecodeTests` (needs `djpeg`): **pixel-identical to djpeg** on 504 synthetic jpegli encodes (7 sizes from 1 × 1 to
321 × 239, 4 patterns, 4:2:0 / 4:4:4, the three tunings, d 0.5 / 2 / 9), on the 6 Lightroom sample originals (baseline
4:4:4, 45 MP) and on their 4:2:0 and 4:4:4 full-size jpegli encodes. Time, 45 MP, one thread: 0.34–0.44 s (4:2:0),
0.51–0.66 s (4:4:4); a 1440 px Social file ≈ 0.02 s. Memory: coefficient planes and one byte per sample per
component, from the codec arena (returned when the call ends).

## 5. The decoder guard

`SearchConstants.decoderGuard` (`DecoderGuard`, `hmb`: `HMB_DECODER_GUARD=off|chroma444|all`):

- A JPEG candidate whose ImageIO score reaches the target, and whose layout the mode covers, is decoded again with
  `IslowDecoder` and scored against the same reference; the lower score is the candidate's score — for the search
  (secant, bias, stop rule), the zeroing post-pass, the journal and the receipt. Failing candidates are not decoded
  twice (the minimum cannot pass either). The ImageIO candidate is released before the second decode, and the second
  decode takes the same decode slot.
- `.chroma444` (**default**) covers 4:4:4 JPEGs: Social, 4:4:4 fail-open at full size, WebP→JPEG fallbacks at 4:4:4.
  `.all` adds 4:2:0. `.off` is eng-v3.
- The estimator's DirectSearch uses the same rule.

| Holdout, release, lossy three, back to back | Couple | Website | Social | Social min / median | wall | CPU | load |
|---|---|---|---|---|---|---|---|
| main 66e3db0 | 48,365,625 | 5,555,974 | 5,319,707 | 85.0018 / 85.0242 | 12.86 s | 67.9 s | 5.6 → 6.2 |
| guard `.chroma444` (default) | = (SHA-256) | = (SHA-256) | **5,319,392 (−0.006 %)** | 85.0047 / 85.0242 | 13.84 s | 69.6 s | 6.2 → 7.0 |
| guard `.all` | = | = | = `.chroma444` (SHA-256) | | 15.12 s | 80.2 s | 7.0 → 8.5 |
| guard `.off` | = main, 57/57 SHA-256 | | | | 12.63 s | 67.0 s | 8.5 → 9.2 |
| TBD second pair | | | | | | | |

TBD spans.

Wedding (535 × 45 MP, Couple + Social, back to back, load 9 → 28 → 63 from other agents):

| | Couple | Social | Social min / median | probes S | wall | CPU |
|---|---|---|---|---|---|---|
| main | 1,304,140,132 | 143,125,766 | 85.0000 / 85.0255 | 7.03 | 286.6 s | 1442.8 s |
| guard (default) | = (535/535 SHA-256) | **143,214,139 (+0.062 %)**, 183 files changed | 85.0000 / 85.0251 | 7.04 | 253.4 s | 1379.4 s |

The wedding pair ran under load 25–63 (other agents), so its times say nothing; CPU is within noise. Audit of the
guarded Social files (libjpeg-turbo, mixed): **535/535 ≥ 85, min +0.001** (main: TBD below). Holdout: 19/19, min
+0.008 (main: 2 below, min −0.153). Same pairing after the guard: 3/19 holdout and 104/535 wedding files below 85 by
at most 0.05 / 0.33 (source-decode effect, §3 reading 5).

**Why a second decoder and not a guard band.** A band must cover the worst gap seen (Social −0.155 holdout, TBD
wedding) and still is no guarantee for the next photo; at Social's slope (D-ENG-8: 0.20 points of overshoot = 2.3 %
of the bytes) +0.16…+0.2 costs about 2 % of Social's bytes on every file, against +0.06 % (wedding) for the guard,
which only moves the files that need it.

**Why `.chroma444` and not `.all`.** `.all` decodes every passing 4:2:0 full-size probe a second time (0.35–0.45 s per
45 MP decode + one score) and changed no byte on the holdout or the wedding: libjpeg-turbo reads every jpegli 4:2:0
file higher than ImageIO (gap ≥ +0.020 on 19, TBD on 535). It costs +15 % CPU on the holdout's three-delivery job.
It stays available for audits and for an owner who wants the guarantee by construction everywhere.

## 6. Codec lock reproducibility

**Cause.** `libtool -static` copies each member's owner into the ar header: the build user's uid, the build
directory's group (BSD semantics: new files take their directory's group, so `/tmp` gives `wheel` (0) and a home
folder `staff` (20)) and the umask's mode. The members themselves were identical, but the archive's SHA-256 was not,
and `Scripts/build-codecs.sh` silently rewrote `Vendor/codecs.lock` (eng-v3 verification §5).

**Fix.** After `libtool` (with `ZERO_AR_DATE=1` as before) every member header is rewritten to date 0, uid 0, gid 0,
mode 100644 (perl, in place; names and sizes untouched, so the `__.SYMDEF` offsets stay valid). The script compares
the built archive with `OUTPUT_SHA256` **before installing anything** and fails on a mismatch; `--update-lock` is the
only way to install a different archive and rewrite the lock. A build path with spaces now fails early with a clear
message (CMake splits `-ffile-prefix-map=<path>` at spaces; it failed late before).

**Proof** (fresh `git clone` of this branch per directory, libjxl/libwebp sources copied from the main checkout's
work tree, full CMake build each time; logs `safety-audit/codecA-*.log`, `codecB.log`):

| Build | Directory group | umask | libtool's raw archive | After normalising | Result |
|---|---|---|---|---|---|
| A, old lock 3e81407d | `wheel` (scratch under `/private/tmp`) | 022 | `4b68dbe5…` | `6e8cf4a9…` | **fails**, nothing installed (exit 1) |
| A, `--update-lock` | `wheel` | 022 | | `6e8cf4a9…` | installs, lock 3e81407d → 6e8cf4a9 |
| A, again | | | | | "up to date", exit 0 |
| B, new lock | `staff` (`runs/`, via a symlink without spaces) | 077 | `13f2f46a…` | **`6e8cf4a9…`** | installs, lock unchanged, exit 0 |
| main's 3e81407d archive, normalised | `staff` | 022 | `3e81407d…` | **`6e8cf4a9…`** | same members as the old pin |

The raw archives of A and B differ in 1,284 bytes, all in ar header uid/gid/mode fields. Linking against the
normalised archive gives the same `hmb` outputs (holdout 57/57 SHA-256 with the guard off = main).
