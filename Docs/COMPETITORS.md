# Competitors

Market survey and hands-on analysis for holdmybyte v2 (macOS, wedding and event photographers, 24–61 MP Lightroom
exports). Written 2026-10-16 on branch `eng-research`. Engine experiments and the ranked engine recommendations are in
[`variants/research.md`](variants/research.md); this file is the market picture and what JPEGmini actually does.

Sources are vendor pages and release notes fetched on 2026-10-16 (links at the end). Vendor claims are marked as
claims; numbers we measured are marked **[M]**, with the machine state in `variants/research.md`.

## 1. Summary

- **JPEGmini is the only direct competitor**: a local Mac/Windows app aimed at photographers that recompresses
  full-size JPEGs in place. Everything else is either a web optimiser (bandwidth-oriented, uploads, size limits,
  per-GB pricing), a lossless or fixed-quality desktop tool with no per-photo quality decision, or an encoder library.
- **What JPEGmini actually ships [M]** (27,200 JPEGmini outputs found on this Mac, 1,500 sampled; 20 resized exports
  with their originals): baseline JPEG, one scan, Huffman-optimised, **4:4:4 kept** (1,498 of 1,500), all metadata kept,
  a `COM` marker `Optimized by JPEGmini <version>`, and quantisation tables that are the standard Annex K tables times
  one per-photo factor (chroma matches exactly; luma within ±1 on about 18 of 64 entries). On 45 MP exports the
  factor sits at IJG quality 92–94 for 70 % of the photos. Its per-photo "intelligence" is one scalar,
  and it is set conservatively.
- **JPEGmini's bytes are beatable with a plain encoder [M]**: libjpeg-turbo, 4:4:4 baseline, Annex K tables scaled
  per photo to reach score ≥ 90 on every holdout photo, totals 176.3 MB against JPEGmini's 191.0 MB (whose files score
  79.1–91.5) and v2 Highest's 207.8 MB (`variants/research.md` F1). JPEGmini's real advantage is over the
  photographer's habit of exporting at Lightroom quality 100, not over a good encoder.
- **Even Apple's built-in encoder beats it [M]**: `sips`/Preview at quality 75 (also 4:4:4 baseline) gives 8.11 MB
  at score 90.73 on holdout 0014, where JPEGmini gave 9.55 MB at 90.73.
- **Scoring caveat [M]**: for JPEGmini-style files (4:4:4 baseline) the score moves by about 1.5 points depending on
  whether reference and candidate go through the same decoder path (research F4). The July JPEGmini scores were most
  likely taken with `squeeze score` (ImageIO on both sides), which reads such a file exactly as v2 does (90.13 on
  both for our test file), so they stand; every re-score must keep both sides on one decoder.
- **JPEGmini is moving toward our product shape**: v4.5 (June 2026) added watch folders, automatic
  optimise/resize/export and multi-size export into sub-folders, i.e. "deliveries". Price: $59 one-time (Pro),
  $89 with Lightroom/Photoshop/Capture One plugins, $99 with automations, $129 bundle; one year of updates.
- **Our moat is the measured floor, not the percentage**: on the 535-photo wedding JPEGmini's own output ranges from
  score 75.0 to 93.5 (median 89.9) while claiming "visually
  identical"; our High delivery (old engine) holds ≥ 85.0 on every file and is 43 % smaller. No competitor surveyed publishes a per-photo quality number at all.

## 2. JPEGmini (Beamr)

### 2.1 Product, price, claims

