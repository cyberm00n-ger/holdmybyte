# holdmybyte v2: Binding Specification

Product lead and judge · 2026-10-15 · target: macOS 26 Tahoe, Apple Silicon, Swift 6.2, SwiftUI

This document is binding for every engineer on v2. If it conflicts with anything else (the old repo, a design proposal, a habit), this document wins. Only the lead changes it. To request a change, write it up as a question in your work package's PR.

**How this was decided**
- **Design base: Direction A ("A tool that disappears").** It is a single window: the wedding is a job, one drop produces N deliveries from one decode, and history is a searchable sidebar. Direction B ("The Wedding Is the Unit": a library plus queue, Destinations in Settings, Lightroom After-Export, watch folders, source-change re-delivery, batch selection, a PDF proof) is the better *v2.x roadmap*, but it is roughly 2× the surface. A smaller, excellent v1 wins.
- **Grafted from B:** the proof sentence "535 of 535 photos met their quality target"; the "Lowest five" thumbnail strip in the proof card; the rule that a delivery is never shown green while photos are missing; the ETA copy table; non-modal error banners everywhere (no modal error alerts); the CMYK notice; "Leave room for Lightroom" as the meaning of *Automatic* processor use; the menu-bar drop target is explicitly not taken.
- **Engine proposal:** it arrived empty (`null`). Section 3 was written by the lead from the engine agent's experiment files in `scratchpad/v2/engine-exp/`, from `jpegos/Benchmarks/DATENLAGE.md`, from `Docs/ENGINE-AUDIT.md`, from `LESSONSLEARNED.md`, and from fresh re-measurements taken today (load average 4.4, Lightroom closed). Every number in §3 is tagged:
  - **[M]** measured (source given)
  - **[S]** simulated on real encodes and real scores
  - **[B]** a budget, i.e. a target that must be met. A budget is not a measurement.

---

## 1. Product

### 1.1 In one paragraph

holdmybyte is a native macOS app for wedding photographers. You drop a finished Lightroom export (500–2000 JPEGs of 24–45 MP, about 20 MB each) and press Return. In a single pass, each photo decoded once, holdmybyte writes every delivery you need:
- the couple's full-size JPEG package (typically about 88 % smaller);
- a website gallery (2560 px WebP, about 98 % smaller);
- a social set (1440 px JPEG);
- a byte-exact lossless JPEG XL archive (about 22 % smaller).

Every delivered lossy file is measured against its original with SSIMULACRA2 and must meet its quality bar; the score is measured on the exact bytes that are written. The app then tells a short, honest story: how big each delivery is, how much smaller, the score distribution, and the hardest photos one click away in a Lightroom-style compare view.

Originals are never modified. Nothing leaves the Mac.

### 1.2 The three core flows (v1 must make these perfect)

**F1: Drop → deliveries (the core flow).**
1. The user drags `…/Finn und Lissy/fertig` onto the window.
2. Within 100 ms, setup appears, named **Finn und Lissy**. "fertig" counts as a generic name, so the parent folder's name is used.
3. The remembered deliveries are checked (Couple’s Package and Website).
4. The estimates arrive within 5 s.
5. The user presses Return. The contact sheet turns from grey to colour. The user can close the window, and the job keeps running (Dock progress, plus a transient menu-bar item).
6. A notification arrives. **Show in Finder** reveals `Finn und Lissy – Deliveries/Couple`, ready to upload.
7. Total effort: 1 drag and 1 key.

**F2: Trust: spot-check the hardest photos.**
1. In the Done view, open the proof card and choose **Spot-Check the Hardest Photos**. Compare opens on the lowest-scoring photo.
2. Press `Z` for 100 % at the cursor. Hold `\` to see the original. Press `→` for the next-hardest photo; zoom and position are kept. Press `D` to show the amplified differences.
3. After the 12th photo, a toast reads: "You’ve checked the 12 hardest photos. Everything else scored higher."

**F3: Find a past wedding and add a delivery.**
1. Press ⌘F and type "lissy". The sidebar shows the wedding, grouped under "July 2026" (its wedding date).
2. The Done view loads from history in under 100 ms. ⌘R reveals the folder.
3. **More ▸ Create More Deliveries…** reopens setup with the same sources. Deliveries already made are checked, disabled, and marked "Done Jul 14". Tick Archive and press Return. The output goes into the same Deliveries folder.

---

## 2. Design

### 2.0 Principles (they decide edge cases)

1. **The unit of work is a wedding; the output is a set of deliveries.** One drop is one wedding with N deliveries.
2. **Two actions to a finished delivery:** drop, then Return. Every other control has a remembered default.
3. **Show proof, not promises.** Every number in the UI was measured on *this* wedding. Benchmark marketing numbers never appear in the app.
4. **Native or nothing.** Use system controls, system type and system materials. Liquid Glass appears only where Apple uses it: toolbar, sidebar, sheets, and floating controls over content. Content is never glass.
5. **Originals are untouchable,** and the UI says so once, quietly. There is no "replace original" anywhere. Existing folders are never written into: a name clash gets " 2" appended.
6. **Everything resumes.** Stopping, quitting, a crash or an ejected drive never loses finished work.

### 2.1 Information architecture

```
holdmybyte (single main Window scene, id "main")
├── Sidebar (NavigationSplitView, system floating glass sidebar)
│   ├── New Wedding                 ← always the first row
│   ├── In Progress                 ← running / queued / paused / stopped / interrupted (hidden if empty)
│   └── <Month Year> sections       ← finished weddings, grouped by WEDDING date (earliest EXIF), newest first
│       footer: lifetime stat
├── Detail (one view per selection; its phases morph in place)
│   ├── New Wedding → Empty drop zone → Setup (scanning → ready)
│   ├── Wedding     → Queued → Running → Paused / Stopped / Interrupted → Done / Done with issues / Failed
│   └── Compare     (pushed on the detail NavigationStack; full-bleed)
├── Sheets: Edit Delivery · Rename Wedding
├── Settings scene: General · Deliveries · Advanced
├── Transient MenuBarExtra (only while a job runs AND the main window is closed)
└── Dock tile progress · user notifications · drop onto the Dock icon
```

**Scene skeleton (binding):**

```swift
@main struct HoldMyByteApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @State var model = AppModel.live()
  var body: some Scene {
    Window("holdmybyte", id: "main") { RootView().environment(model) }
      .defaultSize(width: 1120, height: 780)
      .windowResizability(.contentMinSize)
      .windowToolbarStyle(.unified)
      .commands { AppCommands(model: model) }
    Settings { SettingsView().environment(model) }                 // 600 wide, height fits content
    MenuBarExtra(isInserted: $model.showsTransientStatusItem) {
      StatusMenu().environment(model)
    } label: { StatusItemLabel(fraction: model.overallFraction) }
  }
}

struct RootView: View {
  @Environment(AppModel.self) var model
  var body: some View {
    NavigationSplitView(columnVisibility: model.columnVisibilityBinding) {
      Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } detail: {
      NavigationStack(path: model.detailPathBinding) {
        DetailRouter(selection: model.state.selection)
          .navigationDestination(for: CompareRoute.self) { CompareView(route: $0) }
      }
    }
    .searchable(text: model.searchBinding, placement: .sidebar, prompt: "Search Weddings")
    .frame(minWidth: 780, minHeight: 560)
    .onDrop(of: [.fileURL], delegate: WindowDropDelegate(model: model))   // computes DragSummary on dropEntered, calls handleDrop
  }
}
```

**Closing and quitting:**
- Closing the window while a job runs keeps the app alive (`applicationShouldTerminateAfterLastWindowClosed` returns `false` while running, `true` when idle).
- Reopening via the Dock or **Open holdmybyte** restores the window.

**Sidebar visibility:**
- **First launch with empty history:** `.detailOnly`, so the window is just the drop zone.
- **When the first job starts:** the sidebar animates in (`.all`).
- **After that:** the user's ⌃⌘S choice is remembered.

### 2.2 Window chrome and toolbar

- **Window:** default 1120×780, minimum 780×560. Toolbar style `.unified`.
- **Title:** `navigationTitle` is the wedding name. `navigationSubtitle` is `535 photos · 10.95 GB`.
- **Toolbar grouping:** items group into glass capsules automatically. `ToolbarSpacer(.fixed)` separates groups.
- **Labels:** every toolbar button has a text label and a `.help()` tooltip that includes the shortcut, e.g. "Compare photos (⌘Y)".

| Detail state | Toolbar, trailing |
|---|---|
| Empty / Setup | nothing (nothing competes with the drop zone; the commit button lives in the bottom bar) |
| Queued | `Remove from Queue` (`xmark`) |
| Running | group: `Pause` (`pause.fill`) · `Stop` (`stop.fill`) |
| Paused / Stopped / Interrupted | group: `Resume` (`play.fill`) · `Stop` (`stop.fill`) |
| Done / Done with issues | group: `Compare` (`square.split.2x1`) · `Show in Finder` (`folder`) · spacer · `More` menu (`ellipsis`) |
| Compare | leading: `Back` (`chevron.left`, label = wedding name) · principal: segmented `Split │ Side by Side` · trailing group: Delivery menu (only with >1 lossy delivery) · `Differences` (`circle.lefthalf.filled`) · Zoom menu (`plus.magnifyingglass`) · spacer · `Inspector` (`sidebar.trailing`) |

**More menu** (Done): `Create More Deliveries…` · `Rename…` · divider · `Remove from History…`

**Sidebar toolbar:** a `+` button (`plus`, "New Wedding", ⌘N) sits in the sidebar column's toolbar whenever the sidebar is visible.

### 2.3 Sidebar

```swift
List(selection: $selection) {
  NewWeddingRow().tag(SidebarSelection.newWedding)          // Label("New Wedding", systemImage: "plus.circle.fill"), icon .tint
  if !active.isEmpty { Section("In Progress") { ForEach(active) { WeddingRow($0).tag(.wedding($0.id)) } } }
  ForEach(monthGroups) { g in Section(g.title) { ForEach(g.items) { WeddingRow($0).tag(.wedding($0.id)) } } }
}
.listStyle(.sidebar)
.safeAreaInset(edge: .bottom) { LifetimeFooter() }          // .caption, .secondary, padding 12 v / 16 h; hidden when 0
.contextMenu(forSelectionType: SidebarSelection.self) { items in … }
```

**WeddingRow** is 44 pt tall:

```swift
HStack(spacing: 10) {
  ThumbnailView(photo: record.coverPhoto, size: 32).clipShape(.rect(cornerRadius: 6, style: .continuous))
  VStack(alignment: .leading, spacing: 1) {
    Text(record.name).lineLimit(1).truncationMode(.middle)
    Text("Jul 12 · 535 photos").font(.caption).foregroundStyle(.secondary).monospacedDigit()
  }
  Spacer(minLength: 4)
  TrailingAccessory(record)
}
```

TrailingAccessory, first match wins:
1. Running: `ProgressView(value:)`, circular, `.controlSize(.small)`.
2. Queued: `Text("Queued")`, `.caption`, `.tertiary`.
3. Paused, Stopped or Interrupted: `pause.circle`, `.secondary`.
4. Finished with issues: `exclamationmark.triangle.fill`, orange, 11 pt.
5. Finished clean: delivery symbols at 11 pt, `.tertiary`, spacing 3, at most 4.

**Grouping and footer**
- Section titles use the month and year of the wedding date (the earliest capture date), formatted with `.dateTime.month(.wide).year()`, for example "July 2026".
- The cover photo is the first photo by capture time.
- **Lifetime footer:** `1.24 TB saved across 38 weddings`. Saved = Σ(source − output) over full-size deliveries only (Couple’s Package, Archive, and custom full-size deliveries). Resized deliveries are excluded.

**Search** (⌘F focuses the field) matches name, month name, year, source path and camera, case- and diacritic-insensitively. When nothing matches, show `ContentUnavailableView.search(text:)`.

**Context menu:** `Show in Finder` (⌘R) · `Compare Photos` (⌘Y) · `Create More Deliveries…` · `Rename…` · divider · `Remove from History…` (⌘⌫).

**Remove alert:**
- Title: "Remove “Finn und Lissy” from history?"
- Message: "The delivered photos stay where they are. Only this entry is removed."
- Buttons: [Remove] (destructive) [Cancel]

### 2.4 Screen and state catalogue (complete for v1)

Every state below has a snapshot id (§5, WP5) and is rendered in both light and dark appearance.

**Layout widths**
- Setup text column: `frame(maxWidth: 760)`, centred, horizontal padding 32.
- Done header blocks: `maxWidth: 900`.
- Grids: full width, padding 20.

#### S1 `empty`: New Wedding, nothing dropped

```swift
DropZone().padding(20)
// DropZone:
ZStack {
  RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.fill.quinary)
  RoundedRectangle(cornerRadius: 22, style: .continuous)
    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])).foregroundStyle(.tertiary)
  VStack(spacing: 0) {
    Image(systemName: "photo.stack").font(.system(size: 64, weight: .light))
      .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
    Spacer().frame(height: 20)
    Text("Drop a wedding").font(.system(size: 28, weight: .semibold))
    Spacer().frame(height: 6)
    Text("A folder or a selection of finished photos.").font(.title3).foregroundStyle(.secondary)
    Spacer().frame(height: 22)
    Button("Choose Photos…") { model.choosePhotos() }.buttonStyle(.glass).controlSize(.extraLarge)   // ⌘O
    Spacer().frame(height: 28)
    DeliveryPreviewLine()
  }
  VStack { Spacer(); FooterNote().padding(.bottom, 16) }
}
```

- **DeliveryPreviewLine:** a borderless button in `.callout`, `.secondary`, reading `Creates: Couple’s Package · Website`, followed by `chevron.down` at 9 pt.
  - Clicking opens a popover, 280 wide, with one checkbox `Toggle` per preset and a footer button `Edit Deliveries…`, which opens Settings ▸ Deliveries.
  - Changes here update the remembered default set.
- **FooterNote:** `Label("Everything stays on this Mac. Originals are never changed.", systemImage: "lock.fill")`, `.caption`, `.tertiary`, symbol at 10 pt.
- **Whole window is a drop target**, sidebar included. Dropping onto the Dock icon (`application(_:open:)`) behaves the same.

#### S2 `empty-error-raw` / `empty-error-none`: nothing usable dropped

Same zone. The symbol becomes `photo.badge.exclamationmark`, hierarchical, orange.

- Title: **"No photos found"**
- Subtitle, by case:
  - only RAW: "“Finn und Lissy” contains 535 RAW files. holdmybyte compresses finished photos: export JPEGs first."
  - otherwise: "The dropped items don’t contain JPEG, HEIC, PNG or TIFF photos."
- Button: `Choose Other Photos…`
- The zone returns to `empty` after 6 s or at the next drag.

#### S3 `drag-target`

Applies while the drag is inside the window (`isTargeted == true`):
- **Stroke:** 2 pt, solid, `.tint`.
- **Fill:** `.tint.opacity(0.08)`.
- **Motion:** content scales to 1.02 with `.spring(response: 0.3, dampingFraction: 0.8)`. The symbol plays `.symbolEffect(.bounce, value: isTargeted)`.
- **Title** (crossfades), chosen by the dragged items:

  | Dragged items | Title |
  |---|---|
  | one folder | **"Release to add “Finn und Lissy”"** (name inferred as in S4) |
  | files only | **"Release to add 535 photos"** |
  | mixed | **"Release to add 3 items"** |

- **Subtitle:** "Folders are searched, including subfolders."

**Dropping onto other screens**
- **Over Setup:** the setup gets a 2 pt `.tint` inner border and a centred glass capsule, 40 tall, reading **"Add to this wedding"**.
- **Over Running, Done or history:** the capsule reads **"Start a new wedding"**, and the drop opens a new setup.

#### S4 `preparing` → `setup-ready` / `setup-estimating`

The drop zone morphs into Setup within 100 ms of the drop. Setup is usable while scanning continues.

```swift
VStack(spacing: 0) {
  Form {
    Section { SetupHeader() }
    Section {
      ForEach(presets) { DeliveryRow($0) }
      Button { model.addDelivery() } label: { Label("Add Delivery…", systemImage: "plus") }.buttonStyle(.borderless)
    } header: { Text("Deliveries") } footer: { Text("Each photo is read once and saved in every delivery you choose.") }
    Section("Save To") { LocationRow(); RenameRow() }
    if !notices.isEmpty { Section { ForEach(notices) { NoticeRow($0) } } }
  }
  .formStyle(.grouped)
  .frame(maxWidth: 760)
  .scrollEdgeEffectStyle(.soft, for: .bottom)
}
.safeAreaInset(edge: .bottom) { SetupBottomBar() }
```

**SetupHeader** (88 pt tall):

```swift
HStack(spacing: 16) {
  ThumbnailMosaic(photos: first4, cell: 36, gap: 2, corner: 10)      // redacted shimmer while loading
  VStack(alignment: .leading, spacing: 4) {
    TextField("Wedding name", text: $name).textFieldStyle(.plain).font(.system(size: 22, weight: .semibold))
    HStack(spacing: 6) {
      if scanning { ProgressView().controlSize(.small) }
      Text(metaLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }
  }
}
```

- `metaLine` while scanning: `Reading photos… 212 found`. When done: `535 photos · 10.95 GB · July 12, 2026 · ILCE-7RM5`. Omit the date or the camera if unknown.
- **Name inference:**
  - Use the dropped folder's name.
  - If that name is generic, use the parent folder's name. Generic names, case-insensitive: export, exports, final, finals, fertig, jpg, jpeg, jpgs, selects, edited, bearbeitet, output, delivery, lieferung, web, highres, full.
  - For loose files, use their common parent folder, then apply the same rule.

**DeliveryRow** (minimum height 56; clicking anywhere on the row toggles it):

```swift
HStack(spacing: 12) {
  Toggle("", isOn: $on).toggleStyle(.checkbox).labelsHidden()
  Image(systemName: preset.symbol).font(.system(size: 17)).frame(width: 30, height: 30)
    .background(on ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 7, style: .continuous))
  VStack(alignment: .leading, spacing: 2) {
    Text(preset.name).font(.body.weight(.medium))
    Text(preset.specLine).font(.callout).foregroundStyle(.secondary)
  }
  Spacer()
  VStack(alignment: .trailing, spacing: 2) {
    Text(estimateText).font(.body).monospacedDigit()          // "≈ 1.4 GB" | "Estimating…" (redacted shimmer) | off: "–" in .tertiary
    Text(estimateDetail).font(.callout).foregroundStyle(.secondary)   // "−87 %" | resized: "2560 px" | archive: "byte-exact"
  }
  Button("Edit…") { model.editDelivery(preset) }.buttonStyle(.borderless).opacity(hovering || increasedContrast ? 1 : 0)
}
```

- ⌘1…⌘9 toggle rows 1–9.
- **"Create More Deliveries" mode:** deliveries already made are checked and disabled, and their estimate column reads `Done Jul 14`.

**LocationRow:** `LabeledContent("Folder")`
- Value: a `folder` symbol plus a path breadcrumb in `.callout`, middle-truncated, e.g. `Weddings › Finn und Lissy › Finn und Lissy – Deliveries`.
- Trailing: `Button("Change…")`, which opens an `NSOpenPanel` that can choose directories and create folders.
- Second line, `.caption`, `.secondary`: the delivery subfolder names, e.g. `Couple · Website`.

**RenameRow:** `Toggle("Rename by capture time", isOn:)`
- Second line, `.caption`, `.secondary`, `.monospaced()`: `Finn-und-Lissy-0001.jpg … Finn-und-Lissy-0535.jpg`.
- When off: "Original file names are kept."

**SetupBottomBar** (64 tall, `.bar` background, top `Divider`):

```swift
HStack(spacing: 12) {
  Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit()
  Spacer()
  Button("Cancel") { model.cancelSetup() }.keyboardShortcut(.cancelAction).controlSize(.large)
  Button(primaryTitle) { model.startDraft() }.buttonStyle(.glassProminent).controlSize(.large)
    .keyboardShortcut(.defaultAction).disabled(!canStart)
}.padding(.horizontal, 20)
```

- **summary:**
  - before estimates: `2 deliveries`
  - after estimates: `2 deliveries · ≈ 1.6 GB in total · about 5 min`
  - with nothing checked: `Choose at least one delivery.` (the primary button is disabled)
- **primaryTitle:**
  - normally: `Compress 535 Photos`
  - while still scanning: `Compress Photos` (stays enabled; the job starts when the scan ends)
  - when another job is running: `Add to Queue`
- **Cancel** returns to `empty`. Nothing has been written to disk at this point.

#### S5 Setup notices (`setup-warn-precompressed`, `setup-blocked-disk`, …)

A NoticeRow is a `Label` with body text and optional trailing buttons. Symbols by kind:
- info: `info.circle`, `.secondary`
- warning: `exclamationmark.triangle.fill`, orange
- block: `xmark.octagon.fill`, red

A block disables the primary button.

| Situation | Kind | Copy | Actions |
|---|---|---|---|
| Non-photos skipped | info | "Skipped 14 files that aren’t photos (XMP, MOV)." | `Show List` (popover) |
| Some RAW skipped | info | "Skipped 12 RAW files. holdmybyte works on finished photos: export JPEGs from Lightroom first." | none |
| CMYK photos | warning | "2 CMYK photos can’t be compressed yet. They will be listed as issues; export them as RGB." | none |
| Already compressed (DQT quality estimate < 90 on more than 20 % of JPEGs) | warning | **"These photos were already compressed."** "312 of 535 photos look like the output of another compressor. Compressing them again adds a second round of loss. Quality is still measured, but against these files, not your exports." | `Use Archive Only` · `Continue Anyway` |
| holdmybyte output (our COM marker found) | warning | **"These look like holdmybyte deliveries."** "Compressing a delivery again won’t make it meaningfully smaller and adds loss. Drop your Lightroom export instead." | `Continue Anyway` |
| Output folder exists | info | "“Finn und Lissy – Deliveries” already exists here. The new deliveries go into “Finn und Lissy – Deliveries 2”." | none |
| Not enough space | block | **"Not enough space on “Macintosh HD”."** "These deliveries need about 1.9 GB; 0.8 GB is free." | `Choose Another Location…` |
| Location not writable | block | **"holdmybyte can’t write to “Wedding SSD”."** "The drive is read-only. Choose another location for the deliveries." | `Choose Another Location…` |
| Non-JPEG sources in a JPEG delivery | info | "18 HEIC and PNG photos will be delivered as JPEG." | none |
| Output folder inside a dropped folder | block | **"holdmybyte can’t save inside the folder you dropped."** "Choose another location for the deliveries." | `Choose Another Location…` |

In "Create More Deliveries" mode, an existing output folder is expected. The "Output folder exists" notice is suppressed, and new delivery subfolders are added inside it.

#### S6 `edit-delivery`: Edit Delivery sheet (500 × 560, `Form(.grouped)`)

| Field | Control | Options and copy |
|---|---|---|
| Name | TextField | "Couple’s Package" |
| Symbol | Menu, 12 symbols | heart, globe, square.grid.3x3, archivebox, book.closed, printer, iphone, photo, star, sparkles, person.2, folder |
| Format | Picker (menu) | `JPEG` · `WebP` · `JPEG XL (lossless, from JPEG)` |
| Size | Picker (radio) + field | `Full size` · `Long edge: [2560] px` (field 72 wide, monospaced digits, 400–12000) |
| Quality | Picker (menu) | `Highest` · `High` · `Balanced` · `Web`. Footer: the selected level's description (§2.6). It shows `Lossless` and is disabled for JPEG XL. `Balanced` is offered only for Full size + JPEG. |
| Colour | Picker (radio) | `Keep original profile` · `Convert to sRGB` (footer: "Use sRGB for websites and social media.") |
| Metadata | Picker (radio) | `Keep all` · `Remove location and camera serial` · `Remove all except copyright` |
| Folder name | TextField | "Couple" |

- Buttons: `Cancel` (Esc) · `Save` (Return, `.glassProminent`).
- Built-in presets also show `Restore Default`, borderless, bottom-left.
- The sheet validates with `DeliveryPreset.validationError`. Invalid combinations are disabled, never silently corrected.

#### S7 `queued`

The setup header is shown read-only, plus:

```swift
ContentUnavailableView {
  Label("Waiting to start", systemImage: "clock")
} description: {
  Text("Starts automatically after “Anna & Ben” finishes.")
} actions: {
  Button("Start Now Instead") { … }      // pauses the current job, starts this one
  Button("Remove from Queue") { … }
}
```

#### S8 `running-early` / `running-mid`

Running, Paused, Done and history views are **one view in different phases**. The header changes and the grid stays, so the user never loses their place.

```swift
VStack(spacing: 0) {
  RunHeader().padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
  if let banner { StatusBanner(banner).padding(.horizontal, 24).padding(.bottom, 12) }   // S9
  DeliveryStrip().padding(.horizontal, 24).padding(.bottom, 12)
  Divider()
  ScrollView { PhotoGrid().padding(20) }.scrollEdgeEffectStyle(.soft, for: .top)
}

