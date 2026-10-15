// hmb-snapshot: renders every state of the state catalogue to PNG without the window server (Docs/SPEC.md §5.5).
//
//   HMB_SNAPSHOT             all | comma-separated ids            (default all)
//   HMB_SNAPSHOT_DIR         output directory                     (default ./Snapshots)
//   HMB_SNAPSHOT_APPEARANCE  light | dark | both                  (default both)
//   HMB_SNAPSHOT_SIZE        WIDTHxHEIGHT                         (default 1120x780)
//   HMB_SNAPSHOT_LOCALE      locale identifier                    (default en_DE)
//   HMB_SNAPSHOT_SETTLE      seconds per render before capture    (default 0.45)
//   HMB_FIXTURE_PHOTOS       optional folder of local photos used as thumbnails
//
//   hmb-snapshot --list               print the catalogue ids
//   hmb-snapshot --render-icon DIR    write the placeholder app icon as an .iconset (Scripts/make-icon.sh)
//   hmb-snapshot --self-test [DIR]    check the capture pipeline on a probe view (no app views needed)
//
// Exit status: 0 when every image rendered and none is blank; 1 otherwise; 64 for usage errors.
import AppKit
import Foundation

let environment = ProcessInfo.processInfo.environment

// The locale must be in place before anything reads `Locale.current` (HMBFormat's defaults do).
let localeIdentifier = environment["HMB_SNAPSHOT_LOCALE"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_DE"
UserDefaults.standard.setVolatileDomain(["AppleLocale": localeIdentifier, "AppleLanguages": ["en"]],
                                        forName: UserDefaults.argumentDomain)

func fail(_ message: String, status: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("hmb-snapshot: \(message)\n".utf8))
    exit(status)
}

func loadAverage() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) == 3 ? loads.map { ($0 * 100).rounded() / 100 } : []
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--list":
    for entry in StateCatalogue.entries { print(entry.id) }
    exit(0)
case "--render-icon":
    guard arguments.count == 2 else { fail("usage: hmb-snapshot --render-icon <dir.iconset>") }
    do { try AppIconArt.writeIconset(to: URL(fileURLWithPath: arguments[1], isDirectory: true)) } catch { fail("\(error)", status: 1) }
    exit(0)
case "--self-test":
    guard arguments.count <= 2 else { fail("usage: hmb-snapshot --self-test [dir]") }
case "-h", "--help":
    print("usage: hmb-snapshot [--list | --render-icon <dir> | --self-test [dir]]; configure with HMB_SNAPSHOT* variables (Docs/SNAPSHOTS.md)")
    exit(0)
case .some(let other):
    fail("unknown argument \(other)")
case .none:
    break
}

// MARK: Options

let selection = environment["HMB_SNAPSHOT"].flatMap { $0.isEmpty ? nil : $0 } ?? "all"
let entries: [CatalogueEntry]
if selection == "all" {
    entries = StateCatalogue.entries
} else {
    let ids = selection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let unknown = ids.filter { StateCatalogue.entry($0) == nil }
    if !unknown.isEmpty { fail("unknown state id(s): \(unknown.joined(separator: ", ")); see --list") }
    entries = ids.compactMap(StateCatalogue.entry)
}

let appearances: [SnapshotAppearance] = switch environment["HMB_SNAPSHOT_APPEARANCE"] ?? "both" {
case "light": [.light]
case "dark": [.dark]
case "both", "": [.light, .dark]
default: fail("HMB_SNAPSHOT_APPEARANCE must be light, dark or both")
}

let windowSize: CGSize = {
    let text = environment["HMB_SNAPSHOT_SIZE"].flatMap { $0.isEmpty ? nil : $0 } ?? "1120x780"
    let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { fail("HMB_SNAPSHOT_SIZE must look like 1120x780") }
    return CGSize(width: parts[0], height: parts[1])
}()