| | |
|---|---|
| Vendor | Beamr Imaging (Israel; also video: CABR/HEVC). JPEGmini since 2011. |
| Products | **JPEGmini Pro** desktop (Mac, Windows), **Pro + Plugins** (Lightroom Classic export plugin, Photoshop, Capture One), **Pro + Automations** (watch folders, background, batch presets), **Complete Bundle**; **JPEGmini Photo Server** (Linux CLI, annual licence, AWS Marketplace); "JPEGmini Cloud" promoted without price. Free tier: 7-day trial, then 50 images/day. |
| Price | $59 Pro · $89 Pro + Plugins · $99 Pro + Automations · $129 bundle (list $149). One-time, 3 devices, one year of updates included. |
| Claims | "up to 80 % smaller" photos (pricing page: "up to 70 % without quality loss"), panoramas up to 75 %, video up to 50 %; "visually identical"; ITU BT.500 subjective tests at 100 % zoom and 200 DPI print; "500,000 photographers"; 17 granted patents, 2 SPIE 2011 papers. |
| Formats | JPEG → JPEG, HEIC → JPEG, H.264/H.265 video (4K HEVC since 4.1.3, Aug 2024). Up to 512 MP since 4.2.3 (Nov 2025). No AVIF, WebP or JPEG XL output. |
| Releases | 4.0 (Oct 2023, UI) · 4.1.x (2024: 256 MP, HEVC) · 4.2.0 (May 2025, "faster batch processing") · 4.2.3 (Nov 2025, 512 MP) · **4.5.0 (Jun 2026): watch-folder automations, auto optimise/resize/export, multi-size export to sub-folders, background running** · 4.5.1 (Aug 2026). No release note mentions the compression engine since 2022. |
| UX | Drop photos or folders on a window; default mode overwrites originals after a "Files will be replaced" sheet (seen on this Mac); optional export to a folder with resize presets; a running "savings" counter. No preview of the quality decision, no per-photo score, no undo once replaced. |

**Installed copy on this Mac:** "JPEGmini Pro 5.app", bundle version 3.4.1 (build 40871, March 2022), automatic
updates off; outputs carry engine strings 3.18.8 (95 %), 3.18.4, 3.18.2 and 3.14.12. Every number in our July
benchmarks and in this file is from this 2022 build. **Before any public comparison, re-run the duel with the current
4.5.x release** (a licensed copy; the engine is probably unchanged, but that is an assumption).

### 2.2 How it works (patents + binary + outputs)

- **Metric** (SPIE 7867, 2011; US 8,908,984 and related; CVPR 2018 workshop paper): per-region PSNR, "added
  artifactual edges along coding block boundaries" (blockiness, the core), texture change and edge preservation,
  combined by a weighted geometric mean with a per-image configuration. Single-scale and block-grid-centred; no colour
  model, no published thresholds. This explains its spread on our metric (75–93.5 on one wedding): grain smoothing
  and in-block ringing create no new block edges, so its measure under-reacts to them.
- **Engine** (strings in the 2022 binary): an in-house transcoder `jmtrans` with modes `-enc`, `-dec` and `-trs`
  (transcode: reads the DCT coefficients, writes a new quantisation file, "do_quant_plane() Q Matrix"), options for
  quality level (`-qual=0` best [default], 1 high, 2 medium), `-shc=1` **skip highly compressed images [default]**,
  `-rmt` remove metadata (default off), `-prg` progressive only if the input was progressive (default), DCT-domain
  downscaling (`downscale_dct_dec`, "octv", "dctx2") and adaptive-quantisation flags (`gaq`, `nqm`, `stc`, `stp`,
  `ats`, `dsq`). Pixel paths use libjpeg-turbo 2.0.2 and ImageMagick. The app tracks `originalAlreadyProcessed`.
  The GUI shell has no scripting interface; the bundled `beamrtrans` binary is the video transcoder.
- **Outputs [M]** (1,500 of 27,200 JPEGmini files on this Mac, 148 folders, mostly 45 MP Z9 wedding exports; plus 20
  resized exports with originals in `~/Desktop/thefotoarchive`):

| Property | Finding |
|---|---|
| Container | `SOF0` baseline, 1 scan, 4 optimised DHT segments (`jpegtran -optimize` gains 0 bytes). `DRI` of the Lightroom source is dropped. |
| Chroma | 4:4:4 in 1,498 of 1,500; the other two are 4:2:0 (sources unknown). No sign of subsampling. |
| Metadata | EXIF, IPTC (APP13), ICC, XMP and APP14 kept byte-for-byte, in source order; `COM "Optimized by JPEGmini 3.18.8.213562496-A"` added; DQT moved after the COM. Median 47 KB metadata. |
| Tables | Annex K × one factor per photo. Chroma: exact match (64/64) in most files. Luma: median 46/64 exact, the rest ±1 (lowest AC terms often forced to 1 at high quality). Luma and chroma use the same factor. |
| Operating point, ≥ 30 MP (1,201 files) | IJG-equivalent quality: p5 76, p25 92, **median 93**, p75 94, p95 95. Q 92–94 = 70 % of files; 14 % below Q 85; tail down to 59. Bits per pixel median 1.74. |
| Operating point, 4000 px resized | Q 78–93, median 87 (finer content per pixel → lower Q). |
| Progressive | Never, for baseline sources. A lossless `jpegtran -progressive` repack of its output saves 1.0–2.0 % **[M]**. |
| Per-shoot spread | Q range within one folder (55 folders with ≥ 8 samples): median 18 points. |