RunHeader = VStack(alignment: .leading, spacing: 10) {
  HStack(alignment: .firstTextBaseline) {
    VStack(alignment: .leading, spacing: 4) {
      Text("Compressing \(name)").font(.system(size: 22, weight: .semibold))
      Text(statusLine).font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }
    Spacer()
    VStack(alignment: .trailing, spacing: 2) {
      Text(savedSoFar).font(.system(size: 28, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
      Text(savedLabel).font(.caption).foregroundStyle(.secondary)
    }
  }
  ProgressView(value: fraction).progressViewStyle(.linear)
}
```

**statusLine** (ETA copy, grafted from B):

| Condition | Copy |
|---|---|
| no photo finished | `Starting…` |
| fewer than 10 photos finished | `12 of 535 photos · estimating time…` |
| ETA under 1 min | `530 of 535 photos · less than a minute left` |
| ETA 1–60 min | `312 of 535 photos · about 3 min left` |
| ETA over 60 min | `312 of 1,800 photos · about 1 h 20 min left` |
| the last photos are in flight | `Finishing…` |

The ETA is an exponentially smoothed seconds-per-photo (α = 0.1) over finished photos, times the remaining photos.

**savedSoFar / savedLabel:**
- With at least one full-size delivery: `8.21 GB` / `saved so far`, summed over full-size deliveries.
- Otherwise: `92 MB` / `delivered so far`.

**DeliveryStrip:** `HStack(spacing: 8)` of capsules (`.fill.tertiary`, 28 tall, horizontal padding 10). Each capsule is symbol + name + live size, e.g. `heart  Couple’s Package  1.02 GB`.
- When a delivery is complete, the size becomes `checkmark` in `.tint`, and clicking the capsule reveals its folder.
- Overflow scrolls horizontally.

**PhotoGrid:** `LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 168), spacing: 6)], spacing: 6)`.
- Cells are square, aspect-fill, corner 6 continuous.
- Order is capture time. The Done view's sort menu can change it.

| Cell status | Look |
|---|---|
| queued | `.saturation(0)`, `.opacity(0.45)` |
| working | `.saturation(0)`, `.opacity(0.85)`; top-right `ProgressView().controlSize(.mini)` on a 20 pt `.regularMaterial` circle |
| done | full colour; transition from saturation 0 to 1 over 0.25 s, ease-out |
| kept original | full colour; top-right `equal.circle.fill`, 14 pt, `.secondary` |
| failed | opacity 0.6; top-right `xmark.octagon.fill`, 14 pt, red |

**Grid interaction:**
- **Hover:** a bottom gradient overlay with white `.caption` in monospaced digits, e.g. `−88 % · 85.4` (for the delivery chosen in the grid header). The tooltip is the file name.
- **Click** selects the cell (2 pt `.tint` ring).
- **Double-click, Space or ⌘Y** on a done cell opens Compare.
- The grid must scroll at 120 fps with 2000 cells.

#### S9 Banners: `paused-user`, `paused-drive`, `paused-disk`, `stopped`, `interrupted`

**StatusBanner layout:**
- `HStack(spacing: 10)`: 16 pt symbol · `VStack` with the title (`.body.weight(.semibold)`) and message (`.callout`, `.secondary`) · `Spacer` · buttons.
- Background `.fill.quaternary`, corner 10, padding 12.
- Banners are never modal.

| Reason | Symbol | Title / Message | Buttons |
|---|---|---|---|
| user paused | `pause.circle.fill` | "Paused" / "312 of 535 photos are done." | `Resume` |
| source drive gone | `externaldrive.badge.xmark` | "Paused: “Wedding SSD” was disconnected." / "Reconnect it, then resume. Nothing has been lost." | `Resume` (enabled when the volume is mounted) · `Stop` |
| output disk full | `exclamationmark.triangle.fill` (orange) | "Paused: “Macintosh HD” is full." / "Free up about 0.6 GB, then resume." | `Resume` · `Stop` |
| output not writable | `exclamationmark.triangle.fill` (orange) | "Paused: holdmybyte can’t write to “Deliveries”." / "Check the folder’s permissions, then resume." | `Resume` · `Stop` |
| stopped by user | `stop.circle.fill` | "Stopped" / "312 of 535 photos are in the delivery folders. The rest can be finished any time." | `Resume` · `Show in Finder` |
| quit or crash | `arrow.clockwise.circle.fill` | "Compression was interrupted" / "312 of 535 photos are done and safe. Continue where it stopped?" | `Resume` · `Stop Here` |

When paused, stopped or interrupted, the RunHeader title is still "Compressing Finn und Lissy", but its progress bar uses `.tint(.secondary)`.

**Stop alert** (⌘. or the toolbar Stop button):
- Title: "Stop compressing “Finn und Lissy”?"
- Message: "The 312 finished photos stay in the delivery folders. You can finish the rest later."
- Buttons: [Stop] [Continue] (default).

#### S10 `done-single` / `done-three`: the result story

```swift
ScrollView {
  VStack(alignment: .leading, spacing: 24) {
    ResultHeader()
    if hasIssues { IssuesCard() }                 // S11
    if folderMissing { MissingFolderBanner() }    // S12
    DeliveryTiles()
    ProofCard()
    GridHeader(); PhotoGrid()
  }.padding(.horizontal, 32).padding(.vertical, 24)       // header blocks capped at maxWidth 900; grid uses full width
}
```

**ResultHeader:**

```swift
HStack(spacing: 14) {
  Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(.tint)
    .symbolEffect(.drawOn, isActive: appeared)                       // once
  VStack(alignment: .leading, spacing: 4) {
    Text("Finn und Lissy is ready").font(.system(size: 26, weight: .semibold))
    Text("535 photos · 2 deliveries · finished in 4 min 12 s · every photo verified").font(.callout).foregroundStyle(.secondary)
  }
}
```

**DeliveryTiles:** `LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)])`. A single delivery spans the full width.

```swift
VStack(alignment: .leading, spacing: 10) {                       // min height 168, padding 18
  Label("Couple’s Package", systemImage: "heart").font(.headline)
  Text("1.35 GB").font(.system(size: 34, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
  Text("from 10.95 GB · −88 %").font(.callout).foregroundStyle(.secondary)
  SizeBar(source: 10.95e9, output: 1.35e9)                       // 6 pt capsule; track .fill.tertiary; fill .tint
  if keptOriginal > 0 { Text("7 photos kept as original. They were already as small as this quality allows.").font(.caption).foregroundStyle(.secondary) }
  HStack {
    Label(proofLine, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
    Spacer()
    Button("Show in Finder") { … }.buttonStyle(.borderless).font(.caption)
  }
}
.background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
.overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
```

Tile variants:
- **Resized delivery:** the size line reads `2560 px · WebP · 159 MB for 535 photos`, and there is no SizeBar.
- **Archive:** the size line reads `from 10.95 GB · −22 %`, and the proof line reads `Byte-exact: every file restores to the identical original`.

**proofLine** by quality level:

| Level | proofLine |
|---|---|
| High / Highest / Web | `Every photo ≥ 85 · lowest 85.0` (the floor and lowest value change with the level) |
| Balanced | `Every photo met its target · lowest 74.0` |

**ProofCard** (tile style, full width, padding 18), with grafts from B:

```swift
VStack(alignment: .leading, spacing: 14) {
  HStack(alignment: .top, spacing: 24) {
    VStack(alignment: .leading, spacing: 6) {
      Text("535 of 535 photos met their quality target").font(.headline)
      Text("Each delivered photo was compared with its original. Lowest 85.0 · median 85.5 · highest 87.3.")
        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
      HStack {
        Button("Spot-Check the Hardest Photos") { … }.buttonStyle(.glass)   // ⇧⌘Y
        InfoButton(popover: QualityExplainer())                            // info.circle, borderless
      }
    }
    Spacer()
    VStack(alignment: .trailing, spacing: 6) {
      if lossyDeliveries.count > 1 { DeliverySwitcher() }                  // segmented, icons only, accessibility labels
      ScoreHistogram().frame(width: 300, height: 84)
    }
  }
  Text("Lowest five").font(.subheadline.weight(.semibold))
  HStack(spacing: 8) { ForEach(lowestFive) { ProofThumb($0) } }   // 96×64, corner 6, score capsule bottom-trailing (.caption2, monospaced, .ultraThinMaterial); click → Compare at that photo
}
```

ProofCard parts:
- **ScoreHistogram (Swift Charts):**
  - Bars: `BarMark` with 0.5-point bins, `.foregroundStyle(.secondary.opacity(0.55))`.
  - Floor line: `RuleMark(x: floor)`, 1.5 pt, `.tint`, annotated with the floor value (`.caption`).
  - Balanced: instead of the rule, a `RectangleMark` band over the target range in `.tint.opacity(0.12)`.
  - Axes: three X ticks, no Y axis.
- **Archive-only weddings:** the card shows only `Label("Byte-exact: 535 of 535 files restore to the identical original.", systemImage: "checkmark.seal.fill")`.
- **QualityExplainer popover** (320 wide):
  - Opening text: "holdmybyte measures every delivered photo against its original with SSIMULACRA2, an open perceptual metric. Higher is closer to the original; 100 means identical."
  - Then the four levels with their descriptions (§2.6).

**GridHeader:** an `HStack` containing, in order:
- `Text("535 Photos").font(.headline)`
- `Spacer`
- Delivery `Picker` (menu, icon and name), which chooses which delivery's values the hover and badges show.
- Sort `Menu` (`arrow.up.arrow.down`): `Capture Time` · `Lowest Score First` · `Largest Savings First` · `Smallest Savings First`
- `Toggle("Issues Only")`, only when there are issues.

#### S11 `done-issues`: partial failure

**ResultHeader changes:**
- Symbol: `exclamationmark.triangle.fill`, orange, with no draw-on.
- Title: "Finn und Lissy is ready, with 3 issues"
- Subtitle: "535 photos · 2 deliveries · 532 verified · 3 need attention"

**IssuesCard:** tile style with a 3 pt orange leading edge and one `DisclosureGroup` per issue type, expanded when the type has 5 or fewer items.
- **Rows:** the file name (`.callout.monospaced()`) and reason, plus the buttons `Show Original` and, if retryable, `Try Again`.
- **Footer:** `Try Again for All`.

| Type | Copy |
|---|---|
| unreadable source | "Couldn’t read 2 photos. The files are damaged or incomplete. They are missing from every delivery." |
| CMYK | "2 photos are CMYK, which isn’t supported yet. Export them as RGB from Lightroom." |
| encode failed | "Website: 1 photo couldn’t be saved. Try again; if it fails again, the file is unusual. Please send the log." |
| write failed | "Couple’s Package: 1 photo couldn’t be saved to the delivery folder." |
| source missing at retry | "1 photo is no longer in the wedding folder." |

**Policies:**
- A full-size delivery is **never** incomplete because of quality. If no candidate beats the original at the quality bar, the engine delivers the original bytes and records `keptOriginal`. That is info, never orange.
- A delivery with any `failed` photo is never shown with the seal. Its tile proofLine reads `532 of 535 photos delivered` in orange.

#### S12 `done-missing-folder`

The banner sits under ResultHeader (StatusBanner style):
- Symbol: `folder.badge.questionmark`
- Title: "The delivery folder has moved or was deleted."
- Message: "Last seen at ~/Weddings/Finn und Lissy/Finn und Lissy – Deliveries."
- Buttons: `Locate…` · `Remove from History…`

While the folder is missing, Compare and Show in Finder are disabled. `Locate…` relinks the folder. It accepts a folder only if at least 90 % of the recorded output relative paths exist in it.

#### S13 `failed`: nothing delivered

```swift
ContentUnavailableView {
  Label("Couldn’t compress “Finn und Lissy”", systemImage: "xmark.octagon")
} description: {
  Text("“Wedding SSD” was disconnected before any photo was finished.")   // the specific reason
} actions: { Button("Try Again") { … }; Button("Remove") { … } }
```

#### S14 Compare: `compare-split-fit`, `compare-split-100`, `compare-side`, `compare-original-held`, `compare-diff`, `compare-no-original`

Compare is pushed on the detail `NavigationStack` and is full-bleed. Content runs under the toolbar: `.ignoresSafeArea(edges: .top)` and `.backgroundExtensionEffect()`. The surround colour is the token `compareSurround` (§2.5).

```swift
ZStack(alignment: .bottom) {
  CompareCanvas(pair:, mode:, zoom:, divider:, showsOriginal:, showsDifferences:)   // NSViewRepresentable, CALayer-backed
  CompareHUD().padding(.bottom, 20)
}
.overlay(alignment: .top) { SideLabels().padding(.top, 52 + 10) }
.inspector(isPresented: $showsInspector) { PhotoInspector().inspectorColumnWidth(min: 240, ideal: 260, max: 320) }
```

**Modes:**
- **Split** (default): original on the left, delivered on the right.
  - Divider: a 1.5 pt white line with a 0.5 pt dark shadow.
  - Knob: a 30 pt circle using `.glassEffect(.regular.interactive(), in: .circle)`, with `arrow.left.and.right` at 12 pt. The divider starts at 50 %.
  - Dragging the knob or the line moves the divider. Dragging elsewhere pans when zoomed; at Fit it moves the divider.
- **Side by Side:** two panes with a 2 pt gap and synchronised zoom and pan.

**Show Original:**
- Hold `\` to show the full original; release to return. Tapping `\` (released within 200 ms) latches it on.
- While the original is shown, a centred capsule reads "Original".
- The swap is a layer visibility flip: no decode, under 16 ms.

**Differences (`D`):**
- Overlays |delivered − original| × 10 on luma darkened to 30 %, coloured in `.tint`.
- Computed with Core Image (`CIDifferenceBlendMode` then a colour matrix), on the GPU.
- A legend capsule at the top right reads "Differences amplified 10×".

**Zoom:**
- Levels are Fit and 100 % only. 100 % = one image pixel per device pixel.
- `Z` toggles between them at the cursor (or the centre if the cursor is outside). Double-click toggles at the click point. ⌘+ / ⌘− and pinch also switch between them.
- Two-finger scroll pans.
- Zoom and pan **persist** when moving to the next photo.

**SideLabels:** glass capsules, 24 tall, `.caption.weight(.semibold)`:
- Left: `Original · 21.4 MB`
- Right: `Delivered · 2.61 MB`
- In Side by Side, one label sits above each pane.

**CompareHUD** (`GlassEffectContainer`, capsule, 44 tall, horizontal padding 6):

```swift
HStack(spacing: 4) {
  Button { prev() } label: { Image(systemName: "chevron.left") }           // ←
  Text(counter).monospacedDigit().frame(minWidth: 96)                       // "12 of 535" | "Hardest 3 of 12"
  Button { next() } label: { Image(systemName: "chevron.right") }          // →
  Divider().frame(height: 20)
  ScorePill(score)                     // capsule, .tint at 15 % background, .tint text; orange only if below target (must never happen)
  Text("21.4 MB → 2.61 MB · −88 %").font(.callout).monospacedDigit()
  Divider().frame(height: 20)
  Menu(orderTitle) { Button("Capture Time"); Button("Lowest Score First"); Button("Largest Savings First") }
}
```

**Spot-check:**
- Opened from the ProofCard (or ⇧⌘Y), the order is Lowest Score First.
- The first K photos count as "Hardest n of K", where K = clamp(ceil(0.03 × photos), 5, 12).
- After the K-th photo, a one-time capsule toast (2.5 s) reads: "You’ve checked the 12 hardest photos. Everything else scored higher."

**Resized deliveries** are compared against the original resized with the identical resampler, which is exactly what was scored. The inspector says "Compared with the original resized to 2560 px."

**Archive** is not selectable in Compare. It is byte-exact, so there is nothing to compare.

**PhotoInspector** (`Form(.grouped)`):
- Header: the file name (`.headline`, middle truncation), then "Captured July 12, 2026 at 15:42" (`.caption`, `.secondary`).
- Section "Quality": `85.4` at 28 pt semibold; below it `Target 85 · High` (`.caption`).
- Section "Size":
  - `LabeledContent("Original", "21.4 MB · 8640 × 5760")`
  - `LabeledContent("Delivered", "2.61 MB · JPEG")`
  - `LabeledContent("Saved", "18.8 MB · −88 %")`
- Section "Details" (`DisclosureGroup`, collapsed): Encoder `jpegli` · Chroma `4:2:0` · Colour `Display P3` · Metadata `Kept` · Time `0.48 s`.
- Buttons: `Show Original in Finder` · `Show Delivered in Finder`.

**Compare loading and availability:**
- **Loading:** first show the source's embedded preview, or an ImageIO thumbnail at 2× the view size. It must appear in under 150 ms. A mini spinner shows in the HUD until full resolution arrives. Keep the current pair decoded plus the next pair at screen resolution.
- **Original unavailable** (`compare-no-original`):
  - The canvas shows the delivered photo only, and the left label reads "Original not available".
  - A capsule reads "Connect “Wedding SSD” to compare."
  - `\`, `D` and Split are disabled.

#### S15 `history-search` / `history-empty-search`

- Search filters the sidebar (§2.3).
- With history empty and the sidebar shown, only the New Wedding row appears and the footer is hidden.

#### S16 Settings: `settings-general`, `settings-deliveries`, `settings-advanced`

The Settings scene uses toolbar-style tabs, is 600 wide, and every tab is a `Form(.grouped)`.

**General** (`gearshape`):

| Label | Control | Copy |
|---|---|---|
| Save deliveries | Picker (radio) | `Next to the originals` · `In this folder:` + path + `Choose…` |
| Folder name | TextField | default `{wedding} – Deliveries`; footer "Tokens: {wedding}, {date}, {year}" |
| Rename photos | Toggle `By capture time` + TextField | default `{wedding}-{number}`; footer preview `Finn-und-Lissy-0001.jpg` |
| When finished | Toggles | `Show a notification` (on) · `Play a sound` (off) |
| Menu bar | Toggle | `Show progress in the menu bar while the window is closed` (on) |
| Processor use | Picker (menu) | `Automatic` · `Gentle`; footer "Automatic leaves room for Lightroom: it uses all but two cores. Gentle uses two cores at low priority." |

**Deliveries** (`square.stack`):
- A `List` of presets. Each row has a checkbox (whether the preset is in the default set), the symbol, the name and the spec line.
- Drag to reorder; the order defines ⌘1…⌘9.
- Bottom bar: `+`, `−` (disabled for built-ins) and `Edit…` (opens S6).
- Bottom-left: `Restore Default Deliveries`.
- Footer: "Checked deliveries are used for new weddings."

**Advanced** (`wrench.and.screwdriver`):
- `Keep detailed logs` (off) and `Show Logs in Finder`.
- `Reset Learned Estimates`.
- `Clear History…` opens an alert: "Clear the history of all 38 weddings? Delivered photos are not touched." [Clear] [Cancel]

#### S17 `menubar-extra`: transient status item

- **Inserted** only while a job runs **and** the main window is closed **and** the setting is on. It is removed when the job ends.
- **Label:** a 16 pt progress ring drawn as a template image, plus `58 %` in monospaced digits.
- **Menu**, in order:
  - "Finn und Lissy" (disabled, bold)
  - "312 of 535 photos · about 3 min left"
  - separator
  - `Pause` / `Resume`
  - `Stop…`
  - separator
  - `Open holdmybyte`

#### S18 Alerts: `alert-stop`, `alert-quit`, `alert-remove`

`alert-stop` and `alert-remove` use the copy above.

**Quit while running** (⌘Q):
- Title: "Stop compressing “Finn und Lissy” and quit?"
- Message: "312 of 535 photos are done. holdmybyte will offer to resume next time it opens."
- Buttons: [Quit] [Cancel] (default).

#### S19 Dock and notifications (no snapshot)

**Dock:**
- `NSDockTile.contentView` shows the app icon with a 6 pt `.tint` progress bar at the bottom while running.
- The badge is the number of finished weddings the user hasn't viewed yet. It clears when the wedding is viewed.

**Notifications:** sent only if the app is not frontmost and the setting is on.

| Event | Title | Body |
|---|---|---|
| finished clean | "Finn und Lissy is ready" | "Couple’s Package 1.35 GB (−88 %) · Website 159 MB · every photo verified." |
| finished with issues | "Finn und Lissy is ready, with 3 issues" | "532 of 535 photos delivered. Open holdmybyte to see what happened." |
| paused by drive | "Paused: “Wedding SSD” was disconnected." | none |

The finished notifications have the actions `Show in Finder` and `Compare`.

### 2.5 Visual tokens (light and dark)

All tokens live in `Sources/HMBUI/Design/Tokens.swift`. Views never use literal colours or sizes outside that file. The single exception is the 1 px separator, which is always `.separator`.

| Token | Light | Dark | Use |
|---|---|---|---|
| `accentMulticolor` | `#0B7F7B` | `#3CC8BF` | `.tint` at the root **only** when the user's system accent is Multicolor (`UserDefaults.standard.object(forKey: "AppleAccentColor") == nil`); otherwise the system accent is used |
| `compareSurround` | `#F2F2F2` | `#1C1C1E` | Compare background (the photographer's neutral surround) |
| `warning` | `.orange` | `.orange` | warnings, issues edge |
| `failure` | `.red` | `.red` | failures |
| `info` | `.secondary` | `.secondary` | info symbols |
| surfaces | `.background`, `.background.secondary`, `.fill.quaternary/.tertiary/.quinary` | same (system-adaptive) | everything else |

**Accent usage.** The accent (`.tint`) appears only on these elements, nothing else:
- progress bars and rings
- the primary `.glassProminent` button
- size-bar fills
- the histogram floor rule and target band
- the seal symbols
- selection rings
- the drag-target state
- the delivery icon well when the delivery is on

**Typography.** SF Pro only. There is no serif face. Monospaced type is used only for file-name previews.

| Role | Spec |
|---|---|
| Tile hero number | 34 pt semibold, `.monospacedDigit()` |
| Running saved counter / drop title | 28 pt semibold |
| Done title | 26 pt semibold |
| Setup name / run title | 22 pt semibold |
| Section and tile titles | `.headline` |
| Body | `.body` |
| Secondary lines | `.callout`, `.secondary` |
| Meta and footers | `.caption`, `.secondary` / `.tertiary` |

**Number formatting:**
- All numbers use `.monospacedDigit()`.
- Bytes use `ByteCountFormatStyle(style: .file)` (decimal, as Finder does).
- Percent uses U+2212 (−) and the locale's spacing; the German locale gives `10,95 GB` and `−88 %`.
- Scores use one decimal.
- The UI language is English. In v1, strings are literal `LocalizedStringKey`s in code; there is no String Catalog file, which avoids merge conflicts. Catalog extraction is a v1.x task.

**Spacing and shape:**
- 4 pt grid. Spacing tokens are 4, 6, 8, 12, 16, 20, 24 and 32.
- Corner radii: drop zone 22 · tiles and cards 16 · status banners 10 · mosaic 10 · icon wells 7 · thumbnails 6. All are `.continuous`.

**Materials:**
- **Glass is used for:**
  - the sidebar, toolbar groups, sheets and popovers (automatic);
  - Compare HUD, knob, side labels and toasts;
  - the drop-onto-content capsule;
  - the `Choose Photos…` and `Spot-Check…` buttons (`.glass`);
  - the primary commit button (`.glassProminent`).
- **Never glass:** the drop zone, tiles, cards, grid and form rows.
- All custom glass goes through one modifier, `.hmbGlass(_:in:)`. It falls back to `.regularMaterial` when `\.isSnapshotRendering` is true, because the snapshot harness cannot render Liquid Glass.

**SF Symbols 7** (hierarchical rendering for symbols 24 pt and larger, monochrome below):
- **Drop zone:** `photo.stack`, `photo.badge.exclamationmark`
- **Wedding:** `plus.circle.fill`, `plus`
- **Delivery presets:**
  - Couple’s Package: `heart`
  - Website: `globe`
  - Social & Blog: `square.grid.3x3`
  - Archive: `archivebox`
- **Proof:** `checkmark.seal.fill`, `checkmark.seal`
- **Compare:** `square.split.2x1`, `arrow.left.and.right`, `circle.lefthalf.filled`, `plus.magnifyingglass`, `sidebar.trailing`
- **Location:** `folder`, `folder.badge.questionmark`
- **Job control:**
  - Actions: `pause.fill`, `play.fill`, `stop.fill`
  - Banners: `pause.circle.fill`, `stop.circle.fill`, `arrow.clockwise.circle.fill`
- **Status:**
  - `externaldrive.badge.xmark`
  - `equal.circle.fill` (kept original)
  - `exclamationmark.triangle.fill`
  - `xmark.octagon.fill`
  - `info.circle`
  - `clock`
- **Sort:** `arrow.up.arrow.down`
- **Privacy note:** `lock.fill`
- **Settings tabs:** `gearshape`, `square.stack`, `wrench.and.screwdriver`

**App icon:**
- **v1 placeholder:** generated by `Scripts/make-icon.sh` as a white photo print in front of a teal glass slab.
- **Final art:** Icon Composer art is a non-goal for v1 (§7).

### 2.6 Quality levels and default deliveries (UI copy)

| Level | Rule (engine) | Description shown |
|---|---|---|
| Highest | score ≥ 90 | "Visually lossless, even when you flick between both at 100 %. For albums and print." |
| High | score ≥ 85 | "Indistinguishable from the original at normal viewing; only a flicker test at 100 % can reveal it." |
| Balanced | per-photo target from texture (74–87) | "Adapts to each photo: detailed scenes keep more, smooth scenes give more. The quality clients are used to, at a fraction of the size." |
| Web | score ≥ 70 | "High quality on screens. For resized website and social images." |

**Default deliveries:**

| id | Name | Spec line | Size | Format | Quality | Colour | Metadata | Folder | Default on |
|---|---|---|---|---|---|---|---|---|---|
| `couple` | Couple’s Package | `Full size · JPEG · Balanced` | full | JPEG | Balanced | keep | keep all | `Couple` | yes |
| `website` | Website | `2560 px · WebP · location removed` | 2560 | WebP | Web | sRGB | remove location | `Website` | yes |
| `social` | Social & Blog | `1440 px · JPEG · sRGB` | 1440 | JPEG | High | sRGB | remove location | `Social` | no |
| `archive` | Archive | `Lossless · JPEG XL · byte-exact` | full | JPEG XL lossless | Lossless | keep | keep all | `Archive` | no |

> Correction to Design A: A set Social & Blog to Web (≥70). The validated pipeline (DATENLAGE §8) ran Social at ≥85 (155 MB for the wedding). 1440 px images are viewed at 100 % on phones, so v1 uses **High**.

### 2.7 Motion

- **Default spring:** `.spring(response: 0.32, dampingFraction: 0.85)`.
- **State morphs** (empty → setup → running → done): a 0.35 s `.smooth` crossfade, with `matchedGeometryEffect` on the title and on the mosaic → grid.
- **Drag target:** scale to 1.02 plus a symbol bounce.
- **Scan:** thumbnails arrive with opacity 0 → 1 and a 15 ms stagger, capped at the first 40 cells.
- **Photo done:** saturation 0 → 1 over 0.25 s. Engine events are coalesced to at most 10 UI updates per second.
- **Counters:** `.contentTransition(.numericText())`. Tile hero numbers count down from the source size to the output size over 0.6 s, on first appearance only.
- **Done seal:** `.symbolEffect(.drawOn)`, once.
- **Reduce Motion:** no scale, bounce, stagger or count-up; only 0.2 s opacity crossfades. Numbers appear at their final values.

### 2.8 Keyboard shortcuts and menus

| Menu | Item | Key |
|---|---|---|
| holdmybyte | Settings… | ⌘, |
| File | New Wedding | ⌘N |
| | Choose Photos… | ⌘O |
| | Show in Finder | ⌘R |
| | Close Window | ⌘W |
| Edit | Find (sidebar search) | ⌘F |
| Wedding | Start / Add to Queue | ⌘↩ (Return also works in setup) |
| | Toggle Delivery 1–9 (setup) | ⌘1…⌘9 |
| | Pause / Resume | ⌥⌘P |
| | Stop… | ⌘. |
| | Compare Photos | ⌘Y (Space on a selected grid photo) |
| | Spot-Check Hardest Photos | ⇧⌘Y |
| | Create More Deliveries… | ⇧⌘N |
| | Remove from History… | ⌘⌫ |
| View | Show/Hide Sidebar | ⌃⌘S |
| | Sort Photos ▸ Capture Time / Lowest Score / Largest Savings / Smallest Savings | — |
| | Comparison ▸ Split / Side by Side | Y toggles |
| | Comparison ▸ Show Original (hold) | \ |
| | Comparison ▸ Fit / 100 % | Z |
| | Comparison ▸ Zoom In / Out | ⌘+ / ⌘− |
| | Comparison ▸ Show Differences | D |
| | Comparison ▸ Inspector | I, ⌥⌘I |
| | Comparison ▸ Next / Previous Photo | → / ← |
| | Back | Esc, ⌘[ |
| Help | How Quality Is Measured | — |

Single-letter keys are active only while Compare is focused. They are declared on menu items with `.keyboardShortcut(_, modifiers: [])` so that they are discoverable.

### 2.9 Accessibility

**VoiceOver labels and actions:**

| Element | Treatment |
|---|---|
| Drop zone | Label "Drop zone"; hint "Drop photos or folders, or press Command-O to choose photos."; `.accessibilityAction(named: "Choose Photos")` |
| DeliveryRow | One combined element: "Couple’s Package, full size JPEG, Balanced quality, estimated 1.4 gigabytes, 87 percent smaller, checked" |
| Grid cell | "DSC09412, done, 88 percent smaller, score 85.4"; action "Compare" |
| Progress | `AccessibilityNotification.Announcement` at every 10 %, and on pause and finish |
| Compare divider | `accessibilityAdjustableAction` in 10 % steps; value "Divider at 50 percent"; `\` is exposed as the action "Show Original" |
| Histogram | `accessibilityChartDescriptor` with the summary "535 photos, lowest 85.0, median 85.5, all at or above 85" |

**Keyboard:**
- Every action is reachable from the keyboard.
- Setup focus order: name → deliveries → folder → rename → Start.

**Increase Contrast:**
- The drop-zone stroke becomes 2 pt solid `.secondary`.
- Card strokes become `.primary.opacity(0.3)`.
- The hover-only `Edit…` button is always visible.

**General rules:**
- Colour never carries meaning alone. Every state has a symbol and words, and the red and orange badges differ in shape.
- Hit targets are at least 28×28 pt. Hover-revealed controls stay in the accessibility tree.
- Numbers are never truncated. Names use middle truncation with the full name as a tooltip.
- Reduce Motion follows §2.7. Reduce Transparency is handled by the system materials.

---
## 3. Engine

### 3.0 Decisions and corrections (read first)

The engine proposal was empty. The decisions below come from the experiment files and today's re-measurements. Every number carries a tag (see the introduction): **[M]** measured, **[S]** simulated, **[B]** budget.

**As built (updated 2026-10-16).** The engine lead's decisions D-ENG-1…12 (`Docs/DECISIONS.md`) amend this section.
The rows and subsections below state the engine as it now is; each amendment names its decision, and
`Docs/ENGINE.md` holds the measurements. Original rationale is kept where it still explains the choice.

| # | Decision | Evidence | Rejected alternative |
|---|---|---|---|
| E1 | **One JPEG encoder: jpegli, linked in-process via its native `jpegli_*` API.** No mozjpeg, no QuantRefiner, no encoder competition. *As built (D-ENG-11):* jpegli's own tables are reshaped per search (`JPEGTuning.fullSize`: chroma tables at d × 0.65, DC at d × 0.8, luma AC tilted up to × 4.95 at high frequencies, AQ on; `JPEGTuning.resized`: chroma at d × 0.7, **adaptive quantisation off**). Every output is still a standard progressive jpegli JPEG. | **[S]** On the 19-photo holdout at the old engine's per-photo reference-scale scores, jpegli 4:2:0 alone gives 49.28 MB vs. the old engine's 49.81 MB (−1.1 %) with a bracketing search (`search-analysis.txt`), and 49.47 MB (−0.7 %) / 49.86 MB (+0.1 %) with the proxy-guided search (`sim-A.txt`, `sim-B.json`). jpegli 4:4:4 won 0 of 19. | The old competition (moz420/moz444/jpegli420/jpegli444 + refiner): 2 libjpegs with clashing symbols, a subprocess helper, and 66 % of CPU spent on a rider. |
| E2 | **4:4:4 only as fail-open**, when 4:2:0 cannot reach the target at d ≥ 0.5. The gate `chromaEnergy ≥ 2.42 → also search 4:4:4` exists behind a flag that is **off** by default and is switched on only if gate G3 (§6) fails. *As built (D-ENG-11):* holds for full size; DirectSearch JPEG at T ≥ 80 (Social at 85) searches **4:4:4 first** and no 4:2:0 (with `resized` tables 4:4:4 is 7–12 % smaller at T 85, and 4:2:0 cannot reach 90 at 1440 px). | jpegli444 won 7/533 on the old harvest. `chroma-0110.txt` **[M]**: on the most chroma-rich sample, 4:2:0 at d1.6 gives 74.80 @ 3.41 MB, while 4:4:4 needs about 3.85 MB for the same score. | Always searching both (2× the probes on about 25 % of photos for ~1 % of wins). |
| E3 | **Delivered bytes are exactly the scored bytes.** Probes are encoded at the final setting: progressive level 2, adaptive quantisation on. There is no "probe at p0, re-encode at p2". *As built (D-ENG-11):* holds for every full-size output; full probes use a per-component progressive AC script chosen from the first mosaic encode (same coefficients). A DirectSearch JPEG may be delivered as a **lossless scan rewrite** of the scored file (kept only when ImageIO decodes both to identical pixels; the coefficients are identical, so every decoder agrees) or as a rewrite that zeroes isolated ±1 coefficients, which is **scored as delivered**. The mosaic proxy uses a 4-scan script with the same coefficients. | `jpegli-modes.txt` **[M]**: p2 is 2.4–3.1 % smaller than p0 at the same distance, but costs 0.76 s vs 0.37 s **[M today]**. CPU is not the bottleneck (§3.11), so the stronger guarantee is worth 0.4 CPU-s. | `photo-pipeline.sh`'s p0-probe/p2-final model: it relies on a pixel-identity assumption that nobody has tested. |
| E4 | **Search = mosaic proxy + bias-corrected full-resolution probes**, mean about 2.0 and at most 3 full probes, with constants from `simulate.py` and `STOP = 0.5`. *As built (D-ENG-3):* the mosaic is encoded and scored *at the probe's own distance* (`.mosaicExact`, §3.4); holdout 1.84 full probes mean, max 3. | `proxy-analysis.txt` **[M]**: grid mosaic full−mosaic bias mean −1.49, sd 0.61, slope correlation 0.97 (the "hard" mosaic is worse: sd 1.32). `sim-B` **[S]**: 2.0 probes mean, 3 max, 0/19 unresolved, overshoot max 0.51. | The "hard" tile mosaic; half- or quarter-scale proxies (`scale-analysis.txt`: quarter-scale residual 4.5 points, so it is useless). |
| E5 | **Metric = port of the old Metal SSIMULACRA2** (FIR Gaussian, cached reference session), *not* a new implementation. All floors (85, Balanced 74…87) are defined on this scale, the same scale as every DATENLAGE number. | Old port GPU vs CPU agreement ≤ 0.01. Holdout **[M]**: port scores read +0.53 above the libjxl reference binary on average at about 74 (`old-holdout-ownscores.txt` vs `-refscores.txt`). | A new IIR-exact kernel: it shifts every floor and invalidates all benchmark comparisons for v1. It is recorded as a v1.x task. |
| E6 | **Decode with ImageIO** for sources and candidates (no colour conversion, no orientation applied). *As built:* ImageIO stays the scoring decoder (D-ENG-2). **Decoder guard (D-ENG-12):** a 4:4:4 JPEG candidate that passes is also decoded the way libjpeg-turbo does it (browsers; in process, from jpegli's coefficients) and the lower score counts; for jpegli 4:2:0 ImageIO is the lower reading, and ImageIO's WebP pixels are libwebp's. | **[M today]**: ImageIO 45 MP decode 0.10 s + 0.012 s blit, vs libjpeg-turbo 0.28–0.30 s (`bench/iio`, `bench/dec`). | libjpeg-turbo (a third libjpeg, symbol clash with jpegli's wrapper). |
| E7 | **Website = WebP only.** If WebP can't reach the floor, fall back to JPEG. **No AVIF in v1.** | DATENLAGE §8: WebP 2560/≥70 = 159 MB, −98.5 %, reached on every photo. AVIF (`avif-web.txt`) is smaller, but needs libaom (a huge vendoring burden) and has spottier CMS/upload support. | AVIF as the default or as a fallback tier. |
| E8 | **Archive = libjxl lossless JPEG transcode, effort 7, verified by reconstruction plus SHA-256.** *As built (D-ENG-10/11):* up to 4 threads per transcode and verification (output independent of the thread count), libjxl memory from a per-call arena, archives as their own work items. | **[M today]**: 45 MP sample, 1.90 s encode + 1.16 s reconstruct, single thread, `cmp` byte-exact, −22.1 %. e9 saves only 0.4 % more (`jxl/`). | Effort 9. |
| E9 | **One process, real worker `Thread`s, one GPU metric lane.** | LESSONSLEARNED §13 (GCD starvation) and DATENLAGE §7 (lanes 1→3 gain nothing; width 5 was optimal with the old per-photo cost). | Swift-concurrency task groups blocking on engine gates. |
| E10 | **No predictor, no student metric, no grain synthesis, no training log** in v1. | DATENLAGE §2 failed-attempts ledger; grain synthesis is unverifiable with full-reference metrics. | — |

### 3.1 Public API (module `HMBModel`, implemented by `HMBEngine.LiveEngine`)

The UI only ever talks to this protocol. `FixtureEngine` (in `HMBFixtures`) implements it for previews, snapshots and UI tests.

```swift
// Sources/HMBModel/EngineService.swift  (frozen after WP0)
import Foundation

public protocol EngineService: Sendable {
    /// Recursively scans dropped items. Yields `.progress` at most every 100 ms and exactly one `.finished`.
    func scan(_ items: [URL]) -> AsyncThrowingStream<ScanUpdate, any Error>

    /// Size estimates for each delivery, from a sample of at most 12 photos. Must finish within 5 s for
    /// the default deliveries on 45 MP photos. Cancellable (Task cancellation).
    func estimate(photos: [SourcePhoto], deliveries: [DeliveryPreset]) async throws -> [DeliveryID: DeliveryEstimate]

    /// Checks space and writability and resolves the output folder (adds " 2" if needed). Writes nothing.
    func preflight(_ request: JobRequest) async -> Preflight

    /// Runs (or, with `resume: true`, continues) a job. Exactly one job runs at a time; the caller queues.
    /// The stream ends after `.phase(.finished)`, `.phase(.stopped)`, `.phase(.paused)` or `.phase(.failed)`.
    func run(_ request: JobRequest, resume: Bool) -> AsyncStream<EngineEvent>

    func pause(_ wedding: WeddingID) async
    func stop(_ wedding: WeddingID) async

    /// Jobs that have a journal but no finished marker (shown as Interrupted at launch).
    func unfinishedJobs() async -> [UnfinishedJob]
    /// Forgets the journal of a finished or abandoned job.
    func discardJournal(_ wedding: WeddingID) async

    /// Decoded original (resized and colour-converted exactly as scored) plus the decoded delivered file.
    func comparePair(record: WeddingRecord, photo: PhotoID, delivery: DeliveryID,
                     maxPixelSize: Int?) async throws -> ComparePair
}
```

### 3.2 Internal primitives contract (module `HMBEngine`, file `Sources/HMBEngine/Interfaces/Primitives.swift`, frozen after WP0)

WP1 implements these primitives and WP2 consumes them. Both packages compile against this file from day one: WP0 ships `Primitives+Fakes.swift` with deterministic CPU fakes.

```swift
import Foundation
import CoreGraphics
import HMBModel

/// 8-bit RGBA (alpha ignored, always opaque), rows contiguous with `bytesPerRow`, in `colorSpace`.
public final class PixelImage: @unchecked Sendable {
    public let width: Int, height: Int, bytesPerRow: Int
    public let colorSpace: CGColorSpace
    public let pixels: UnsafeMutableRawBufferPointer        // owned; freed in deinit
    public init(width: Int, height: Int, colorSpace: CGColorSpace)   // zero-filled, bytesPerRow = width * 4 rounded up to 64
    deinit
    public var pixelCount: Int { width * height }
}

public struct JPEGMarker: Sendable, Hashable { public var code: UInt8; public var payload: Data }   // 0xE0…0xEF, 0xFE

public struct SourceInfo: Sendable {
    public var kind: SourceKind
    public var fileBytes: Data                  // memory-mapped
    public var markers: [JPEGMarker]            // JPEG only: APPn + COM in file order
    public var iccProfile: Data?
    public var exif: Data?                       // TIFF-structured EXIF payload without the "Exif\0\0" prefix
    public var xmp: Data?
    public var orientation: Int                  // 1…8
    public var estimatedJPEGQuality: Int?        // from DQT (IJG scale)
    public var isCMYK: Bool
    public var isHoldMyByteOutput: Bool          // COM marker "holdmybyte" present
    public var isArithmeticCoded: Bool
}

public struct ImageFeatures: Sendable { public var textureP50: Double; public var chromaEnergy: Double }

public enum ChromaSubsampling: String, Sendable, Codable { case s420 = "4:2:0", s444 = "4:4:4" }

public protocol ImageDecoding: Sendable {
    func inspect(_ url: URL) throws -> SourceInfo                         // no pixel decode
    func decode(_ info: SourceInfo) throws -> PixelImage                  // full resolution, stored orientation
    func decode(encoded: Data) throws -> PixelImage                       // candidate decode (JPEG/WebP)
}
public protocol ImageProcessing: Sendable {
    func features(_ image: PixelImage) -> ImageFeatures                   // port of GrainEstimator.statistics(p50) + chromaEnergy
    func resized(_ image: PixelImage, longEdge: Int) -> PixelImage        // vImage high-quality (Lanczos); never upscales
    func convertedToSRGB(_ image: PixelImage) -> PixelImage               // perceptual intent via vImageConverter
    func mosaic(_ image: PixelImage) -> PixelImage?                       // 8×4 grid of 256² tiles; nil if < 2048×1024
}
public protocol JPEGEncoding: Sendable {
    func encode(_ image: PixelImage, distance: Double, subsampling: ChromaSubsampling,
                markers: [JPEGMarker]) throws -> Data                     // jpegli, progressive level 2, adaptive quant on
}
/// Opaque, prepared (sharp-YUV converted) WebP input. WP1 subclasses or wraps `hmb_webp_prepared*`; freed in deinit.
open class WebPPrepared: @unchecked Sendable { public init() {} }
public protocol WebPEncoding: Sendable {
    func prepare(_ image: PixelImage) throws -> WebPPrepared              // sharp-YUV conversion once
    func encode(_ prepared: WebPPrepared, quality: Float, icc: Data?, exif: Data?, xmp: Data?) throws -> Data   // method 4
}
public protocol JXLTranscoding: Sendable {
    func transcodeLossless(jpeg: Data, effort: Int) throws -> Data
    func reconstructJPEG(jxl: Data) throws -> Data
}
public protocol MetricReference: AnyObject, Sendable { var width: Int { get }; var height: Int { get } }
public protocol PerceptualMetric: Sendable {
    func prepareReference(_ image: PixelImage) throws -> any MetricReference   // GPU pyramid of the reference, reused per candidate
    func score(_ candidate: PixelImage, against reference: any MetricReference) throws -> Double
    func release(_ reference: any MetricReference)
}

public struct EnginePrimitives: Sendable {
    public var decoder: any ImageDecoding
    public var processing: any ImageProcessing
    public var jpeg: any JPEGEncoding
    public var webp: any WebPEncoding
    public var jxl: any JXLTranscoding
    public var metric: any PerceptualMetric
    public static func live() throws -> EnginePrimitives    // WP1
    public static func fakes() -> EnginePrimitives          // WP0 (deterministic: PSNR→score mapping, fake codecs)
}
```

*As built (additive, D-ENG-10/11/12):* `JPEGEncoding` gained `encodeForScoring` (same coefficients, 4-scan proxy
script, for the mosaic), `encode(…, scans:)` and `chooseScans` (per-component AC script, `JPEGScanChoice`), and
`TunableJPEGEncoding` takes a `JPEGTuning`; `live(webpTuning:)` builds `LibWebPEncoder` with `WebPTuning.default`
(method 6, loop-filter strength 40, sharpness 7 on `WEBP_PRESET_PHOTO`); `PixelImage` ≥ 1 MB is an anonymous mapping
and decoded candidates may wrap ImageIO's buffer; `IslowDecoder` decodes a JPEG to libjpeg-turbo's pixels (decoder
guard). The fakes implement the defaults.

### 3.3 Per-photo pipeline (one decode, all deliveries)

Each worker processes one photo end to end:

```
1. inspect(url)                      → SourceInfo (memory-mapped bytes, markers, ICC, EXIF, XMP, DQT quality, CMYK flag)
   if isCMYK                         → every lossy delivery: failed(.cmykUnsupported); Archive: attempt transcode, the §3.6 verification decides (else keep original)
2. decode(info)                      → PixelImage S (source colour space, stored orientation)      [M 0.10 s]
3. features(S)                       → textureP50, chromaEnergy                                     [B ≤ 0.05 s]
4. for delivery in executionOrder:   resized lossy (ascending long edge) → full-size lossy → archive
     source variant V = S → (convertedToSRGB if colour == .convertToSRGB) → (resized if longEdge < max(W,H))
     (variants are cached per photo by (colour, longEdge); a resize is computed at most once)
     lossy:   meta = final metadata (§3.7), built before the search so every probe carries it (scored = written)
              bytes = search(V, target(delivery, features))      §3.4 / §3.5
     archive: bytes = archive(info)                              §3.6 (as built: a separate work item of the photo, D-ENG-10)
     metadata applied (§3.7), then OutputWriter.write(bytes, for: photo, delivery)   §3.8
5. release S, the variants and the metric references; append PhotoResults to the journal; emit events
```

Targets:
- **highest / high / web:** the fixed floor (90 / 85 / 70).
- **balanced:** `textureP50 < 4.5 ? 74 : clamp(88 − 0.62 · textureP50, 75…87)`. This is ported verbatim from `jpegos/Sources/SqueezeCore/ClassicTarget.swift`, and `textureP50` and `chromaEnergy` are ported verbatim from `GrainEstimator.swift` (16×16 blocks, 4-neighbour high-pass on luma).

### 3.4 Full-size JPEG search (`MosaicSearch`)

The constants are binding. WP2 may retune them only with a holdout A/B recorded in `Docs/ENGINE.md`.
*As built:* the aim is `.mosaicExact` (D-ENG-3); the original §3.4 loop stays selectable as `.proxyCurve` with its
constants (M0 = 0.6, M1 = 0.15, BIAS = −1.5, STOP = 0.5). Probes and mosaic use `JPEGTuning.fullSize` (D-ENG-11).

```
Inputs: V (full-size variant), target T, source bytes B_src (for keep-original), sourceIsJPEG, colour, chroma (4:2:0)
Constants: MAX_FULL = 3, RESCUE = 2, D_MIN = 0.5, bias prior −1.1, bias slope −0.6 / ln d, first margin 0,
           margin 0.03, stop 0.15, min step 0.003 (ln d), rescue margin 0.3, solver ≤ 6 mosaic evaluations / width 0.004
prior(T)   = exp(0.693 + 0.06 · (74 − T))         // 74→2.00, 85→1.03, 90→0.77 (holdout replay: no refit needed)
mosaic M   = processing.mosaic(V)                  // 8 cols × 4 rows of 256×256 tiles, each centred in its cell, origin floored to /16
x          = ln d, on a 1e-4 grid (solver and probes use identical distances → deterministic)
m(x)       = score(decode(jpeg_proxy(M, d, tuned)), ref(M)), cached; 3 seeds at prior(T)·{0.8, 1, 1.25}
             the first mosaic encode per chroma also fixes the AC scan script of every full probe (same coefficients)
probe(d)   = bytes = jpeg(V, d, tuned, chosen script, final markers); s = score(decode(bytes), refV)
bias(x)    = −1.1 before any probe; one side known: b_ref − 0.6·(x − x_ref) from the probe closest to T;
             passing P and failing F: linear between b_P and b_F; with b_k = s_k − m(x_k)
solve(g)   = largest x in [lo, hi] with m(x) + bias(x) ≥ g (bracket from cached mosaic points, regula falsi)
probe 1    : solve(T + 0)
loop       : while probes < MAX_FULL: stop if a passing probe has s − T < 0.15;
             lo = max passing x + 0.003, hi = min failing x − 0.003; stop if lo > hi; probe solve(T + 0.03)
result     = smallest-bytes passing probe
rescue     : none passed → first rescue at solve(T + 0.3) below the smallest failing x, then d × 0.8 (≥ D_MIN), ≤ RESCUE
fail-open  : still none → the whole search again with 4:4:4
keep-orig  : sourceIsJPEG && colour == .keepProfile && (no pass || best.bytes ≥ 0.95 · B_src) → original bytes
             (metadata policy applied losslessly, §3.7), status .keptOriginal
non-JPEG source and no pass → status .failed(.qualityUnreachable)   // practically unreachable; must be logged
```

Small images (no mosaic, i.e. under 2048×1024) use `DirectSearch` (§3.5) with JPEG.

**[M] as built** (holdout, release, D-ENG-11): 48,365,625 bytes for 19 photos at 1.84 full probes mean, max 3, every
photo ≥ target (G1 limit 50,301,670, D-ENG-1). Cost per aimed probe ≤ 6 mosaic evaluations (~0.03 s each on 2 MP).

### 3.5 Resized deliveries (`DirectSearch`)

- **Reference:** the resized (and possibly sRGB-converted) variant V. This is exactly what Compare shows as "original".
- **Parameters** (axis on which the score falls; values within one quantum of a range end snap to it):
  - JPEG: x = ln d ∈ [ln 0.5, ln 25], quantum 0.001, start `prior(T)`, default slope −10 per ln d, max step 1.0.
  - WebP: x = −q, q ∈ [0, 100], quantum 1, start `qPrior(T) = clamp(80 + 1.1·(T − 70), 5…100)` (fitted on the
    holdout, D-ENG-5), default slope +0.5 per q, max step 30.
- **Search:** a secant step on the two latest probes, aimed at T + stop/2, clamped into the passing/failing bracket
  (midpoint when outside; stop when the bracket is one quantum wide).
  - Stop at the first passing probe with s − T < stop — WebP 1.0, **JPEG 0.5** (D-ENG-8) — or after 5 probes.
  - Result: the smallest-bytes passing probe.
- **JPEG order** (`JPEGTuning.resized`, D-ENG-11): T ≥ 80 → 4:4:4 from the prior, then 4:4:4 at d = 0.5 (no 4:2:0);
  below 80 → 4:2:0, then 4:2:0 at d = 0.5, then 4:4:4 from d = 0.5. Small full-size images also apply keep-original.
- **JPEG post-pass** (D-ENG-11): the result is rewritten with the per-component scan script estimated from its
  coefficients (kept only if ImageIO decodes it to identical pixels), then up to 4 rewrites that zero isolated ±1 AC
  coefficients (bisection over the zigzag start) are each scored; the smallest passing one is delivered. The
  re-scores count as probes.
- **Decoder guard** (D-ENG-12, `SearchConstants.decoderGuard`, default `.chroma444`): every 4:4:4 JPEG probe or
  rewrite that passes under ImageIO is scored again on libjpeg-turbo's pixels; its score is the lower of the two.
- **WebP encoding:** `WebPConfigPreset(WEBP_PRESET_PHOTO)` with `method = 6`, filter strength 40, sharpness 7
  (`WebPTuning.default`, D-ENG-11; was method 4 and the preset's filter), `use_sharp_yuv = 1`, `thread_level = 0`. The
  sharp-YUV conversion is done **once** per (photo, delivery) and copied per probe (fixes old audit #19).
- **WebP fallback:** if WebP at q = 100 does not reach T, the delivery falls back to JPEG with the same size and the same search. The encoder is recorded as `jpegli (fallback)`, and the file gets a `.jpg` extension.
- **JPEG failure:** if JPEG at d = 0.5 with 4:4:4 still misses T, the status is `.failed(.qualityUnreachable)`.

### 3.6 Archive (`JXLArchive`)

- **Scope:** only JPEG sources that are Huffman-coded, baseline or progressive.
  - Non-JPEG, arithmetic-coded or unusual sources: the original bytes are copied (status `.keptOriginal`, encoder `copy`).
- **Encode:** `JxlEncoderAddJPEGFrame` with `JxlEncoderStoreJPEGMetadata(enc, JXL_TRUE)`, effort 7. *As built
  (D-ENG-11):* up to 4 threads per call (`hmb_jxl_*_threads`); libjxl's output does not depend on the thread count
  (535/535 wedding archives identical). At most `MemoryPlan.archiveLanes` archives run at once (§3.9).
- **Verification is mandatory for every file:** `reconstructJPEG(jxl)` must be byte-identical (SHA-256) to the source bytes.
  - If it is not, the `.jxl` is discarded, the original is copied, a failure is logged, and the status is `.keptOriginal`.
- The result is recorded as `PhotoResult.byteExact = true`.
- Metadata policy does not apply to the archive (byte-exact means byte-exact).

### 3.7 Colour and metadata

**Colour:**
- `keepProfile`: pixels are untouched, and the source ICC is re-embedded verbatim (an APP2 chain for JPEG, the ICCP chunk for WebP).
- `convertToSRGB`: `vImageConverter` from the source `CGColorSpace` to sRGB, perceptual intent, done once per photo. The output embeds `CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()`.
- The metric reference for converted deliveries is the **converted** variant. The score measures compression loss, not gamut mapping. The inspector shows `Colour: Converted to sRGB`.

**Orientation:** never applied to pixels. The EXIF Orientation is preserved under every policy.

**Metadata:** handled by `MetadataEditor` (Swift, WP2). EXIF is rebuilt with a minimal TIFF IFD writer; XMP is rewritten via `CGImageMetadataCreateFromXMPData` → remove → `CGImageMetadataCreateXMPData`.

| Policy | EXIF | XMP | IPTC (APP13) | ICC |
|---|---|---|---|---|
| keepAll | verbatim | verbatim | verbatim | verbatim (or sRGB if converted) |
| removeLocation | drop GPS IFD (tag 0x8825), BodySerialNumber 0xA431, LensSerialNumber 0xA435, MakerNote 0x927C, SubIFDs; *as built (D-ENG-8):* also IFD1 and its thumbnail | drop `exif:GPS*`, `aux:SerialNumber`, `aux:LensSerialNumber`, `exifEX:BodySerialNumber`; *as built (D-ENG-11):* written without layout whitespace when CGImageMetadata reads the same tags back | verbatim, *as built (D-ENG-8):* except the preview resources 0x0409/0x040C | as keepAll |
| removeAll | new minimal EXIF: Orientation, Artist, Copyright | only `dc:rights`, `dc:creator` (without layout whitespace) | dropped | as keepAll |

**Container placement:**
- JPEG outputs: the ordered markers are APP1 Exif, APP1 XMP, APP2 ICC chain, APP13, then `COM "holdmybyte 2.0"`.
- WebP outputs: VP8X with ICCP / EXIF / XMP chunks, via libwebpmux.
- Keep-original copies under a non-keepAll policy are rewritten **losslessly**: the JPEG entropy data is copied byte for byte and only the segments are replaced. A test proves the decoded pixels are identical. Data after EOI (MPF/CIPA previews with their own unfiltered EXIF) and the APP2 MPF index are dropped under these policies.

### 3.8 Scanning, jobs, writing, resume

**Scan:**
- Recursive. It skips hidden items, packages, symlinks, `.holdmybyte-partial`, and folders whose name ends in ` – Deliveries`.
- **Accepted inputs:** `.jpg .jpeg .jpe .heic .heif .png .tif .tiff` (verified by UTType conformance).
- **RAW** (`cr2 cr3 nef nrw arw srf sr2 raf orf rw2 pef dng srw x3f 3fr iiq erf mef mos rwl`) is counted and skipped. Everything else counts as non-photo.
- **Metadata read:** `CGImageSourceCopyPropertiesAtIndex` only, with no decode. It reads DateTimeOriginal (plus OffsetTimeOriginal), Model, pixel size, orientation and colour model.
- **Sort order:** capture date, then relative path (localized standard compare).
- **Budget:** ≥ 500 files/s on internal SSD **[B]**.

**Default output folder:** `<parent of the first source root>/{wedding} – Deliveries`. The output folder can never be inside a source root (preflight blocks it).

**OutputWriter** is the only code in the app that writes into delivery folders:
1. **Source protection.** Realpath and (device, inode) of the target are compared with the set of every source file and every source root. Writing to any of them, or below a source root, throws `.wouldTouchSource`. Regression tests cover symlinks, case variants (APFS is case-insensitive) and hard links.
2. **Staging.** Each file is written to `<deliveryDir>/.holdmybyte-partial/<UUID>.tmp` (`O_CREAT|O_EXCL`), then moved with `renamex_np(tmp, final, RENAME_EXCL)`. On `EEXIST`, it retries with " 2", " 3", and so on.
3. **Folder names.** The delivery root folder gets " 2" if it exists, except in Create-More mode. The partial directory is removed when the job finishes.
4. **File names.**
   - Renaming on: `{wedding}-{number}`. The slug replaces whitespace with "-" and removes `/:\`. `{number}` is zero-padded to max(4, digits(count)), in capture order.
   - Renaming off: the original base name.
   - The extension comes from the delivery format: `.jpg`, `.webp`, `.jxl`.

**Journal:** `~/Library/Application Support/holdmybyte/Jobs/<weddingID>/request.json` plus `journal.jsonl`.
- One `PhotoResult` is appended per (photo, delivery) after the rename, with `fsync` every 10 lines and at pause.
- `finished` is written last.

**Resume:**
- A (photo, delivery) is skipped when its journal entry exists **and** the output file exists with `size == outBytes`. Everything else is redone.
- A crash loses at most the photos that were in flight.

**Pause and stop:**
- Cancellation is cooperative, checked before every probe and every write. The in-flight probe is abandoned and its `.tmp` deleted.
- Pause latency **[B]**: under 1.5 s.

**Error mapping:**

| Error | Result |
|---|---|
| `ENOSPC` | `.paused(.diskFull(volume, needed: remaining estimate))` |
| `EACCES` / `EROFS` on output | `.paused(.outputNotWritable(path))` |
| read failure while the source volume is unmounted | `.paused(.sourceUnavailable(volume))` |
| read failure while the volume is present | that photo `.failed(.unreadable)` |

**Determinism:** the same inputs, settings and engine build produce byte-identical outputs. JPEG and WebP encoders run single-threaded per image; libjxl runs on up to 4 threads with thread-count-independent output; there is no randomness and no time-dependent state. The codec archive itself is reproducible (§3.13).

**Events:** results are coalesced and emitted at most 10× per second. `JobProgress` is emitted at least once per second while running.

### 3.9 Concurrency model

- **Workers:** dedicated `Thread`s (stack 8 MB) pull photo indices from a locked FIFO. They never block the Swift cooperative pool, which only sees `AsyncStream` and continuations.
- **Worker count:**
  - `.automatic` = clamp(activeProcessorCount − 2, 2…8), QoS `.userInitiated`.
  - `.gentle` = 2, QoS `.utility`.
- **One `MetricLane`:**
  - It serialises full-resolution GPU work on one `MTLCommandQueue`; workers block on it from their own thread. *As
    built (D-ENG-11):* mosaic and ≤ 3 MP scores run outside the lane lock on pooled per-caller working sets.
  - *As built (D-ENG-10):* references above 3 MP are **deferred**: the handle keeps the caller's pixels and each
    score rebuilds the GPU pyramid inside the lane (bit-identical scores, ~35 ms per 45 MP score); Metal pools are
    keyed orientation-free with a 2 GB LRU. Full-size searches take a slot (count from the memory plan, else 3), and at
    most 2 full-size decodes run at once.
- **Archive** jobs run on the same workers. *As built (D-ENG-10):* a photo's archive is its own work item, at most
  `MemoryPlan.archiveLanes` at once while lossy work is queued.
- **Memory plan (D-ENG-10):** a per-pixel model of the largest photo (base 0.3 GB, metric pools 32 B/px, archive
  30 B/px, lossy worker 6 B/px + 6 B/px per full-size search) against min(8 GB, RAM/2) sets workers, archive lanes and
  full-size slots (45 MP, 8 processor workers → 7 workers, 3 lanes). Large buffers come from mappings and per-call
  arenas, not malloc; `hmb` and the app run with `MallocLargeCache=0`.
- **Memory budget [B]:** peak RSS ≤ 8 GB at 8 workers on 45 MP input. *[M] as built:* wedding, all four, 7.18 GB RSS /
  7.42 GB footprint (D-ENG-10); Couple-only jobs 5.2–6.0 GB footprint (D-ENG-11).

### 3.10 Estimates

- **Sample:** S = min(12, n) photos at indices ⌊(i + 0.5)·n/S⌋ in capture order. Decoding and features run on the real photos.

**Per-delivery estimate rules:**

| Delivery kind | Estimate |
|---|---|
| Full-size lossy | Proxy curve only (no full probes): d* = exp(inv(G)), then the mosaic is encoded at d* (tuned, level 2). Estimate = mosaicBytes × (W·H / mosaicPixels) × κ_full + marker bytes. *As built:* G = T + 0.03 − (−1.1) = T + 1.13 for `.mosaicExact` (T + M0 − BIAS for `.proxyCurve`). Full-size WebP: the mosaic at qPrior. |
| Resized lossy | *As built (D-ENG-4):* the delivery's **real DirectSearch** on the sample's variant (WebP with its JPEG fallback, JPEG with the 4:4:4-first rule and the decoder guard); the post-pass is not modelled. Estimate = best passing bytes × κ_resized. (Was: one probe at the prior, which missed by 30–45 %.) |
| Archive | 0.78 × JPEG source bytes + 1.0 × other source bytes. |

- **Totals** are scaled by n/S. The result is `DeliveryEstimate(bytes:, fractionOfSource:, secondsPerPhoto:)`.
- **κ:**
  - κ starts as constants fitted by WP2 on the holdout (median actual/estimate) and recorded in `Docs/ENGINE.md`. *As built:* all κ defaults are 1.0 (holdout actual/estimate 0.998–1.010).
  - After every finished job, the ratio of actual to estimated bytes per delivery kind is folded into a learned κ with an exponential moving average (α = 0.3), stored in UserDefaults. "Reset Learned Estimates" clears it.
- **Time:** `secondsPerPhoto` comes from the per-delivery-kind EMA of measured wall seconds per photo on this Mac. The defaults are the budgets in §3.11.
- **[B]:** ≤ 5 s for the default deliveries on 45 MP input, and the totals must be within ±15 % of actual (gate G7).

### 3.11 Performance budget (M1 Max, 10 cores, 64 GB, quiet machine: 1-minute load < 3 before start)

| Item | Value | Tag / source |
|---|---|---|
| ImageIO decode, 45 MP JPEG → RGBA8 | 0.10 s + 0.012 s blit | M today (`bench/iio`) |
| libjpeg-turbo decode, 45 MP (not used) | 0.28–0.30 s | M today (`bench/dec`) |
| vImage resize 8256×5504 → 2560 (high quality) | 0.10 s | M today (`bench/rs`) |
| jpegli encode, 45 MP, p2 / p0 (CLI incl. PPM read) | 0.76 s / 0.37 s | M today |
| CPU reference SSIMULACRA2, 45 MP | 6.2 s | M today; never in the hot path |
| Metal fused-pass bandwidth model, 45 MP, 6 scales | 0.39 s | M today (`gpubench`) |
| **GPU score per 45 MP candidate with cached reference** | **≤ 0.40 s (stretch 0.25)** | **B (WP1 gate)** |
| GPU reference preparation, 45 MP | ≤ 0.20 s | B |
| Full probes per full-size photo | mean 2.0, max 3 (+2 rescue) | S (`sim-B`) |
| JXL transcode + reconstruct, 45 MP, 1 thread | 1.90 s + 1.16 s | M today |
| WebP 2560 encode, m4, sharp YUV | ≤ 0.52 s | M today |
| **Couple’s Package (Balanced), 535 × 45 MP** | **≤ 10 min (≤ 1.12 s/photo)**; old engine 17.4 min; JPEGmini 3.8 min | B; DATENLAGE §8 / §7 |
| Website alone, 535 photos | ≤ 2.5 min (old 3.7) | B |
| Archive alone, 535 photos | ≤ 6 min (old 11.3) | B |
| **All four deliveries, one pass, 535 photos** | **≤ 14 min** (old: four runs, 39.5 min in total) | B |
| Setup visible after drop | ≤ 100 ms; scan ≥ 500 files/s | B |
| Estimates | ≤ 5 s | B |
| Compare first frame / full-resolution pair | ≤ 150 ms / ≤ 600 ms | B |
| History Done view load, 2000 photos | ≤ 100 ms | B |

Honest framing:
- The Balanced pipeline is GPU-bound: about 2.0 × 0.40 s + 0.20 s ≈ 1.0 GPU-s per photo, against about 1.9 CPU-s spread across 8 workers.
- JPEGmini (0.42 s/photo) stays faster. v2's claim is **about 2× faster than the old engine, 43–75 % smaller than JPEGmini, and every photo verified.**
- The website, README and UI never claim parity with JPEGmini's speed.

### 3.12 Guarantees (each one has a test; see WP2 and WP1)

1. **Originals are never opened for writing.** The only write path is `OutputWriter`, and it refuses source files, source roots and anything below them.
2. **Lossy deliveries.** Every lossy file has `score ≥ target`, measured by the engine's metric on the decoded **delivered bytes** against the (resized or converted) source variant. The score is stored per file. *As built (D-ENG-12):* "decoded" means ImageIO and, for 4:4:4 JPEGs, also libjpeg-turbo's pixels (browsers); the stored score is the lower reading. 4:2:0 JPEGs read higher in libjpeg-turbo than in ImageIO, and ImageIO's WebP pixels are libwebp's (`DecoderAuditTests`).
3. **Full-size JPEG deliveries are complete.** A photo is missing only on read, encode or write errors, which are listed. When compression can't win, the original is kept.
4. **The archive is byte-exact.** Every `.jxl` reconstructs to the identical source bytes (verified for each file before it is counted).
5. **Determinism:** byte-identical outputs on reruns.
6. **Resume** never re-delivers or duplicates a finished file and never leaves a `.tmp` behind after a finished job.
7. **No network:** the binary links no networking frameworks beyond those Foundation pulls in, makes no URLSession use, and passes an `nm`/`otool` audit in CI. There is no telemetry.

### 3.13 Codec vendoring plan

**Pins** (verified against upstream today with `git ls-remote`):

| Library | Tag | Commit | Provides |
|---|---|---|---|
| libjxl | `v0.11.2` | `332feb17d17311c748445f7ee75c4fb55cc38530` | libjxl, libjxl_cms, libjxl_threads, **jpegli** (`lib/jpegli`, present in v0.11.x, removed in v0.12.0), plus submodules highway, brotli, skcms, and libjpeg-turbo (headers only, needed to configure jpegli) |
| libwebp | `v1.6.0` | `4fa21912338357f89e4fd51cf2368325b59e9bd9` | libwebp, libsharpyuv, libwebpmux |

Not vendored: mozjpeg, libjpeg-turbo libraries, libavif, libaom, lcms2, libpng.

**`Scripts/build-codecs.sh` outline** (idempotent; bash, `set -euo pipefail`, every path quoted, no word splitting):

```bash
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; WORK="${HMB_CODEC_WORK:-$ROOT/.codec-build}"
source "$ROOT/Vendor/codecs.lock"          # LIBJXL_TAG, LIBJXL_COMMIT, LIBWEBP_TAG, LIBWEBP_COMMIT, OUTPUT_SHA256
[ "$(shasum -a 256 "$ROOT/Vendor/xcframeworks/HMBCodecs.xcframework/macos-arm64/libhmbcodecs.a" 2>/dev/null | cut -d' ' -f1)" = "$OUTPUT_SHA256" ] && exit 0
fetch() { git clone --depth 1 --branch "$2" "$1" "$3"; [ "$(git -C "$3" rev-parse HEAD)" = "$4" ] || die "pin mismatch $3"; }
fetch https://github.com/libjxl/libjxl.git "$LIBJXL_TAG" "$WORK/libjxl" "$LIBJXL_COMMIT"
git -C "$WORK/libjxl" submodule update --init --recursive --depth 1
fetch https://github.com/webmproject/libwebp.git "$LIBWEBP_TAG" "$WORK/libwebp" "$LIBWEBP_COMMIT"
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_FIND_FRAMEWORK=NEVER
        "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local")
cmake -S "$WORK/libjxl" -B "$WORK/jxl-build" "${COMMON[@]}" -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_JPEGLI=ON
      -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF
      -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF
      -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF
cmake --build "$WORK/jxl-build"
cmake -S "$WORK/libwebp" -B "$WORK/webp-build" "${COMMON[@]}" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF
      -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF
      -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_USE_THREAD=ON
cmake --build "$WORK/webp-build"
# as built: Vendor/patches/<lib>/*.patch are applied (idempotent; each keeps the codec's output byte-identical)
libtool -static -o "$WORK/libhmbcodecs.a" <every .a listed in Scripts/codec-libs.txt, resolved under the two build dirs>
# as built (D-ENG-12): ZERO_AR_DATE=1, then every ar member header normalised to uid 0, gid 0, mode 100644 (libtool
# copies the user, the build directory's group and the umask into them), so any checkout builds the locked bytes
# audits (fail the script): no exported _jpeg_* symbols; no /opt/homebrew or /usr/local in any load command or string table
nm -gU "$WORK/libhmbcodecs.a" | grep -E ' _jpeg_' && die "libjpeg API exported"
# as built: SHA-256 ≠ OUTPUT_SHA256 → fail, install nothing (unless --update-lock, the only way the lock changes)
rm -rf "$ROOT/Vendor/xcframeworks/HMBCodecs.xcframework"
xcodebuild -create-xcframework -library "$WORK/libhmbcodecs.a" -output "$ROOT/Vendor/xcframeworks/HMBCodecs.xcframework"
# headers listed in Scripts/codec-headers.txt (jxl/*.h incl. generated jxl/version.h + export headers, lib/jpegli/{common,encode,types}.h
# with their include layout preserved, jpeglib.h/jmorecfg.h/jconfig.h from the jxl build tree, webp/{encode,mux,mux_types,types,decode}.h)
copy_headers "$ROOT/Sources/CHMBCodecs/vendor-include"
finish   # installed SHA-256 == built; with --update-lock, write OUTPUT_SHA256
```

**How SwiftPM consumes this without `unsafeFlags`:**
- `.binaryTarget(name: "HMBCodecsBinary", path: "Vendor/xcframeworks/HMBCodecs.xcframework")`: an XCFramework of one static library, with no headers.
- `CHMBCodecs` is a C++17 target with `cxxSettings: [.headerSearchPath("vendor-include"), .define("JXL_STATIC_DEFINE"), .define("JXL_THREADS_STATIC_DEFINE"), .define("JXL_CMS_STATIC_DEFINE")]` and `linkerSettings: [.linkedLibrary("c++")]`. All of these are safe settings.
- Swift sees only `Sources/CHMBCodecs/include/hmb_codecs.h`, a plain C API. `setjmp`/`longjmp` for jpegli errors stays inside the `.cc` file.

**Git and worktrees:**
- `Vendor/xcframeworks/` and `Sources/CHMBCodecs/vendor-include/` are git-ignored. `Vendor/codecs.lock`, `Scripts/codec-libs.txt` and `Scripts/codec-headers.txt` are committed.
- In a worktree, `Scripts/link-codecs.sh <main-checkout>` copies both directories with `cp -cR` (an APFS clone, instant), so the build runs once per machine.

**Equivalence check (part of the WP1 tests):**
- In-process jpegli (libjxl v0.11.2) at d ∈ {1.6, 2.0} on the 6 sample photos must match `jpegos/Vendor/bin/cjpegli` (google/jpegli, used in every experiment): sizes within ±1.0 % and scores within ±0.2.
- If the check fails, WP1 reports it. The lead then switches the pin to google/jpegli `031a0077f5799a6041004267fc12b956c1f52a20` built against libjxl's highway, sharing one `libhwy.a`.

**C API (`Sources/CHMBCodecs/include/hmb_codecs.h`, frozen after WP0; WP1 implements it):**

```c
#include <stddef.h>
#include <stdint.h>
typedef struct { uint8_t *data; size_t size; } hmb_buffer;          // malloc'ed; release with hmb_buffer_free
typedef struct { const uint8_t *data; size_t size; } hmb_bytes;     // borrowed
typedef struct { uint8_t code; hmb_bytes payload; } hmb_marker;
void hmb_buffer_free(hmb_buffer *b);
// All functions return 0 on success; on failure write a NUL-terminated message into err (err_len ≥ 256).
int  hmb_jpegli_encode(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                       float distance, int subsampling_444, int progressive_level,
                       const hmb_marker *markers, size_t marker_count, hmb_buffer *out, char *err, size_t err_len);
typedef struct hmb_webp_prepared hmb_webp_prepared;
int  hmb_webp_prepare(const uint8_t *rgba, uint32_t width, uint32_t height, size_t stride,
                      hmb_webp_prepared **out, char *err, size_t err_len);
int  hmb_webp_encode(const hmb_webp_prepared *p, float quality, int method,
                     hmb_bytes icc, hmb_bytes exif, hmb_bytes xmp, hmb_buffer *out, char *err, size_t err_len);
void hmb_webp_release(hmb_webp_prepared *p);
int  hmb_jxl_transcode_jpeg(const uint8_t *jpeg, size_t size, int effort, hmb_buffer *out, char *err, size_t err_len);
int  hmb_jxl_reconstruct_jpeg(const uint8_t *jxl, size_t size, hmb_buffer *out, char *err, size_t err_len);
const char *hmb_codec_versions(void);   // "libjxl 0.11.2 · jpegli (libjxl 0.11.2) · libwebp 1.6.0"
```

*As built (additive):* `hmb_jpegli_encode_opts` (tuned tables, sampling, AQ, proxy script, scan choice),
`hmb_jpegli_encode_scans`, `hmb_jpeg_optimize_scans`, `hmb_jpeg_choose_scans`, `hmb_jpeg_rewrite` (D-ENG-11),
`hmb_webp_encode_tuned`, `hmb_jxl_*_threads` (D-ENG-11), `hmb_jpeg_decode_islow` (D-ENG-12). The frozen calls are
byte-identical wrappers.

---
## 4. Repository layout

**Basics**
- **Location:** `/Users/sebastianhaas/Desktop/holdmybyte`
- **Remote:** `git@github.com:cyberm00n-ger/holdmybyte.git` (branch `main`)
- **Names:** product `holdmybyte`, bundle id `eu.sebastianhaas.holdmybyte`, CLI `hmb`
- **Toolchain:** Xcode 26 / Swift 6.2, macOS 26 SDK, arm64 only

**Hard rule: no client photos are ever committed.** Test fixtures are synthetic. Real photos are referenced only through environment variables (§5.6). `Scripts/check-repo.sh` fails on:
- any tracked file larger than 512 KB, except files under `Docs/assets/`;
- any tracked JPEG, HEIC or TIFF that carries an EXIF `Make` tag.

```
holdmybyte/
├── Package.swift                       WP0 (frozen; changes only via the lead)
├── README.md                           WP0 skeleton → WP5 fills Benchmarks section
├── .gitignore                          WP0  (.build/, .codec-build/, Vendor/xcframeworks/, Sources/CHMBCodecs/vendor-include/, Snapshots/, Benchmarks/runs/)
├── Vendor/
│   ├── codecs.lock                     WP0  (pins + output sha256)
│   └── xcframeworks/HMBCodecs.xcframework   (built, ignored)
├── Scripts/
│   ├── build-codecs.sh  codec-libs.txt  codec-headers.txt  link-codecs.sh        WP0
│   ├── bundle-app.sh  make-icon.sh  snapshot.sh  bench.sh  check-repo.sh  notarize.sh   WP5
├── Sources/
│   ├── CHMBCodecs/       include/hmb_codecs.h (WP0) · jpegli.cc, webp.cc, jxl.cc, buffer.cc (WP1) · vendor-include/ (generated)
│   ├── HMBModel/         WP0  (shared types, §5.0 — frozen)
│   ├── HMBEngine/
│   │   ├── Interfaces/   WP0  (Primitives.swift §3.2, Primitives+Fakes.swift — frozen)
│   │   ├── Codecs/  Imaging/  Metric/                                   WP1
│   │   └── Search/  Pipeline/  Jobs/  IO/  Metadata/  Estimate/  Service/   WP2
│   ├── HMBStore/         WP4  (history JSON, presets, settings, thumbnail cache)
│   ├── HMBFixtures/      WP0  (domain fixtures, FixtureEngine, in-memory stores, synthetic thumbnails)
│   ├── HMBUI/
│   │   ├── Design/       WP0  (Tokens.swift, Glass.swift — frozen)
│   │   ├── State/        WP0 AppState.swift (frozen) · WP3 AppModel.swift · WP4 AppModel+Compare.swift, AppModel+Settings.swift
│   │   ├── Shell/ Drop/ Setup/ Run/ MenuBar/ Components/ Alerts/        WP3
│   │   └── Compare/ Settings/ EditDelivery/                             WP4
│   ├── HoldMyByteApp/    WP3  (@main, AppDelegate, AppCommands, AppModel.live(), Dock, notifications)
│   ├── HMBBench/         WP5  (library: bench runner, reports, baselines)
│   ├── hmb/              WP5  (CLI executable)
│   └── HMBSnapshot/      WP5  (snapshot harness executable + state catalogue)
├── Tests/
│   ├── HMBModelTests/                      WP0
│   ├── HMBEngineTests/Primitives/          WP1
│   ├── HMBEngineTests/Pipeline/            WP2
│   ├── HMBStoreTests/                      WP4
│   ├── HMBUITests/AppModel/                WP3
│   ├── HMBUITests/Compare/                 WP4
│   ├── HMBBenchTests/                      WP5
│   └── Fixtures/                           WP0 (synthetic only: generated gradients/patterns, ≤ 256 KB each)
├── Docs/
│   ├── SPEC.md                             lead (this file)
│   ├── ENGINE.md                           WP2 (search, constants, fits; WP1 contributes via PR comment, lead pastes)
│   ├── METRIC.md                           WP1 (port notes, validation tables)
│   ├── BENCHMARKS.md                       WP5
│   └── SNAPSHOTS.md                        WP5
├── Benchmarks/
│   ├── baselines.json                      WP5 (old engine + JPEGmini numbers from DATENLAGE, holdout per-file old bytes)
│   └── runs/                               generated, ignored (selected reports copied into Docs/BENCHMARKS.md)
└── Snapshots/                              generated, ignored
```

### 4.1 `Package.swift` (written by WP0, verbatim)

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "holdmybyte",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "holdmybyte", targets: ["HoldMyByteApp"]),
        .executable(name: "hmb", targets: ["hmb"]),
        .executable(name: "hmb-snapshot", targets: ["HMBSnapshot"]),
    ],
    targets: [
        .binaryTarget(name: "HMBCodecsBinary", path: "Vendor/xcframeworks/HMBCodecs.xcframework"),
        .target(
            name: "CHMBCodecs",
            dependencies: ["HMBCodecsBinary"],
            cxxSettings: [
                .headerSearchPath("vendor-include"),
                .define("JXL_STATIC_DEFINE"), .define("JXL_THREADS_STATIC_DEFINE"), .define("JXL_CMS_STATIC_DEFINE"),
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(name: "HMBModel"),
        .target(name: "HMBEngine", dependencies: ["HMBModel", "CHMBCodecs"]),
        .target(name: "HMBStore", dependencies: ["HMBModel"]),
        .target(name: "HMBFixtures", dependencies: ["HMBModel"]),
        .target(name: "HMBUI", dependencies: ["HMBModel", "HMBFixtures"]),
        .executableTarget(name: "HoldMyByteApp", dependencies: ["HMBUI", "HMBEngine", "HMBStore", "HMBModel"]),
        .target(name: "HMBBench", dependencies: ["HMBEngine", "HMBModel"]),
        .executableTarget(name: "hmb", dependencies: ["HMBBench", "HMBEngine", "HMBModel"]),
        .executableTarget(name: "HMBSnapshot", dependencies: ["HMBUI", "HMBFixtures", "HMBModel"]),
        .testTarget(name: "HMBModelTests", dependencies: ["HMBModel"]),
        .testTarget(name: "HMBEngineTests", dependencies: ["HMBEngine", "HMBModel", "HMBFixtures"]),
        .testTarget(name: "HMBStoreTests", dependencies: ["HMBStore", "HMBModel", "HMBFixtures"]),
        .testTarget(name: "HMBUITests", dependencies: ["HMBUI", "HMBModel", "HMBFixtures"]),
        .testTarget(name: "HMBBenchTests", dependencies: ["HMBBench", "HMBModel"]),
    ],
    cxxLanguageStandard: .cxx17
)
```

Notes on `Package.swift`:
- Swift 6 language mode is the default for tools-version 6.2.
- There is no `unsafeFlags` anywhere. CI greps for it.
- Metal shaders are Swift string literals, compiled once at runtime and cached, because `swift build` does not compile `.metal` files.
- There are no SwiftPM resources in v1.

### 4.2 App bundle (`Scripts/bundle-app.sh`, WP5)

1. Run `swift build -c release`, then assemble `build/holdmybyte.app`:
   ```
   Contents/MacOS/holdmybyte
   Contents/Helpers/hmb              (Helpers, never MacOS/: lesson of the case-insensitive overwrite)
   Contents/Resources/AppIcon.icns   (Scripts/make-icon.sh)
   Contents/Info.plist
   ```
2. **Info.plist:**
   - `CFBundleIdentifier`: `eu.sebastianhaas.holdmybyte`
   - `LSMinimumSystemVersion`: `26.0`
   - `CFBundleDocumentTypes`: folders and public.image, role Viewer, so the app accepts drops on the Dock icon.
   - `NSHumanReadableCopyright`
3. **Signing:**
   - Developer builds are signed ad hoc (`codesign -s -`).
   - `Scripts/notarize.sh` outlines Developer ID signing with Hardened Runtime and `notarytool`. The owner runs it with his own credentials.
4. **Audits.** The script fails if:
   - any Mach-O in the bundle references `/opt/homebrew` or `/usr/local` (`otool -L`);
   - any dylib other than system libraries is loaded.

---

## 5. Work split

There are five engineers in separate git worktrees, with no overlapping files. The lead does **WP0** first, merges it to `main`, and pushes. Only then do WP1–WP5 branch off.

Ownership is by path (§4). A file you do not own is read-only for you. If you need a change in a frozen file, write it as a question in your PR. The lead decides and lands it on `main`, and you rebase.

**Worktrees:**
```bash
git -C ~/Desktop/holdmybyte worktree add ../holdmybyte-wp1 -b wp1-codecs-metric
git -C ~/Desktop/holdmybyte worktree add ../holdmybyte-wp2 -b wp2-pipeline
git -C ~/Desktop/holdmybyte worktree add ../holdmybyte-wp3 -b wp3-app-flow-ui
git -C ~/Desktop/holdmybyte worktree add ../holdmybyte-wp4 -b wp4-compare-settings-store
git -C ~/Desktop/holdmybyte worktree add ../holdmybyte-wp5 -b wp5-harness-cli-bench
# then, in each worktree, before the first build:
Scripts/link-codecs.sh ~/Desktop/holdmybyte
```

**Merge order:** WP1 → WP2 → WP4 → WP3 → WP5. Any order compiles, but this order gives the best integration signal. The lead runs §6 after each merge. Commits end with the attribution lines required by the harness.

### 5.0 WP0: scaffold and shared types (lead, lands first)

**Owns:**
- `Package.swift`, `.gitignore`, `README.md` (skeleton)
- `Vendor/codecs.lock`, `Scripts/build-codecs.sh`, `codec-libs.txt`, `codec-headers.txt`, `link-codecs.sh`
- `Sources/CHMBCodecs/include/hmb_codecs.h`
- `Sources/HMBModel/**`, `Sources/HMBEngine/Interfaces/**`, `Sources/HMBFixtures/**`
- `Sources/HMBUI/Design/**`, `Sources/HMBUI/State/AppState.swift`
- stub files handed over on merge (listed below)
- `Tests/HMBModelTests/**`, `Tests/Fixtures/**`

**Deliverables:**
1. The codecs build and link, and `swift build` succeeds from a clean clone after `Scripts/build-codecs.sh`. The CHMBCodecs `.cc` files are WP1's; WP0 ships stub bodies that return an error, so everything links.
2. Every shared type below exists verbatim and compiles in Swift 6 language mode with zero warnings.
3. `EnginePrimitives.fakes()` (deterministic fakes) is in place:
   - Fake JPEG/WebP "encoders" store raw RGBA with a header and quantise the pixels by step = round(distance × 4) (JPEG) or (100 − q)/8 (WebP). Their output size is a deterministic function of the step.
   - The fake metric is `100 − 2.5 × RMSE`.
   - The fake JXL transcoder is an identity with a 4-byte magic.
4. `HMBFixtures`, with these pieces:
   - **Records:** `Fixtures.finnUndLissy` (535 photos, 4 deliveries) and `Fixtures.annaUndBen` (412 photos, queued). The Finn und Lissy totals match DATENLAGE §8: Couple 1.35 GB with scores 74.0–76.2 (median 74.5); Website 159 MB, ≥ 70; Social 155 MB, ≥ 85; Archive 8.55 GB, 535 byte-exact.
   - **History:** `Fixtures.history` (38 weddings across 14 months, 1.24 TB saved).
   - **Inputs:** `Fixtures.scanResult` and `Fixtures.estimates`.
   - **Issue variants:** `Fixtures.withIssues(_:)` (2 unreadable, 1 encode failure on Website) and `Fixtures.keptOriginal(7)`.
   - **`FixtureEngine: EngineService`:** scripted streams that replay a job at a configurable speed.
   - **In-memory stores:** `InMemoryHistory`, `InMemoryPresets`, `InMemorySettings`.
   - **`FixtureThumbnails: ThumbnailProviding`:** deterministic synthetic "photo-like" images (seeded warm gradients with soft shapes). If `HMB_FIXTURE_PHOTOS` points at a local folder, it cycles through real JPEG thumbnails from there instead.
5. `Tokens.swift` and `Glass.swift` implement §2.5 exactly. `.hmbGlass(_:in:)` falls back to `.regularMaterial` when `EnvironmentValues.isSnapshotRendering` is `true`.
6. **Stubs** that compile, each handed to its owner on merge:

   | Stub | New owner |
   |---|---|
   | `HMBUI/State/AppModel.swift` | WP3 |
   | `HMBUI/State/AppModel+Compare.swift` | WP4 |
   | `HMBUI/State/AppModel+Settings.swift` | WP4 |
   | `HMBUI/Shell/RootView.swift` | WP3 |
   | `HMBUI/MenuBar/StatusMenu.swift` | WP3 |
   | `HMBUI/Compare/CompareView.swift` | WP4 |
   | `HMBUI/Settings/SettingsView.swift` | WP4 |
   | `HoldMyByteApp/HoldMyByteApp.swift` | WP3 |
   | `hmb/main.swift` | WP5 |
   | `HMBSnapshot/main.swift` | WP5 |
   | `HMBEngine/Service/LiveEngine.swift` | WP2 |
   | `HMBEngine/Interfaces/Primitives+Live.swift` | WP1 (the `EnginePrimitives.live()` body) |

7. `Tests/HMBModelTests` cover: preset validation rules, `specLine`, `DeliverySummary.make`, `HMBFormat` copy (every row of the S8 ETA table, byte and percent formatting in `en_US` and `en_DE`), Codable round-trips of every type, and name inference plus the generic-name list.

**Acceptance:**
- `swift build` and `swift test` are green.
- `Scripts/check-repo.sh` is green (WP0 writes a minimal version; WP5 extends it).
- `nm` shows no `_jpeg_` exports.
- The scaffold is pushed to `main` on GitHub.

#### 5.0.1 Shared types, verbatim (`Sources/HMBModel/`)

Signatures and stored properties are verbatim. Bodies shown as `/* WP0 implements */ fatalError()` are implemented by WP0 according to the comment above each one, before merge.

```swift
// ───────────── IDs.swift ─────────────
import Foundation

public struct WeddingID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
    public var id: UUID { uuid }
    public var description: String { uuid.uuidString }
}

/// Index of a photo in its wedding's capture-time order (0-based). Stable for the life of a record.
public struct PhotoID: Hashable, Codable, Sendable, Comparable {
    public let index: Int
    public init(_ index: Int) { self.index = index }
    public static func < (l: PhotoID, r: PhotoID) -> Bool { l.index < r.index }
}

public struct DeliveryID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let couple  = DeliveryID(rawValue: "couple")
    public static let website = DeliveryID(rawValue: "website")
    public static let social  = DeliveryID(rawValue: "social")
    public static let archive = DeliveryID(rawValue: "archive")
    public static func newCustom() -> DeliveryID { DeliveryID(rawValue: "custom-" + UUID().uuidString.lowercased()) }
}

// ───────────── Delivery.swift ─────────────
public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    case jpeg, webp, jxlLossless
    public var fileExtension: String { switch self { case .jpeg: "jpg"; case .webp: "webp"; case .jxlLossless: "jxl" } }
    public var displayName: String { switch self { case .jpeg: "JPEG"; case .webp: "WebP"; case .jxlLossless: "JPEG XL" } }
}

public enum OutputSize: Codable, Sendable, Hashable {
    case full
    case longEdge(Int)                       // 400...12000
    public var longEdge: Int? { if case .longEdge(let px) = self { px } else { nil } }
}

public enum QualityLevel: String, Codable, Sendable, CaseIterable {
    case highest, high, balanced, web, lossless
    /// Fixed SSIMULACRA2 floor (engine scale). nil: per-photo target (balanced) or byte-exact (lossless).
    public var floor: Double? { switch self { case .highest: 90; case .high: 85; case .web: 70; case .balanced, .lossless: nil } }
    public var displayName: String {
        switch self { case .highest: "Highest"; case .high: "High"; case .balanced: "Balanced"; case .web: "Web"; case .lossless: "Lossless" }
    }
    public var levelDescription: String {
        switch self {
        case .highest:  "Visually lossless, even when you flick between both at 100 %. For albums and print."
        case .high:     "Indistinguishable from the original at normal viewing; only a flicker test at 100 % can reveal it."
        case .balanced: "Adapts to each photo: detailed scenes keep more, smooth scenes give more. The quality clients are used to, at a fraction of the size."
        case .web:      "High quality on screens. For resized website and social images."
        case .lossless: "Byte-exact: every file restores to the identical original."
        }
    }
}

public enum ColourHandling: String, Codable, Sendable { case keepProfile, convertToSRGB }
public enum MetadataPolicy: String, Codable, Sendable { case keepAll, removeLocation, removeAll }
public enum ChromaSubsampling: String, Codable, Sendable { case s420 = "4:2:0", s444 = "4:4:4" }

public struct DeliveryPreset: Identifiable, Codable, Sendable, Hashable {
    public var id: DeliveryID
    public var name: String
    public var symbol: String
    public var format: OutputFormat
    public var size: OutputSize
    public var quality: QualityLevel
    public var colour: ColourHandling
    public var metadata: MetadataPolicy
    public var folderName: String
    public var isBuiltIn: Bool

    public init(id: DeliveryID, name: String, symbol: String, format: OutputFormat, size: OutputSize,
                quality: QualityLevel, colour: ColourHandling, metadata: MetadataPolicy,
                folderName: String, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.symbol = symbol; self.format = format; self.size = size
        self.quality = quality; self.colour = colour; self.metadata = metadata
        self.folderName = folderName; self.isBuiltIn = isBuiltIn
    }

    public var isFullSize: Bool { size == .full }
    public var isLossy: Bool { format != .jxlLossless }

    /// nil when valid. Rules (each returns the quoted message):
    /// jxlLossless ⇔ quality == .lossless, and then size == .full, colour == .keepProfile, metadata == .keepAll
    ///   → "JPEG XL deliveries are lossless, full size and keep everything."
    /// quality == .balanced ⇒ format == .jpeg && size == .full → "Balanced is available for full-size JPEG only."
    /// longEdge ∈ 400...12000 → "Long edge must be between 400 and 12000 px."
    /// name, folderName non-empty after trimming; folderName contains none of "/:" → "Enter a name and a folder name."
    public var validationError: String? { /* WP0 implements exactly the rules above */ fatalError() }

    /// Built-ins return their fixed spec lines (§2.6). Custom: "<size> · <format> · <quality>" + " · sRGB" if converted
    /// + " · location removed" / " · metadata removed". Size text: "Full size" or "2560 px". Lossless: "Lossless · JPEG XL · byte-exact".
    public var specLine: String { /* WP0 implements */ fatalError() }

    public static let builtIns: [DeliveryPreset] = [
        DeliveryPreset(id: .couple, name: "Couple’s Package", symbol: "heart", format: .jpeg, size: .full,
                       quality: .balanced, colour: .keepProfile, metadata: .keepAll, folderName: "Couple", isBuiltIn: true),
        DeliveryPreset(id: .website, name: "Website", symbol: "globe", format: .webp, size: .longEdge(2560),
                       quality: .web, colour: .convertToSRGB, metadata: .removeLocation, folderName: "Website", isBuiltIn: true),
        DeliveryPreset(id: .social, name: "Social & Blog", symbol: "square.grid.3x3", format: .jpeg, size: .longEdge(1440),
                       quality: .high, colour: .convertToSRGB, metadata: .removeLocation, folderName: "Social", isBuiltIn: true),
        DeliveryPreset(id: .archive, name: "Archive", symbol: "archivebox", format: .jxlLossless, size: .full,
                       quality: .lossless, colour: .keepProfile, metadata: .keepAll, folderName: "Archive", isBuiltIn: true),
    ]
    public static let defaultOnIDs: [DeliveryID] = [.couple, .website]
}

// ───────────── Source.swift ─────────────
public enum SourceKind: String, Codable, Sendable { case jpeg, heic, png, tiff }

public struct SourcePhoto: Identifiable, Codable, Sendable, Hashable {
    public var id: PhotoID
    public var url: URL
    public var relativePath: String          // relative to its source root
    public var byteCount: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var captureDate: Date?
    public var camera: String?
    public var kind: SourceKind
    public var modified: Date
    public init(id: PhotoID, url: URL, relativePath: String, byteCount: Int64, pixelWidth: Int, pixelHeight: Int,
                captureDate: Date?, camera: String?, kind: SourceKind, modified: Date) {
        self.id = id; self.url = url; self.relativePath = relativePath; self.byteCount = byteCount
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.captureDate = captureDate
        self.camera = camera; self.kind = kind; self.modified = modified
    }
}

public enum NoticeSeverity: String, Codable, Sendable { case info, warning, block }

public enum ScanNotice: Codable, Sendable, Hashable {
    case skippedNonPhotos(count: Int, extensions: [String])
    case skippedRaw(count: Int)
    case cmyk(count: Int)
    case alreadyCompressed(count: Int, of: Int)
    case holdMyByteOutput(count: Int)
    case convertedToJPEG(count: Int)
    case outputFolderExists(existing: String, used: String)
    case notEnoughSpace(volume: String, needed: Int64, available: Int64)
    case notWritable(volume: String)
    case outputInsideSource
    public var severity: NoticeSeverity {
        switch self {
        case .skippedNonPhotos, .skippedRaw, .convertedToJPEG, .outputFolderExists: .info
        case .cmyk, .alreadyCompressed, .holdMyByteOutput: .warning
        case .notEnoughSpace, .notWritable, .outputInsideSource: .block
        }
    }
}

public struct ScanResult: Codable, Sendable, Hashable {
    public var photos: [SourcePhoto]         // capture order; ids are 0..<count
    public var sourceRoots: [URL]
    public var suggestedName: String
    public var weddingDate: Date?
    public var camera: String?               // most frequent Model
    public var totalBytes: Int64
    public var rawCount: Int
    public var notices: [ScanNotice]
    public init(photos: [SourcePhoto], sourceRoots: [URL], suggestedName: String, weddingDate: Date?,
                camera: String?, totalBytes: Int64, rawCount: Int, notices: [ScanNotice]) {
        self.photos = photos; self.sourceRoots = sourceRoots; self.suggestedName = suggestedName
        self.weddingDate = weddingDate; self.camera = camera; self.totalBytes = totalBytes
        self.rawCount = rawCount; self.notices = notices
    }
}

public enum ScanUpdate: Sendable {
    case progress(found: Int)
    case finished(ScanResult)
}

/// Generic folder names (case-insensitive) that defer to the parent folder's name.
public enum WeddingNaming {
    public static let genericFolderNames: Set<String> = ["export", "exports", "final", "finals", "fertig", "jpg", "jpeg",
        "jpgs", "selects", "edited", "bearbeitet", "output", "delivery", "lieferung", "web", "highres", "full"]
    /// Applies the rule in §2.4 S4. `folders` = dropped folders (or the common parent of dropped files).
    public static func suggestedName(for folders: [URL]) -> String { /* WP0 */ fatalError() }
    /// "Finn und Lissy" → "Finn-und-Lissy" (whitespace → "-", removes / : \)
    public static func slug(_ name: String) -> String { /* WP0 */ fatalError() }
}

// ───────────── Job.swift ─────────────
public enum ProcessorUse: String, Codable, Sendable { case automatic, gentle }

public struct NamingScheme: Codable, Sendable, Hashable {
    public var renameByCaptureTime: Bool
    public var pattern: String               // tokens {wedding}, {number}
    public init(renameByCaptureTime: Bool, pattern: String) { self.renameByCaptureTime = renameByCaptureTime; self.pattern = pattern }
    public static let `default` = NamingScheme(renameByCaptureTime: true, pattern: "{wedding}-{number}")
}

public struct JobRequest: Codable, Sendable, Hashable {
    public var wedding: WeddingID
    public var name: String
    public var photos: [SourcePhoto]
    public var sourceRoots: [URL]
    public var deliveries: [DeliveryPreset]  // snapshot, UI order
    public var outputFolder: URL             // as resolved by preflight
    public var naming: NamingScheme
    public var processorUse: ProcessorUse
    public var onlyPhotos: Set<PhotoID>?     // retry subset; nil = all
    public var appendToExistingFolder: Bool  // Create More Deliveries
    public init(wedding: WeddingID, name: String, photos: [SourcePhoto], sourceRoots: [URL],
                deliveries: [DeliveryPreset], outputFolder: URL, naming: NamingScheme,
                processorUse: ProcessorUse, onlyPhotos: Set<PhotoID>? = nil, appendToExistingFolder: Bool = false) {
        self.wedding = wedding; self.name = name; self.photos = photos; self.sourceRoots = sourceRoots
        self.deliveries = deliveries; self.outputFolder = outputFolder; self.naming = naming
        self.processorUse = processorUse; self.onlyPhotos = onlyPhotos; self.appendToExistingFolder = appendToExistingFolder
    }
}

public struct Preflight: Codable, Sendable, Hashable {
    public var outputFolder: URL
    public var estimatedBytes: Int64?
    public var notices: [ScanNotice]
    public var canStart: Bool { !notices.contains { $0.severity == .block } }
    public init(outputFolder: URL, estimatedBytes: Int64?, notices: [ScanNotice]) {
        self.outputFolder = outputFolder; self.estimatedBytes = estimatedBytes; self.notices = notices
    }
}

public struct DeliveryEstimate: Codable, Sendable, Hashable {
    public var bytes: Int64
    public var fractionOfSource: Double      // 0.12 means output is 12 % of the source bytes
    public var secondsPerPhoto: Double
    public init(bytes: Int64, fractionOfSource: Double, secondsPerPhoto: Double) {
        self.bytes = bytes; self.fractionOfSource = fractionOfSource; self.secondsPerPhoto = secondsPerPhoto
    }
}

public enum PhotoFailure: String, Codable, Sendable {
    case unreadable, cmykUnsupported, encodeFailed, writeFailed, sourceMissing, qualityUnreachable
    public var isRetryable: Bool { self == .encodeFailed || self == .writeFailed || self == .sourceMissing }
}

public enum PhotoStatus: Codable, Sendable, Hashable {
    case queued, working, done, keptOriginal, failed(PhotoFailure)
}

public struct PhotoResult: Codable, Sendable, Hashable {
    public var photo: PhotoID
    public var delivery: DeliveryID
    public var status: PhotoStatus
    public var score: Double?                // nil for archive and plain copies
    public var target: Double?
    public var inBytes: Int64
    public var outBytes: Int64?
    public var outRelativePath: String?      // relative to JobRequest.outputFolder, e.g. "Couple/Finn-und-Lissy-0001.jpg"
    public var outPixelWidth: Int?
    public var outPixelHeight: Int?
    public var encoder: String?              // "jpegli" | "jpegli (fallback)" | "libwebp" | "libjxl" | "copy"
    public var chroma: ChromaSubsampling?
    public var byteExact: Bool?              // archive only
    public var probes: Int
    public var seconds: Double
    public init(photo: PhotoID, delivery: DeliveryID, status: PhotoStatus, score: Double? = nil, target: Double? = nil,
                inBytes: Int64, outBytes: Int64? = nil, outRelativePath: String? = nil, outPixelWidth: Int? = nil,
                outPixelHeight: Int? = nil, encoder: String? = nil, chroma: ChromaSubsampling? = nil,
                byteExact: Bool? = nil, probes: Int = 0, seconds: Double = 0) {
        self.photo = photo; self.delivery = delivery; self.status = status; self.score = score; self.target = target
        self.inBytes = inBytes; self.outBytes = outBytes; self.outRelativePath = outRelativePath
        self.outPixelWidth = outPixelWidth; self.outPixelHeight = outPixelHeight; self.encoder = encoder
        self.chroma = chroma; self.byteExact = byteExact; self.probes = probes; self.seconds = seconds
    }
}

public struct DeliverySummary: Codable, Sendable, Hashable {
    public var delivery: DeliveryID
    public var total: Int                    // photos in scope
    public var processed: Int                // done + keptOriginal + failed
    public var delivered: Int                // done + keptOriginal
    public var keptOriginal: Int
    public var failed: Int
    public var sourceBytes: Int64            // Σ inBytes over delivered
    public var outputBytes: Int64            // Σ outBytes over delivered
    public var minScore: Double?
    public var medianScore: Double?
    public var maxScore: Double?
    public var floor: Double?                // fixed floor, if any
    public var targetRange: ClosedRange<Double>?   // balanced: min...max of per-photo targets
    public var byteExactCount: Int
    public var savedFraction: Double { sourceBytes > 0 ? 1 - Double(outputBytes) / Double(sourceBytes) : 0 }
    public var isComplete: Bool { processed == total && failed == 0 }
    public static func make(preset: DeliveryPreset, photos: [SourcePhoto], results: [PhotoResult]) -> DeliverySummary {
        /* WP0 implements; scores over status == .done only */ fatalError()
    }
}

public enum PauseReason: Codable, Sendable, Hashable {
    case user
    case sourceUnavailable(volume: String)
    case diskFull(volume: String, neededBytes: Int64)
    case outputNotWritable(path: String)
}

public enum JobPhase: Codable, Sendable, Hashable {
    case queued(position: Int)
    case running
    case paused(PauseReason)
    case stopped
    case interrupted
    case finished
    case failed(reason: String)
}

public struct JobProgress: Sendable, Hashable {
    public var wedding: WeddingID
    public var photosDone: Int
    public var photosTotal: Int
    public var photosInFlight: Int
    public var secondsPerPhoto: Double?      // smoothed (α = 0.1); nil until the first photo finishes
    public var etaSeconds: Double?           // nil until 10 photos have finished
    public var summaries: [DeliverySummary]
    public var fraction: Double { photosTotal == 0 ? 0 : Double(photosDone) / Double(photosTotal) }
    public init(wedding: WeddingID, photosDone: Int, photosTotal: Int, photosInFlight: Int,
                secondsPerPhoto: Double?, etaSeconds: Double?, summaries: [DeliverySummary]) {
        self.wedding = wedding; self.photosDone = photosDone; self.photosTotal = photosTotal
        self.photosInFlight = photosInFlight; self.secondsPerPhoto = secondsPerPhoto
        self.etaSeconds = etaSeconds; self.summaries = summaries
    }
}

public enum EngineEvent: Sendable {
    case phase(WeddingID, JobPhase)
    case results(WeddingID, [PhotoResult])  // coalesced, ≤ 10 Hz
    case progress(JobProgress)               // ≥ 1 Hz while running
}

public struct UnfinishedJob: Codable, Sendable, Hashable {
    public var request: JobRequest
    public var results: [PhotoResult]
    public init(request: JobRequest, results: [PhotoResult]) { self.request = request; self.results = results }
}

// ───────────── Record.swift ─────────────
public struct WeddingRecord: Identifiable, Codable, Sendable, Hashable {
    public var id: WeddingID
    public var name: String
    public var createdAt: Date
    public var weddingDate: Date?
    public var camera: String?
    public var sourceRoots: [URL]
    public var sourceBookmarks: [Data]       // URL.bookmarkData() (not security-scoped) for relinking
    public var photos: [SourcePhoto]
    public var deliveries: [DeliveryPreset]  // snapshots, incl. later "Create More" additions
    public var deliveryCompletedAt: [String: Date]   // DeliveryID.rawValue → completion date
    public var outputFolder: URL
    public var outputBookmark: Data?
    public var naming: NamingScheme
    public var phase: JobPhase
    public var results: [PhotoResult]
    public var startedAt: Date?
    public var finishedAt: Date?
    public var activeSeconds: Double         // excludes paused time
    public var viewed: Bool

    public init(id: WeddingID, name: String, createdAt: Date, weddingDate: Date?, camera: String?,
                sourceRoots: [URL], sourceBookmarks: [Data], photos: [SourcePhoto], deliveries: [DeliveryPreset],
                deliveryCompletedAt: [String: Date], outputFolder: URL, outputBookmark: Data?, naming: NamingScheme,
                phase: JobPhase, results: [PhotoResult], startedAt: Date?, finishedAt: Date?,
                activeSeconds: Double, viewed: Bool) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.weddingDate = weddingDate
        self.camera = camera; self.sourceRoots = sourceRoots; self.sourceBookmarks = sourceBookmarks
        self.photos = photos; self.deliveries = deliveries; self.deliveryCompletedAt = deliveryCompletedAt
        self.outputFolder = outputFolder; self.outputBookmark = outputBookmark; self.naming = naming
        self.phase = phase; self.results = results; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.activeSeconds = activeSeconds; self.viewed = viewed
    }

    public var sourceBytes: Int64 { photos.reduce(0) { $0 + $1.byteCount } }
    public var coverPhoto: SourcePhoto? { photos.first }
    /// Number of failed (photo, delivery) pairs.
    public var issueCount: Int { results.reduce(0) { if case .failed = $1.status { $0 + 1 } else { $0 } } }
    public func summary(for delivery: DeliveryID) -> DeliverySummary? {
        guard let preset = deliveries.first(where: { $0.id == delivery }) else { return nil }
        return DeliverySummary.make(preset: preset, photos: photos, results: results.filter { $0.delivery == delivery })
    }
    /// Σ(source − output) over full-size deliveries (lifetime footer).
    public var savedBytesFullSize: Int64 { /* WP0 */ fatalError() }
}

// ───────────── Compare.swift ─────────────
import CoreGraphics

public struct SendableImage: @unchecked Sendable, Hashable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
    public static func == (l: SendableImage, r: SendableImage) -> Bool { l.cgImage === r.cgImage }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(cgImage)) }
}

public struct ComparePair: Sendable, Hashable {
    public var original: SendableImage?      // nil: source unavailable
    public var delivered: SendableImage
    public var originalBytes: Int64
    public var deliveredBytes: Int64
    public var comparedAtLongEdge: Int?      // resized deliveries
    public var unavailableVolume: String?    // e.g. "Wedding SSD"
    public init(original: SendableImage?, delivered: SendableImage, originalBytes: Int64, deliveredBytes: Int64,
                comparedAtLongEdge: Int?, unavailableVolume: String?) {
        self.original = original; self.delivered = delivered; self.originalBytes = originalBytes
        self.deliveredBytes = deliveredBytes; self.comparedAtLongEdge = comparedAtLongEdge
        self.unavailableVolume = unavailableVolume
    }
}

// ───────────── EngineService.swift ─────────────  (§3.1 verbatim)

// ───────────── Stores.swift ─────────────
public protocol HistoryStoring: Sendable {
    func loadAll() async throws -> [WeddingRecord]
    func save(_ record: WeddingRecord) async throws
    func remove(_ id: WeddingID) async throws
    func removeAll() async throws
}
public protocol PresetStoring: Sendable {
    func load() -> (presets: [DeliveryPreset], defaultOn: [DeliveryID])
    func save(presets: [DeliveryPreset], defaultOn: [DeliveryID])
}
public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}
public protocol ThumbnailProviding: Sendable {
    /// Embedded thumbnail first, max `maxPixelSize`, orientation applied. Disk-cached by path+size+mtime.
    func thumbnail(for photo: SourcePhoto, maxPixelSize: Int) async -> SendableImage?
}

// ───────────── Settings.swift ─────────────
public enum SaveLocation: Codable, Sendable, Hashable { case nextToOriginals, folder(URL) }

public struct AppSettings: Codable, Sendable, Hashable {
    public var saveLocation: SaveLocation = .nextToOriginals
    public var folderNamePattern: String = "{wedding} – Deliveries"   // tokens {wedding} {date} {year}
    public var naming: NamingScheme = .default
    public var notifyWhenFinished = true
    public var playSound = false
    public var menuBarWhileClosed = true
    public var processorUse: ProcessorUse = .automatic
    public var detailedLogs = false
    public init() {}
}

// ───────────── Format.swift ─────────────  (all numbers the UI shows go through here)
public enum HMBFormat {
    public static func bytes(_ n: Int64, locale: Locale = .current) -> String         // ByteCountFormatStyle(style: .file)
    public static func savedPercent(_ fraction: Double, locale: Locale = .current) -> String   // 0.877 → "−88 %" (de) / "−88%" (en_US)
    public static func score(_ s: Double) -> String                                   // "85.4" (always "." — scores are a metric, not prose)
    public static func duration(_ seconds: Double) -> String                          // "38 s", "4 min 12 s", "1 h 20 min"
    public static func statusLine(done: Int, total: Int, etaSeconds: Double?, finishing: Bool) -> String   // S8 table, exact
    public static func folderName(pattern: String, wedding: String, date: Date?) -> String
    public static func fileName(pattern: String, wedding: String, number: Int, count: Int, ext: String) -> String
}
```

#### 5.0.2 UI state, verbatim (`Sources/HMBUI/State/AppState.swift`, frozen)

```swift
import Foundation
import CoreGraphics
import HMBModel

public enum SidebarSelection: Hashable, Sendable { case newWedding, wedding(WeddingID) }
public enum DragSummary: Equatable, Sendable { case folder(name: String), photos(count: Int), items(count: Int) }
public enum DropError: Equatable, Sendable { case onlyRaw(folderName: String, count: Int), noPhotos }
public enum DropZoneState: Equatable, Sendable { case idle, targeted(DragSummary), error(DropError) }
public enum EstimateState: Equatable, Sendable { case estimating, ready(DeliveryEstimate), unavailable }
public enum ScanState: Equatable, Sendable { case scanning(found: Int), ready(ScanResult) }

public struct SetupDraft: Equatable, Sendable {
    public var wedding: WeddingID
    public var name: String
    public var scan: ScanState
    public var enabled: [DeliveryID: Bool]
    public var estimates: [DeliveryID: EstimateState]
    public var naming: NamingScheme
    public var preflight: Preflight?
    public var existingWedding: WeddingID?          // Create More Deliveries
    public var completedDeliveries: [DeliveryID: Date]
    public var isDropTargeted: Bool
    public init(wedding: WeddingID = WeddingID(), name: String, scan: ScanState, enabled: [DeliveryID: Bool],
                estimates: [DeliveryID: EstimateState] = [:], naming: NamingScheme, preflight: Preflight? = nil,
                existingWedding: WeddingID? = nil, completedDeliveries: [DeliveryID: Date] = [:], isDropTargeted: Bool = false) {
        self.wedding = wedding; self.name = name; self.scan = scan; self.enabled = enabled; self.estimates = estimates
        self.naming = naming; self.preflight = preflight; self.existingWedding = existingWedding
        self.completedDeliveries = completedDeliveries; self.isDropTargeted = isDropTargeted
    }
}

public enum CompareMode: String, Sendable { case split, sideBySide }
public enum CompareZoom: Equatable, Sendable { case fit, actual }
public enum CompareOrder: String, Sendable { case captureTime, lowestScore, largestSavings }

public struct CompareRoute: Hashable, Sendable {
    public var wedding: WeddingID
    public var delivery: DeliveryID
    public var start: PhotoID
    public var spotCheck: Bool
    public init(wedding: WeddingID, delivery: DeliveryID, start: PhotoID, spotCheck: Bool) {
        self.wedding = wedding; self.delivery = delivery; self.start = start; self.spotCheck = spotCheck
    }
}

public struct CompareState: Equatable, Sendable {
    public var route: CompareRoute
    public var order: CompareOrder
    public var sequence: [PhotoID]
    public var position: Int
    public var mode: CompareMode = .split
    public var zoom: CompareZoom = .fit
    public var zoomCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)   // unit image coordinates; kept across photos
    public var divider: Double = 0.5
    public var showsOriginal = false
    public var originalLatched = false
    public var showsDifferences = false
    public var showsInspector = false
    public var originalAvailable = true
    public var spotCheckToastShown = false
    public init(route: CompareRoute, order: CompareOrder, sequence: [PhotoID], position: Int) {
        self.route = route; self.order = order; self.sequence = sequence; self.position = position
    }
}

public enum GridSort: String, Sendable { case captureTime, lowestScore, largestSavings, smallestSavings }
public enum AppAlert: Equatable, Sendable { case stop(WeddingID), quitWhileRunning(WeddingID), removeFromHistory(WeddingID), clearHistory }
public enum AppSheet: Equatable, Sendable { case editDelivery(DeliveryPreset, isNew: Bool), renameWedding(WeddingID) }
public enum SettingsTab: String, Sendable { case general, deliveries, advanced }

public struct AppState: Equatable, Sendable {
    public var selection: SidebarSelection = .newWedding
    public var sidebarVisible = false
    public var records: [WeddingRecord] = []        // every wedding; `phase` decides In Progress vs history
    public var queue: [WeddingID] = []              // FIFO; queue.first is running (or next)
    public var live: [WeddingID: JobProgress] = [:]
    public var draft: SetupDraft? = nil
    public var dropZone: DropZoneState = .idle
    public var detailPath: [CompareRoute] = []
    public var compare: CompareState? = nil
    public var search = ""
    public var gridSort: GridSort = .captureTime
    public var gridDelivery: DeliveryID? = nil
    public var issuesOnly = false
    public var selectedPhoto: PhotoID? = nil
    public var alert: AppAlert? = nil
    public var sheet: AppSheet? = nil
    public var settingsTab: SettingsTab = .general
    public var presets: [DeliveryPreset] = DeliveryPreset.builtIns
    public var defaultOn: [DeliveryID] = DeliveryPreset.defaultOnIDs
    public var settings = AppSettings()
    public var windowOpen = true
    public var toast: String? = nil
    public init() {}
}
```

#### 5.0.3 `AppModel` signature (stub by WP0; the body belongs to WP3 and WP4 as noted)

```swift
import SwiftUI
import HMBModel

@MainActor @Observable
public final class AppModel {
    public var state: AppState
    public let engine: any EngineService
    public let history: any HistoryStoring
    public let presetsStore: any PresetStoring
    public let settingsStore: any SettingsStoring
    public let thumbnails: any ThumbnailProviding

    public init(state: AppState, engine: any EngineService, history: any HistoryStoring,
                presetsStore: any PresetStoring, settingsStore: any SettingsStoring, thumbnails: any ThumbnailProviding)

    // WP3 (AppModel.swift)
    public func bootstrap() async                              // load history, presets, settings, unfinished jobs → interrupted
    public func handleDrop(_ urls: [URL]) -> Bool
    public func setDropTargeted(_ targeted: Bool, summary: DragSummary?)
    public func choosePhotos()
    public func toggleDelivery(_ id: DeliveryID)
    public func renameDraft(_ name: String)
    public func chooseOutputFolder()
    public func cancelSetup()
    public func startDraft()
    public func pause(_ id: WeddingID)
    public func resume(_ id: WeddingID)
    public func requestStop(_ id: WeddingID)
    public func confirmAlert()
    public func dismissAlert()
    public func removeFromQueue(_ id: WeddingID)
    public func startNow(_ id: WeddingID)
    public func retry(_ id: WeddingID, photos: [PhotoID]?)
    public func createMoreDeliveries(_ id: WeddingID)
    public func relink(_ id: WeddingID, to folder: URL) -> Bool
    public func removeFromHistory(_ id: WeddingID)
    public func revealInFinder(_ id: WeddingID, delivery: DeliveryID?)
    public func markViewed(_ id: WeddingID)
    public var showsTransientStatusItem: Bool { get set }
    public var overallFraction: Double { get }

    // WP4 (AppModel+Compare.swift)
    public func openCompare(_ route: CompareRoute)
    public func closeCompare()
    public func updateCompare(_ body: (inout CompareState) -> Void)
    public func stepCompare(by delta: Int)

    // WP4 (AppModel+Settings.swift)
    public func editDelivery(_ preset: DeliveryPreset)
    public func addDelivery()
    public func savePreset(_ preset: DeliveryPreset)
    public func deletePreset(_ id: DeliveryID)
    public func movePresets(from: IndexSet, to: Int)
    public func setDefaultOn(_ id: DeliveryID, _ on: Bool)
    public func restoreDefaultDeliveries()
    public func updateSettings(_ body: (inout AppSettings) -> Void)
    public func clearHistory()
    public func resetLearnedEstimates()
}
```

Any of the views can be rendered from a constructed `AppModel(state:…)` with no side effects; in particular, `init` does not call `bootstrap`. This is the contract the snapshot harness relies on.

The listed API is the frozen minimum. Owners may add further members (for example SwiftUI `Binding` helpers like `columnVisibilityBinding`, or private helpers) in their own files, but may not change or remove listed ones.

### 5.1 WP1: codecs, imaging and metric (engine primitives)

**Owns:** `Sources/CHMBCodecs/*.cc`, `Sources/HMBEngine/{Codecs,Imaging,Metric}/**`, `Sources/HMBEngine/Interfaces/Primitives+Live.swift`, `Tests/HMBEngineTests/Primitives/**`, `Docs/METRIC.md`.

**Consumes:** `hmb_codecs.h`, the `Primitives.swift` protocols (§3.2), and `HMBModel` (`ChromaSubsampling`, `SourceKind`).

**Provides:** `EnginePrimitives.live()` with:

| Component | Implementation |
|---|---|
| `ImageIODecoder: ImageDecoding` | ImageIO, `kCGImageSourceShouldCache: false`. Decodes into the image's own colour space (no orientation applied). DQT quality estimate (IJG inverse). CMYK / Adobe transform detection. Arithmetic-coding detection (SOF9–SOF15). Marker extraction. |
| `VImageProcessing: ImageProcessing` | Port of `GrainEstimator.statistics(p50)` and `chromaEnergy`, verbatim semantics. `vImageScale_ARGB8888` with `kvImageHighQualityResampling`. A `vImageConverter` to sRGB. The mosaic (§3.4). |
| `JpegliEncoder: JPEGEncoding` | Via `hmb_jpegli_encode`. |
| `LibWebPEncoder: WebPEncoding` | Via `hmb_webp_*`. |
| `LibJXLTranscoder: JXLTranscoding` | Via `hmb_jxl_*`. |
| `MetalSSIMULACRA2: PerceptualMetric` | Port of `jpegos/Sources/SqueezeCore/Metrics/MetalSSIMULACRA2.swift`, `SSIMULACRA2.swift` and `GaussianBlur.swift`: reference session, buffer pools, pow hoist (audit #1–#3). Adds fused candidate kernels (half-precision intermediates, threadgroup-staged vertical blur, GPU-side final reduction: audit #4–#7) to meet the 0.40 s budget. CPU `SSIMULACRA2` stays in the module as the test oracle. |

**Acceptance criteria and tests:**
1. **Codec round-trips** on 4 synthetic fixtures and, when `HMB_TEST_PHOTOS` is set, the 6 sample photos:
   - JPEG decodes back to its size, and its markers are present in order.
   - WebP carries ICC, EXIF and XMP chunks.
   - JXL transcode + reconstruct is byte-identical (SHA-256).
2. **jpegli equivalence** vs. `jpegos/Vendor/bin/cjpegli` at d ∈ {1.6, 2.0} (only with `HMB_TEST_PHOTOS`): sizes ±1.0 %, scores ±0.2 (§3.13).
3. **Metric agreement:**
   - |GPU − CPU| ≤ 0.02 on 10 pairs.
   - |new port − old engine port| ≤ 0.05 on the 19 holdout outputs in `engine-exp/old-holdout` vs `holdout`, using `old-holdout-ownscores.txt` as the expectation (gated by `HMB_HOLDOUT`).
   - The metric is monotone on a synthetic JPEG quality ladder.
4. **Metric performance:** a 45 MP candidate scored against a cached reference takes ≤ 0.40 s median of 10 (quiet machine), and reference preparation ≤ 0.20 s. Results go into `Docs/METRIC.md` with the machine state. If 0.40 is missed, WP1 still delivers the port and reports the number; the lead decides.
5. **Imaging:**
   - Features match old `GrainEstimator` values within 1e-6 on synthetic fixtures (expected values computed by running the old code once and committing them as constants).
   - The resize never upscales.
   - The sRGB conversion of an sRGB image is the identity (max Δ ≤ 1).
6. **Decoder:**
   - Repeated ImageIO decodes of the same file are pixel-identical.
   - Decoding a jpegli encode (d = 0.5) of a synthetic image comes back within PSNR ≥ 40 dB of the encoder input.
   - CMYK, arithmetic and holdmybyte-COM detection each have a fixture.
7. **Memory and safety:**
   - No leaks: Instruments-free test via `malloc_zone_statistics` before/after 50 encodes, delta < 5 MB.
   - All C error paths return messages, never `abort()`.

### 5.2 WP2: search, pipeline, jobs and the live engine

**Owns:** `Sources/HMBEngine/{Search,Pipeline,Jobs,IO,Metadata,Estimate,Service}/**`, `Tests/HMBEngineTests/Pipeline/**`, `Docs/ENGINE.md`.

**Consumes:** the §3.2 primitives (developed against `.fakes()` until WP1 merges, then `.live()`), plus `HMBModel`.

**Provides:** `LiveEngine: EngineService`, with `public init(primitives: EnginePrimitives = try .live(), supportDirectory: URL = <Application Support>/holdmybyte)`, plus the internal pieces below.

| Component | Responsibility |
|---|---|
| `Scanner` | §3.8 scanning |
| `MosaicSearch` | §3.4 |
| `DirectSearch` | §3.5 |
| `JXLArchive` | §3.6 |
| `MetadataEditor` | §3.7 |
| `PhotoPipeline` | §3.3 |
| `WorkerPool` | §3.9 |
| `MetricLane` | §3.9 |
| `OutputWriter` | §3.8 |
| `Journal` | §3.8 |
| `Estimator` | §3.10 |
| `ProgressCoalescer` | 10 Hz events, smoothed ETA |

**Acceptance criteria and tests (fakes unless marked "live"):**
1. **OutputWriter safety:**
   - Refuses: a source file; a path below a source root; a symlink to a source; a case-variant path; a hard link to a source (same inode).
   - Never overwrites (" 2" naming).
   - No `.tmp` remains after success or after a cancelled write.
2. **Journal and resume:**
   - Kill-after-N simulation (stop at 3 random points). The resumed run produces the same set of files with the same bytes as an uninterrupted run, with no duplicates.
   - A truncated last journal line is tolerated.
3. **Pause and stop:** latency < 1.5 s with fakes made artificially slow, and no partial files.
4. **Errors:** `ENOSPC` maps to `.paused(.diskFull)` (injected via a writer hook); an unmounted source maps to `.paused(.sourceUnavailable)`.
5. **Search logic** (fakes with analytic score curves):
   - Never returns a failing probe.
   - At most 3 + 2 + fail-open probes.
   - Keep-original is triggered at ≥ 0.95 × source.
   - 4:4:4 fail-open triggers only when 4:2:0 is unreachable.
6. **Live search quality** (`HMB_HOLDOUT`):
   - Every one of the 19 photos ≥ its target.
   - Mean full probes ≤ 2.2, max ≤ 5.
   - Total Balanced bytes ≤ 50.31 MB (old 49.81 MB + 1 %).
   - Fitted `prior(T)`, `qPrior(T)` and κ are recorded in `Docs/ENGINE.md`.
7. **Metadata:**
   - For each policy, the produced EXIF/XMP contains exactly the allowed tags (parsed back with ImageIO).
   - Orientation is preserved.
   - A lossless metadata rewrite of a kept original leaves the decoded pixels identical.
8. **Determinism:** two live runs over 6 photos × 4 deliveries are byte-identical.
9. **Scanner:**
   - Generic-name rule, RAW/non-photo counting, the ` – Deliveries` skip, capture order.
   - ≥ 500 files/s on a synthetic tree of 2000 tiny JPEGs.
10. **Estimator (live, holdout):** within ±15 % per delivery; ≤ 5 s.
11. **Event cadence:** results are coalesced to ≤ 10 Hz, and progress is emitted ≥ 1 Hz.

### 5.3 WP3: app shell and job-flow UI

**Owns:**
- `Sources/HMBUI/{Shell,Drop,Setup,Run,MenuBar,Components,Alerts}/**`
- `Sources/HMBUI/State/AppModel.swift`
- `Sources/HoldMyByteApp/**`
- `Tests/HMBUITests/AppModel/**`

**Consumes:** `AppState` and the `AppModel` signature (§5.0.2–5.0.3), `EngineService`, the store protocols, `Tokens`/`Glass`, and `HMBFixtures` (previews and tests).

**Provides:**
- Every view in §2.1–§2.4 S1–S13, S15, S17, S18, plus S19 (Dock, notifications).
- `AppAlert.copy: (title: String, message: String, buttons: [String])`. This is the single source used by the `.alert` modifiers and by the harness.
- `AppModel.live()` in the app target, wiring `LiveEngine`, `JSONHistoryStore`, `UserDefaultsPresetStore`, `UserDefaultsSettingsStore` and `DiskThumbnailCache` from HMBStore.
- The queue: FIFO; one job at a time; Start Now Instead pauses the current job.
- Persistence: records are saved on every phase change and every 5 s while running.
- Volume-mount observation, which enables Resume.

**Acceptance criteria and tests:**
1. **Intent tests** with `FixtureEngine` and in-memory stores:
   - drop → scanning → ready → start → running → finished → record saved;
   - queue order;
   - pause / resume / stop;
   - interrupted at bootstrap;
   - Create More Deliveries (completed deliveries are disabled and the existing folder is used);
   - relink accepts only folders with ≥ 90 % of the outputs;
   - remove from history leaves the files alone.
2. **Copy tests:** all S1–S18 copy lives as constants (or formatting functions) in `Components/Copy.swift`. A table-driven test asserts each one against the spec string, including pluralised and interpolated variants.
3. **Drag and drop:** dropping a folder, files, a mix, only RAW, or nothing usable leads to the correct state (§2.4 S2–S4).
4. **Closing and menu bar:** closing the window while running keeps the app alive, and the menu-bar extra is inserted. When the job finishes it is removed, and if idle, closing the window quits.
5. **Performance:** 2000-photo grid scrolling is checked with a signpost benchmark in the snapshot harness (≥ 110 fps average over 3 s of scripted scrolling). The history Done view loads in ≤ 100 ms.
6. **Visual review:** every WP3 state renders in WP5's harness in light and dark with no clipped text at 1120×780 or at 780×560.

### 5.4 WP4: Compare, Settings, Edit Delivery and the stores

**Owns:**
- `Sources/HMBUI/{Compare,Settings,EditDelivery}/**`
- `Sources/HMBUI/State/AppModel+Compare.swift`, `AppModel+Settings.swift`
- `Sources/HMBStore/**`
- `Tests/HMBUITests/Compare/**`, `Tests/HMBStoreTests/**`

**Consumes:** `AppState`/`CompareState`/`CompareRoute`, `EngineService.comparePair`, the store protocols, and `Tokens`/`Glass`.

**Provides:**

| Item | Contents |
|---|---|
| S14 Compare | `CompareView`; `CompareCanvas` (NSViewRepresentable with CALayers, tiled for 100 %); HUD; inspector; spot-check; Differences via Core Image; preloading of the next pair |
| S6 | Edit Delivery sheet |
| S16 | Settings |
| HMBStore: `JSONHistoryStore` | One `record.json` per wedding in `~/Library/Application Support/holdmybyte/Weddings/<id>/`, atomic writes |
| HMBStore: `UserDefaultsPresetStore`, `UserDefaultsSettingsStore` | Presets and settings in UserDefaults |
| HMBStore: `DiskThumbnailCache` | `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageIfAbsent` and the transform applied, ≤ 320 px, JPEG cache in `~/Library/Caches/eu.sebastianhaas.holdmybyte/Thumbnails/<sha256(path|size|mtime)>.jpg` |

**Acceptance criteria and tests:**
1. **Compare state machine:**
   - next/prev keeps zoom and centre;
   - spot-check K = clamp(ceil(0.03·n), 5, 12), and the toast fires once after K;
   - `\` hold vs. latch (200 ms);
   - archive is excluded;
   - the no-original state disables Split, `\` and `D`.
2. **Compare performance** (harness-driven, 45 MP pair from `HMB_TEST_PHOTOS`): first frame ≤ 150 ms; the original swap ≤ 16 ms (one layer flip); the full pair ≤ 600 ms.
3. **Stores:**
   - Round-trip 2000-photo records; load ≤ 100 ms.
   - A corrupt file is quarantined (renamed `.corrupt`), never fatal.
   - Presets keep their order and the `defaultOn` set.
   - The thumbnail cache is invalidated by mtime.
4. **Settings and Edit Delivery:** every validation rule disables Save with the exact message, and `Restore Default` restores the built-in exactly.
5. **Visual review:** every WP4 state renders in the harness, light and dark.

### 5.5 WP5: snapshot harness, CLI, benchmarks and bundling

**Owns:**
- `Sources/HMBSnapshot/**`, `Sources/hmb/**`, `Sources/HMBBench/**`, `Tests/HMBBenchTests/**`
- `Scripts/{bundle-app,make-icon,snapshot,bench,check-repo,notarize}.sh`
- `Benchmarks/baselines.json`
- `Docs/{BENCHMARKS,SNAPSHOTS}.md`
- the README "Benchmarks" and "Build" sections (by PR comment to the lead; the README is WP0's)

**Consumes:** `HMBUI` (views, `AppModel`, `AppAlert.copy`), `HMBFixtures`, `HMBEngine` (`LiveEngine`, primitives), `HMBModel`.

**Snapshot harness (`hmb-snapshot`):** renders every state without the window server.

| Environment variable | Default | Meaning |
|---|---|---|
| `HMB_SNAPSHOT` | `all` | `all`, or a comma-separated list of state ids |
| `HMB_SNAPSHOT_DIR` | `./Snapshots` | output directory |
| `HMB_SNAPSHOT_APPEARANCE` | `both` | `light`, `dark` or `both` |
| `HMB_SNAPSHOT_SIZE` | `1120x780` | window size |
| `HMB_SNAPSHOT_LOCALE` | `en_DE` | locale (English text, German number formatting, as on the owner's Mac) |
| `HMB_FIXTURE_PHOTOS` | unset | optional folder of real local thumbnails |

How it renders:
- **Windows:** each state is an `AppModel(state: <catalogue entry>, …fixtures)` hosted in an `NSHostingView` inside a borderless offscreen `NSWindow`. The window is never ordered front. Its `appearance` is set, then `layoutSubtreeIfNeeded()`, then `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)`, and the result is written as PNG.
- **Environment:** sets `\.isSnapshotRendering = true` (glass falls back to materials) and `\.locale`.
- **Alerts:** rendered from `AppAlert.copy` into a real `NSAlert`; the harness lays it out and caches `alert.window.contentView`.
- **Menu-bar extra:** rendered as `StatusMenu` content.
- **Settings:** rendered at 600 wide.

Outputs per run:
- `<id>-light.png` and `<id>-dark.png`
- `index.html`: a contact sheet with the id, size and spec section for each image
- `manifest.json`

The run exits with a non-zero status if any state fails to render or renders blank (more than 99 % of pixels have one colour).

**State catalogue** (`HMBSnapshot/StateCatalogue.swift`). It must contain exactly these ids, and adding a state to §2 means adding it here:
- **Empty and drop:** `empty`, `empty-error-raw`, `empty-error-none`, `drag-target`
- **Setup:** `preparing`, `setup-ready`, `setup-estimating`, `setup-warn-precompressed`, `setup-blocked-disk`, `setup-create-more`, `drop-on-setup`, `edit-delivery`
- **Job states:** `queued`, `running-early`, `running-mid`, `paused-user`, `paused-drive`, `paused-disk`, `stopped`, `interrupted`
- **Results:** `done-single`, `done-three`, `done-issues`, `done-kept-original`, `done-missing-folder`, `failed`
- **Compare:** `compare-split-fit`, `compare-split-100`, `compare-side`, `compare-original-held`, `compare-diff`, `compare-no-original`, `compare-spotcheck-toast`
- **History:** `history-search`, `history-empty-search`
- **Settings:** `settings-general`, `settings-deliveries`, `settings-advanced`
- **Other surfaces:** `menubar-extra`, `alert-stop`, `alert-quit`, `alert-remove`

**`hmb` CLI** (installed in `Contents/Helpers/hmb`). Every command refuses to write inside a source (it goes through `OutputWriter`).

```
hmb compress <src>… -o <dir> [--delivery couple|website|social|archive|high-full|highest-full]… [--delivery-json <preset.json>]…
             [--workers N] [--json <report.json>]
hmb estimate <src>… [--delivery …]…
hmb score <reference> <candidate>          # engine metric (Metal), prints one number
hmb inspect <file>                          # SourceInfo + features + Balanced target, as JSON
hmb bench --set <dir> --out <dir> [--delivery …]… [--repeat N] [--old-engine <path-to-squeeze>] [--label <text>]
```

**Bench (`HMBBench`):**
- **Per-file CSV:** name, source bytes, output bytes, score, target, probes, seconds, encoder, chroma.
- **Totals JSON:** bytes, savings, min/median/max score, wall time, s/photo, CPU-s/photo (`getrusage`), peak RSS.
- **Machine state:** `uptime` load before and after, `ProcessInfo.thermalState`, `hw.model`, whether Lightroom is running, and the free memory.
- **Provenance:** git commit and the codec versions.
- **Comparison:** against `Benchmarks/baselines.json`, with pass/fail per gate G1–G8 (§6).
- **Old engine A/B:** `--old-engine` runs the old `squeeze` CLI on the same set in the same session, alternating A/B/A/B, and writes its outputs to `--out/old/`, never into jpegos.
- **Quiet-machine rule:** the bench refuses to report timing gates when the 1-minute load average is > 3 at start. It still reports bytes and scores.

**Acceptance criteria and tests:**
1. `swift run hmb-snapshot` renders all catalogue ids in both appearances on a locked-screen Mac (verified over SSH or with the screen locked), in ≤ 120 s, without the window server.
2. `Scripts/bundle-app.sh` produces a launchable `.app`. The audit passes, and `codesign --verify --deep` succeeds for the ad hoc signature.
3. **`HMBBenchTests`:** CSV/JSON schema; gate evaluation against a synthetic baseline; refusal when `-o` is inside a source.
4. **`Scripts/check-repo.sh`:** no photos and no `unsafeFlags`; no `/opt/homebrew` strings in `Package.swift` or the scripts, except the audit regex itself.
5. **`Benchmarks/baselines.json`** contains:
   - DATENLAGE §1b/§8 totals and times;
   - the JPEGmini totals and throughput;
   - the per-file old-engine holdout bytes and reference scores, from `old-holdout-refscores.txt` (copied as numbers, not as files).

### 5.6 Local data (never committed)

| Variable | Typical value | Used by |
|---|---|---|
| `HMB_TEST_PHOTOS` | `/private/tmp/claude-501/-Users-sebastianhaas-Desktop-jpegos-/218b30ef-5c5b-49e3-8077-d8051064b757/scratchpad/sample` (6 × 45 MP) | WP1/WP2 tests |
| `HMB_HOLDOUT` | `…/scratchpad/holdout` (19), with `…/scratchpad/v2/engine-exp/old-holdout*` | WP1/WP2 tests, G1/G2 |
| `HMB_WEDDING` | `/Users/sebastianhaas/Desktop/jpegos/wedding/Finn und Lissy/fertig` (535, **read-only, never write there**) | G3–G7 |
| `HMB_OLD_ENGINE` | `/Users/sebastianhaas/Desktop/jpegos/.build/release/squeeze` | A/B timing |
| `HMB_FIXTURE_PHOTOS` | the sample folder | realistic snapshots (outputs stay local) |

The scratchpad is temporary. In WP0, the lead copies `sample/`, `holdout/` and `engine-exp/old-holdout*` into `~/Library/Application Support/holdmybyte-dev/data/` (outside the repo) and points the variables there.

---

## 6. Verification plan: what proves v2 is done

Each gate is run by the lead on `main` after the last merge. The results go into `Docs/BENCHMARKS.md`, with the machine state for every timing number.

### 6.1 Build and static gates

| ID | Gate |
|---|---|
| B1 | From a clean clone: `Scripts/build-codecs.sh && swift build -c release` succeeds with **zero warnings** in Swift 6 mode. |
| B2 | `swift test` is green, including the environment-gated tests with `HMB_TEST_PHOTOS` and `HMB_HOLDOUT` set. |
| B3 | `Scripts/check-repo.sh` is green: no `unsafeFlags`, no Homebrew paths, no photos, no `_jpeg_` exports. |
| B4 | `Scripts/bundle-app.sh` succeeds. The app launches, and `otool -L` lists only system libraries. |
| B5 | No network: `nm -u` of the app binary contains no `URLSession`/`nw_`/`CFNetwork` symbols beyond those Foundation pulls in transitively. The binary is checked against the allowlist in `check-repo.sh`. |

### 6.2 Engine and benchmark gates

The machine must be quiet (1-minute load < 3, Lightroom closed). Timing runs are repeated twice and the faster run counts. Old-engine A/B runs alternate in the same session.

| ID | Set / delivery | Gate | Reference |
|---|---|---|---|
| G1 | Holdout 19 / Couple’s Package (Balanced) | every photo ≥ its target; total ≤ **50.31 MB**; mean full probes ≤ 2.2 | old engine 49.81 MB |
| G2 | Holdout 19 / Couple’s Package | wall time ≤ **0.6 ×** the old engine's in the same session | old `squeeze`, A/B/A/B |
| G3 | Wedding 535 / Couple’s Package (Balanced) | every photo ≥ target; total ≤ **1.37 GB**; wall ≤ **10 min**; kept-original count reported | old 1.35 GB, 17.4 min; JPEGmini 5.36 GB |
| G4 | Wedding 535 / custom "High full-size" (JPEG, full, ≥ 85) | min ≥ 85.0; total ≤ **3.10 GB** | old 3.05 GB; JPEGmini 5.36 GB at floor 75 |
| G5 | Wedding 535 / Website and Social | Website min ≥ 70, ≤ **165 MB**, ≤ 2.5 min alone; Social min ≥ 85, ≤ **165 MB** | old 159 MB / 3.7 min; 155 MB / 7.1 min |
| G6 | Wedding 535 / Archive | **535/535 byte-exact**; total ≤ **8.60 GB**; ≤ 6 min alone | old 8.55 GB, 11.3 min |
| G7 | Wedding 535 / all four deliveries in one run | ≤ **14 min**; estimates within ±15 % per delivery; peak RSS ≤ 8 GB | old 39.5 min across four runs |
| G8 | Wedding 535 / Couple, resume | stop at about 40 %, quit, relaunch, Resume → output byte-identical to the uninterrupted G3 run; no `.tmp` left | — |
| G9 | Safety | after G3–G8, `shasum -a 256` of all 535 sources is unchanged vs. before (manifest taken before G3) | — |

If G1/G3 bytes fail, the lead enables the chroma-gate flag (E2) and re-runs. If G3 timing fails because the metric misses its 0.40 s budget, the lead decides between shipping with an honest number and spending more on the metric. In no case is a floor lowered or full-resolution verification dropped to pass a gate.

### 6.3 Screenshot review (every state)

1. Run `HMB_FIXTURE_PHOTOS=<sample> swift run hmb-snapshot`. This produces 42 ids × 2 appearances = 84 PNGs plus `index.html`.
2. The lead reviews each image against §2 using the checklist below, and records pass or fail per id in `Docs/SNAPSHOTS.md`.
3. Finally, the owner sees the contact sheet (as a private artifact) before the release tag.

**Checklist for each image:**
- exact copy;
- no clipped or truncated numbers;
- symbols as specified;
- accent used only on the listed elements;
- dark mode legible, with no hard-coded colours;
- the 780×560 minimum size renders without overlap (the harness also renders `setup-ready`, `running-mid`, `done-three` and `compare-split-fit` at 780×560).

### 6.4 Flow checklist (manual, on the real app with the real wedding)

1. F1: drag `fertig`. Setup appears in under 100 ms, named "Finn und Lissy", with estimates in under 5 s. Press Return. The grid turns grey to colour. Close the window: the menu-bar extra appears and the Dock shows progress. A notification arrives, and Show in Finder selects `Couple`.
2. F1 variant: four deliveries in one run. The strip shows four capsules, and resized ones finish first.
3. F2: Spot-Check opens on the lowest score. `Z` at the cursor, holding `\`, `→` keeping zoom, `D`, and the toast after K photos all work.
4. F3: ⌘F "lissy" finds the wedding. ⌘R reveals it. Create More Deliveries → Archive goes into the same folder, and the completed deliveries are disabled.
5. **Error paths:**
   - Eject the external source drive mid-run: paused-drive, then reconnect and Resume.
   - Fill a small disk image used as the output: paused-disk.
   - Choose a read-only output: blocked in setup.
   - Drop a RAW-only folder: `empty-error-raw`.
   - Drop the Deliveries folder itself: the holdmybyte-output warning.
6. **Interrupt:** quit during a run (alert), relaunch, Interrupted banner, Resume.
7. **Accessibility pass:** VoiceOver reads the drop zone, a delivery row, a grid cell and the histogram summary. Full keyboard flow F1 without the mouse. Reduce Motion and Increase Contrast are both on and checked.
8. **Originals untouched:** G9 manifest compare.

**v2 is done when B1–B5, G1–G9, the 84 snapshots and the 8 flow checks all pass, or each exception is explicitly accepted by the owner in writing.**

---

## 7. Explicit non-goals for v1

- **AVIF output** of any kind (libaom vendoring, CMS support). Website is WebP with a JPEG fallback.
- **Encoder competition and extras:** mozjpeg, QuantRefiner, quant-table tuning; any DCT-domain requantisation (patent-sensitive, see memory "Beamr patents").
- **Learned models:** predictor, student metric, training-log harvesting, the Harvester app.
- **Grain synthesis and grain-aware verification;** saliency/worst-region "Jump to Hardest Spot".
- **New metric kernels:** an IIR-exact SSIMULACRA2 kernel, or re-basing the floors onto the libjxl reference scale.
- **Lightroom and Finder integration:** Lightroom After Export integration, watch folders, the "Waiting for export" state, automatic delivery. These are the first v1.x candidates, taken from Design B.
- **Re-delivery features:** source-change detection, incremental "Update Deliveries", "Deliver Again / replace via Trash".
- **Batch and library features:** multi-wedding batch selection, the All Weddings table, queue reordering, "Put Mac to sleep when finished".
- **Exports:** the Quality Proof PDF, the CSV quality report export in the app (the CLI bench CSV exists).
- **Calibration:** "Tune to My Eye" / the calibration UI.
- **System integrations:** Finder Quick Action, Services, App Intents/Shortcuts, Spotlight indexing, the command-line-tool installer in Settings.
- **Source handling:** any "replace original" mode; writing inside source folders; RAW input; CMYK compression; 16-bit output.
- **Other features:** watermarks, byte budgets ("fits on a USB stick"), upload integrations, any network use, telemetry.
- **Platform and distribution:** localisation beyond English (no String Catalog in v1), Mac App Store sandboxing, Intel builds, final Icon Composer artwork (the generated placeholder ships).
- **Compare extras:** 200 % zoom, the "Hardest Spot" button, comparison of the Archive delivery.