let settleSeconds = environment["HMB_SNAPSHOT_SETTLE"].flatMap(Double.init) ?? 0.45
let outputDirectory = URL(fileURLWithPath: environment["HMB_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "Snapshots",
                          isDirectory: true).standardizedFileURL

// MARK: Run

func sizeLabel(_ size: CGSize) -> String { "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" }

let started = Date()
let loadBefore = loadAverage()
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(outputDirectory.path): \(error)", status: 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.applicationIconImage = AppIconArt.image(pointSize: 128)
ActiveWindowAppearance.force()

let renderer = SnapshotRenderer(locale: Locale(identifier: localeIdentifier), settleSeconds: settleSeconds)

if arguments.first == "--self-test" {
    let directory = arguments.count == 2 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : outputDirectory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let checks = HarnessSelfTest.run(renderer: renderer, directory: directory)
    for check in checks { print("\(check.passed ? "pass" : "FAIL")  \(check.name)  (\(check.detail))") }
    let failed = checks.filter { !$0.passed }.count
    print("self-test: \(checks.count - failed) of \(checks.count) checks passed → \(directory.path)")
    exit(failed == 0 ? 0 : 1)
}

var images: [SnapshotManifest.Image] = []

for entry in entries {
    var sizes: [(CGSize, Bool)] = [(windowSize, false)]
    if entry.surface == .window { sizes += entry.extraSizes.filter { $0 != windowSize }.map { ($0, true) } }
    for (size, isExtra) in sizes {
        for appearance in appearances {
            let name = isExtra ? "\(entry.id)@\(sizeLabel(size))-\(appearance.rawValue).png" : "\(entry.id)-\(appearance.rawValue).png"
            let surface = switch entry.surface {
            case .window: "window"
            case .settings: "settings"
            case .menuBar: "menu bar"
            case .alert: "alert"
            }
            let t0 = Date()
            var record = SnapshotManifest.Image(id: entry.id, section: entry.section, surface: surface, appearance: appearance.rawValue,
                                                file: name, size: sizeLabel(size), pixelWidth: 0, pixelHeight: 0,
                                                dominantColourFraction: 1, blank: true, error: nil, milliseconds: 0)
            do {
                let rendered = try autoreleasepool {
                    try renderer.render(RenderRequest(entry: entry, appearance: appearance, size: size, isExtraSize: isExtra))
                }
                try PNGWriter.write(rendered.image, to: outputDirectory.appending(path: name))
                let dominant = PixelStats.dominantColourFraction(rendered.image)
                record.size = sizeLabel(rendered.pointSize)
                record.pixelWidth = rendered.image.width
                record.pixelHeight = rendered.image.height
                record.dominantColourFraction = (dominant * 10_000).rounded() / 10_000
                record.blank = dominant > PixelStats.blankThreshold
            } catch {
                record.error = "\(error)"
            }
            record.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
            images.append(record)
            let status = record.error.map { "FAILED (\($0))" } ?? (record.blank ? "BLANK" : "ok")
            print("\(name)  \(record.size)  \(record.milliseconds) ms  \(status)")
        }
    }
}

let failures = images.filter { !$0.ok }.count
let manifest = SnapshotManifest(
    run: .init(startedAt: started, seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, locale: localeIdentifier,
               windowSize: sizeLabel(windowSize), appearances: appearances.map(\.rawValue), settleSeconds: settleSeconds,
               fixturePhotos: environment["HMB_FIXTURE_PHOTOS"].map { !$0.isEmpty } ?? false,
               loadAverageBefore: loadBefore, loadAverageAfter: loadAverage(),
               macOS: ProcessInfo.processInfo.operatingSystemVersionString, failures: failures),
    images: images)
do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: outputDirectory.appending(path: "manifest.json"))
    try Data(ContactSheet.html(manifest).utf8).write(to: outputDirectory.appending(path: "index.html"))
} catch {
    fail("cannot write the manifest or index: \(error)", status: 1)
}
print("\(images.count) images, \(failures) failed, \(String(format: "%.1f", manifest.run.seconds)) s → \(outputDirectory.path)/index.html")
exit(failures == 0 ? 0 : 1)