The ±1 luma deviations and the forced-to-1 low frequencies are consistent with the patent claim element that forms
the new matrix as a weighted average of a scaled matrix and the original one (see the patent note in the owner's
records; flag to counsel, as before).

### 2.3 Quality and bytes on the 535-photo wedding (re-analysis of `jpegos/Benchmarks/data`)

| | |
|---|---|
| Saving | 30.9–83.4 % per file, median 49.8 %, total −50.0 % (10.95 → 5.36 GB) |
| Score (`squeeze score`, ImageIO both sides; ≈ v2 scale for these files) | min 75.0, p5 82.0, p25 88.4, median 89.9, p75 90.9, max 93.5; 42 files < 85, 17 < 80 |
| Coupling | corr(score, saving) = **−0.92**: the photos it squeezes most are the ones whose quality drops most |
| Speed | 226 s for 535 (0.42 s/photo wall, ~2.3 CPU-s/photo); v2 Couple's Package 1.93 CPU-s/photo **[M, 2026-10-15]** |
| Our engine matched to its score per file (old engine) | band < 85: 0.86 × its bytes · 85–88: 0.93 × · 88–90: 0.99 × · **90–92: 1.20 ×** · ≥ 92: 1.50 × |

The loss above 90 is mostly chroma: JPEGmini keeps 4:4:4, the old engine and v2 search 4:2:0 first. At score 90,
4:2:0 costs 40 % more bytes than 4:4:4 or cannot reach the target at all; jpegli's own 4:4:4 is also ~15 % larger
than standard tables at 90 (`variants/research.md` F1). Fixing it is engine recommendation 1.

### 2.4 Weak points to position against

1. **No measured floor.** "Visually identical" covers a 75–93.5 spread on one shoot; the worst files are the most
   compressed (corr −0.92). Photographers cannot see which ones.
2. **Overwrites originals by default** (one confirmation sheet, then irreversible).
3. **JPEG only, baseline only.** No JPEG XL archive, no AVIF/WebP web delivery, no lossless option; the 4:4:4
   baseline output itself leaves ~2 % (progressive repack) and ~23 % (JPEG XL lossless transcode) on the table.
4. **Already-JPEGmini'd libraries are everywhere** (27,200 files on this one Mac) and are marked with a `COM` string:
   a second lossy generation is a real risk for any optimiser, and an easy detection for us.
5. **Old engine.** No engine note since 2022; its development goes into automation and video.

## 3. Everyone else

| Product | What it does technically | Selling point / claims | UX | Speed | Price | Fit for 45 MP wedding delivery |
|---|---|---|---|---|---|---|
| **Squoosh** (Google Chrome Labs) | In-browser WASM codecs: MozJPEG, WebP, AVIF, JPEG XL, OxiPNG; resize; side-by-side slider | "Best-in-class codecs", local processing | One image at a time, manual quality slider | Per image, interactive; large images slow in WASM | Free, Apache-2.0 | No batch, no target, no metadata policy — a demo/teaching tool |
| **ImageOptim** (Mac) | Runs MozJPEG/jpegtran, pngquant, Zopfli, etc. and keeps the smallest; lossless by default, optional "lossy minification" at a fixed quality | Free, lossless, strips EXIF/GPS/thumbnails | Drag-and-drop, overwrites in place, CLI, Services | Fast lossless; PNG slow | Free (GPL) | Lossless saves a few %; strips metadata by default; lossy has no per-photo control |
| **TinyJPG / TinyPNG** (Tinify) | Server "smart lossy"; AVIF/WebP/JPEG/PNG (+JXL on web); resize/convert API | "up to 80 %"/"more than 85 %" smaller, no visible loss | Web drop (20 images, 5 MB each free), API, WordPress/Figma | Upload-bound | API 500 free/month, then per image; Web Pro subscription | 45 MP files (15–25 MB) exceed the free 5 MB limit; uploads 11 GB per wedding; strips metadata |
| **Kraken.io** | Cloud lossy/lossless/"expert", resize, convert (JPG, PNG, WebP, AVIF, HEIC) | "at least 60 %, often 80–90 %" (lossy) | Web, API, WP/Magento | Upload-bound | Priced per GB of input: $5 (0.5 GB) … $39 (15 GB) … $79 (60 GB)/month | One 11 GB wedding ≈ the $39 plan for a month |
| **Optimizilla** | Web lossy with a per-image quality slider and preview | Free, preview | ≤ 20 images per batch | Upload-bound | Free (ads) | Manual, small batches |
| **Compressor.io** | Web lossy/lossless, JPEG/PNG/GIF/SVG/WebP | "up to 90 %" | Web drop | Upload-bound | Free; paid plan reported (~$50/yr) | Upload; no control |
| **ShortPixel** | Cloud, WordPress-centred; Lossy / **Glossy** ("for photographers") / Lossless; WebP/AVIF | Glossy keeps "high-quality product pictures" | WP plugin, web, API | Upload-bound | Credits: 100 free/month, one-time packs, subscriptions | Web-delivery tool, not a delivery/archive tool |
| **Optimage** (Mac) | Local; lossless + "visually lossless" lossy with its own perceptual tuning; multi-threaded | Visually lossless, metadata control | Drag-and-drop | Moderate | ~$15 one-time; free tier ~10/day | Closest Mac indie alternative; no published metric or floor |
| **XL Converter** (Win/Linux) | Batch frontend: **jpegli** JPEG, JPEG XL (incl. lossless JPEG transcode), AVIF, WebP; ExifTool metadata; parallel | "up to 35 % better JPEG" via jpegli; reversible JXL | Desktop batch | Multi-core | Free, open source | Not on macOS; fixed-quality, no verification |
| **Guetzli** (Google, 2017) | Butteraugli-guided JPEG search | 20–30 % smaller than libjpeg | CLI | ~1 CPU-min per MP, 300 MB RAM per MP (a 45 MP photo ≈ 45 CPU-min, 13 GB) | Free; **archived Apr 2026** | Unusable at our sizes |
| **jpegli** (Google, 2024) | libjpeg-API encoder/decoder: adaptive dead-zone quantisation, tuned matrices, optional XYB, > 8-bit internal precision | "35 % better compression at high quality" (rater study, encoder-only) | Library, `cjpegli` | "comparable to libjpeg-turbo" | Free | **Our encoder** (SPEC E1) |
| **mozjpeg** (Mozilla) | Trellis quantisation, progressive scan optimisation, tuned tables | 5–10 % smaller than libjpeg-turbo at equal PSNR-HVS | Library/CLI (used by ImageOptim, Squoosh) | 2–5× slower than libjpeg-turbo | Free | Old engine's second encoder; v2 dropped it (E1) |
| **Lightroom Classic** export | Adobe encoder; quality 0–100 in ~13 steps (reported); 4:4:4 at high settings (our source set: IJG ≈ 98–99, 4:4:4); "Limit file size to" for JPEG; AVIF and JPEG XL export (JXL lossless), HDR export with gain-map JPEG | The photographer's default | Export presets, plugins (JPEGmini's plugin hooks in here) | Fast | Subscription (Photography plan) | **The real baseline**: the photographer can simply export at 70–80 instead of 100 — with the same per-photo quality variance JPEGmini has |
| **Capture One** export | Proprietary encoder, quality %, recipes, size estimate (often off) | Recipes | Process recipes | Fast | Subscription/perpetual | Same as Lightroom |
| **Pixelmator Pro / Photomator** (Apple since 2024/25) | Apple ImageIO export: JPEG quality %, HEIC, AVIF/WebP (Pixelmator); Photomator suggests 75–85 % | Photomator: "HEIC ~50 % more efficient" | Batch export | Fast | Pixelmator Pro $49.99 or Apple Creator Studio ($12.99/mo, Jan 2026); Photomator subscription or $99 lifetime | Fixed quality, no verification |
| **Apple ImageIO / Preview / `sips`** | Apple JPEG encoder: baseline, **4:4:4 at every quality tested**, flat-ish tuned luma table (max 15 at q75), rewrites the container | Built in | Preview "Export", Shortcuts, `sips` | Fast | Free | **[M]** q75 on holdout 0014: 8.11 MB at 90.7 (v2 scoring) vs JPEGmini 9.55 MB at 90.73 (same scoring); at 85 v2 (jpegli 4:2:0) beats this style of encoder by ~3 % |
| **AI / neural** | JPEG AI (ISO/IEC 6048-1:2025, learned codec, committee claims ~30 % over state of the art); Adobe Firefly/Lightroom AI features are editing (denoise, super-resolution, generative remove), not compression | — | No consumer encoder or viewer support | GPU-heavy | — | Not deliverable to clients in 2026; watch item only |

Note on Apple ImageIO: `sips` dropped the embedded ICC profile (harmless here: the source was sRGB IEC61966-2.1,
which is also the default assumption) and rewrote the container (JFIF + EXIF + XMP + IPTC, 4 KB instead of 53 KB of
metadata). Lightroom's "13 steps" is from user reports, not Adobe documentation.

## 4. Positioning

**Who we are up against in the photographer's head:** (1) "JPEGmini is the thing for this", (2) "just export from
Lightroom at a lower quality", (3) web optimisers for the website. We win (1) on a verified floor and bytes, (2) on
the floor (a fixed export quality gives the same per-photo spread JPEGmini has), and (3) by doing the website
delivery locally from the same originals, with the metadata policy the photographer chose.

Recommended claims (all measured, all reproducible with `hmb bench`):

1. **"Every photo checked. Lowest score printed on the receipt."** Lead with the floor, not the percentage. JPEGmini
   cannot show one; on one wedding its own files span 75–93.5.
2. **"Smaller than JPEGmini at a higher floor"**: High (≥ 85): 3.05 GB vs 5.36 GB on 535 photos (old engine; re-run
   with v2, with JPEGmini 4.5.x and with one decoder on both sides before publishing). After engine
   recommendation 1, "Highest (every photo ≥ 90) is smaller than JPEGmini" becomes true on the holdout (176 vs
   191 MB); today v2 Highest is 9 % larger.
3. **"One run, all deliveries"** (couple, website, social, archive) — JPEGmini 4.5's multi-size export is the same
   idea without formats beyond JPEG, without a quality check and without a lossless archive.
4. **"Originals are never touched"** (G9) vs JPEGmini's default overwrite.
5. **"Already used JPEGmini? We read its mark"** — route JPEGmini'd folders to the lossless archive (JPEG XL,
   −23.5 % byte-exact) and warn before a second lossy generation.
6. Avoid: "up to 80 %" style claims (everyone makes them), "visually lossless" without the number, speed claims
   against JPEGmini (it is still ~1.7× faster in wall time per photo; per CPU-second we are now at parity).

Pricing reference points: JPEGmini $59–$129 one-time; Optimage ~$15; ImageOptim/Squoosh/XL Converter free; cloud
optimisers $5–$79/month by volume; Lightroom/Capture One subscriptions. A one-time price in JPEGmini's band with
the plugin/automation features included would undercut its $89–$129 tiers.

## 5. Sources

- JPEGmini: https://www.jpegmini.com/ · https://jpegmini.com/pricing · https://www.jpegmini.com/technology ·
  https://jpegmini.com/downloads/mac
- Beamr metric: SPIE 7867 (2011); US 8,908,984; CVPR 2018 workshop "Perceptually optimized low bit-rate…" (Ben-David)
- ImageOptim: https://imageoptim.com/mac · TinyPNG: https://tinypng.com/ , https://tinypng.com/developers ·
  Kraken: https://kraken.io/pricing , https://kraken.io/web-interface · ShortPixel: https://shortpixel.com/faq ·
  Optimage / Mac alternatives: https://compresto.app/blog/imageoptim-alternatives , https://vmdanilov.gumroad.com/l/optimage
- Squoosh: https://github.com/GoogleChromeLabs/squoosh · Guetzli: https://github.com/google/guetzli ·
  jpegli: https://opensource.googleblog.com/2024/04/introducing-jpegli-new-jpeg-coding-library.html
- XL Converter: https://flathub.org/en/apps/eu.codepoems.xl-converter
- Lightroom Classic export: https://helpx.adobe.com/lightroom-classic/desktop/export-photos/export-files-disk-or-cd.html ,
  https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-output.html
- Photomator export: https://support.pixelmator.com/photomator-user-guide/save-share-and-export/export-formats ·
  Apple Creator Studio: https://9to5mac.com/2026/01/13/apple-debuts-apple-creator-studio-subscription-heres-what-you-get/
- JPEG AI: https://jpeg.org/jpegai/
