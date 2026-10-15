// Every user-visible string of S1–S19 (Docs/SPEC.md §2.4), as constants or formatting functions.
// Views and the snapshot harness use only these; `Tests/HMBUITests/AppModel/CopyTests.swift` checks each one against
// the spec text, including the pluralised and interpolated variants.
import Foundation
import HMBModel

public enum Copy {
    // MARK: Shared helpers

    /// "1 photo" / "535 photos" / "1.800 photos" (en_DE), grouped for `locale`.
    public static func count(_ n: Int, _ singular: String, _ plural: String, locale: Locale = .current) -> String {
        "\(n.formatted(.number.locale(locale))) \(n == 1 ? singular : plural)"
    }

    public static func photos(_ n: Int, locale: Locale = .current) -> String { count(n, "photo", "photos", locale: locale) }
    public static func deliveries(_ n: Int, locale: Locale = .current) -> String { count(n, "delivery", "deliveries", locale: locale) }

    /// “Finn und Lissy” (typographic quotes).
    public static func quoted(_ s: String) -> String { "“\(s)”" }

    /// Bytes as GB with one decimal, for disk-space sentences ("1.9 GB", "0.8 GB").
    public static func gigabytes(_ n: Int64, locale: Locale = .current) -> String {
        ByteCountFormatStyle(style: .file, allowedUnits: .gb, spellsOutZero: false, locale: locale).format(n)
    }

    /// "about 5 min", "less than a minute", "about 1 h 20 min" (rounded to minutes).
    public static func approximateDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }

    /// The UI is English (§2.5): dates use English words with the region's conventions ("12 Jul" in en_DE),
    /// also on a Mac whose language is German.
    public static func uiLocale(_ locale: Locale) -> Locale {
        if locale.language.languageCode == .english { return locale }
        return Locale(languageCode: .english, languageRegion: locale.region)
    }

    /// "Jul 12" (en_US), with an explicit time zone so tests and snapshots are stable.
    public static func shortDate(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.locale = uiLocale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "July 12, 2026" (en_US).
    public static func longDate(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day().year()
        style.locale = uiLocale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "July 2026" (sidebar section titles).
    public static func monthYear(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.locale = uiLocale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "~/Weddings/Finn und Lissy" when `url` is inside `home`, else the full path.
    public static func abbreviatedPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    // MARK: S1 empty

    public enum Empty {
        public static let title = "Drop a wedding"
        public static let subtitle = "A folder or a selection of finished photos."
        public static let choosePhotos = "Choose Photos…"
        public static let footerNote = "Everything stays on this Mac. Originals are never changed."
        public static let editDeliveries = "Edit Deliveries…"
        /// "Creates: Couple’s Package · Website"; with nothing chosen: "Creates: no deliveries".
        public static func creates(_ names: [String]) -> String {
            names.isEmpty ? "Creates: no deliveries" : "Creates: " + names.joined(separator: " · ")
        }
        public static let accessibilityLabel = "Drop zone"
        public static let accessibilityHint = "Drop photos or folders, or press Command-O to choose photos."
        public static let accessibilityAction = "Choose Photos"
    }

    // MARK: S2 nothing usable dropped

    public enum DropError {
        public static let title = "No photos found"
        public static func onlyRaw(folderName: String, count: Int, locale: Locale = .current) -> String {
            "\(Copy.quoted(folderName)) contains \(Copy.count(count, "RAW file", "RAW files", locale: locale)). "
                + "holdmybyte compresses finished photos: export JPEGs first."
        }
        public static let noPhotos = "The dropped items don’t contain JPEG, HEIC, PNG or TIFF photos."
        public static let chooseOther = "Choose Other Photos…"
        /// Seconds until the zone returns to `empty`.
        public static let resetAfter: Double = 6
    }

    // MARK: S3 drag target

    public enum DragTarget {
        public static func title(_ summary: DragSummary, locale: Locale = .current) -> String {
            switch summary {
            case .folder(let name): "Release to add \(Copy.quoted(name))"
            case .photos(let count): "Release to add \(Copy.photos(count, locale: locale))"
            case .items(let count): "Release to add \(Copy.count(count, "item", "items", locale: locale))"
            }
        }
        public static let subtitle = "Folders are searched, including subfolders."
        public static let addToThisWedding = "Add to this wedding"
        public static let startNewWedding = "Start a new wedding"
    }

    // MARK: S4 setup

    public enum Setup {
        public static let namePlaceholder = "Wedding name"
        public static func scanning(found: Int, locale: Locale = .current) -> String {
            "Reading photos… \(found.formatted(.number.locale(locale))) found"
        }
        /// "535 photos · 10.95 GB · July 12, 2026 · ILCE-7RM5" (date and camera omitted when unknown).
        public static func meta(photos: Int, bytes: Int64, date: Date?, camera: String?,
                                locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            var parts = [Copy.photos(photos, locale: locale), HMBFormat.bytes(bytes, locale: locale)]
            if let date { parts.append(Copy.longDate(date, locale: locale, timeZone: timeZone)) }
            if let camera, !camera.isEmpty { parts.append(camera) }
            return parts.joined(separator: " · ")
        }
        public static let deliveriesHeader = "Deliveries"
        public static let deliveriesFooter = "Each photo is read once and saved in every delivery you choose."
        public static let addDelivery = "Add Delivery…"
        public static let saveTo = "Save To"
        public static let folder = "Folder"
        public static let change = "Change…"
        public static let edit = "Edit…"
        public static let renameToggle = "Rename by capture time"
        public static let renameOff = "Original file names are kept."
        /// "Finn-und-Lissy-0001.jpg … Finn-und-Lissy-0535.jpg"
        public static func renamePreview(pattern: String, wedding: String, count: Int, ext: String = "jpg") -> String {
            let first = HMBFormat.fileName(pattern: pattern, wedding: wedding, number: 1, count: count, ext: ext)
            guard count > 1 else { return first }
            let last = HMBFormat.fileName(pattern: pattern, wedding: wedding, number: count, count: count, ext: ext)
            return "\(first) … \(last)"
        }
        /// "Weddings › Finn und Lissy › Finn und Lissy – Deliveries" (the last three components).
        public static func breadcrumb(_ url: URL) -> String {
            url.standardizedFileURL.pathComponents.filter { $0 != "/" }.suffix(3).joined(separator: " › ")
        }
        /// "Couple · Website"
        public static func subfolders(_ names: [String]) -> String { names.joined(separator: " · ") }

        public static func estimate(_ bytes: Int64, locale: Locale = .current) -> String { "≈ " + HMBFormat.bytes(bytes, locale: locale) }
        public static let estimating = "Estimating…"
        public static let estimateOff = "–"
        public static let estimateUnavailable = "–"
        public static let byteExact = "byte-exact"
        public static func longEdge(_ px: Int) -> String { "\(px) px" }
        /// "Done Jul 14" (Create More Deliveries mode).
        public static func done(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            "Done " + Copy.shortDate(date, locale: locale, timeZone: timeZone)
        }

        public static let chooseAtLeastOne = "Choose at least one delivery."
        /// "2 deliveries" (before estimates), "2 deliveries · ≈ 1.6 GB in total · about 5 min" (after).
        public static func summary(deliveries: Int, totalBytes: Int64?, seconds: Double?, locale: Locale = .current) -> String {
            guard deliveries > 0 else { return chooseAtLeastOne }
            var text = Copy.deliveries(deliveries, locale: locale)
            if let totalBytes { text += " · ≈ \(HMBFormat.bytes(totalBytes, locale: locale)) in total" }
            if totalBytes != nil, let seconds { text += " · " + Copy.approximateDuration(seconds) }
            return text
        }
        public static func compress(_ count: Int, locale: Locale = .current) -> String {
            count == 1 ? "Compress 1 Photo" : "Compress \(count.formatted(.number.locale(locale))) Photos"
        }
        public static let compressWhileScanning = "Compress Photos"
        public static let addToQueue = "Add to Queue"
        public static let cancel = "Cancel"
        public static let startsWhenRead = "Starts as soon as all photos are read."

        /// VoiceOver: "Couple’s Package, full size JPEG, Balanced quality, estimated 1.4 gigabytes, 87 percent smaller, checked"
        public static func rowAccessibility(preset: DeliveryPreset, estimate: DeliveryEstimate?, isOn: Bool,
                                            completed: Date?, locale: Locale = .current) -> String {
            var parts = [preset.name]
            let size = preset.size.longEdge.map { "\($0) pixel" } ?? "full size"
            parts.append("\(size) \(preset.format.displayName)")
            parts.append("\(preset.quality.displayName) quality")
            if let completed {
                parts.append(Setup.done(completed, locale: locale))
            } else if let estimate, isOn {
                let bytes = ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: locale).format(estimate.bytes)
                    .replacingOccurrences(of: "GB", with: "gigabytes").replacingOccurrences(of: "MB", with: "megabytes")
                    .replacingOccurrences(of: "TB", with: "terabytes").replacingOccurrences(of: "kB", with: "kilobytes")
                parts.append("estimated \(bytes)")
                let percent = Int(((1 - estimate.fractionOfSource) * 100).rounded())
                if preset.isFullSize { parts.append("\(percent) percent smaller") }
            }
            parts.append(isOn ? "checked" : "unchecked")
            return parts.joined(separator: ", ")
        }
    }

    // MARK: S5 notices

    public struct NoticeText: Equatable, Sendable {
        public var title: String?
        public var body: String
        public init(title: String? = nil, body: String) { self.title = title; self.body = body }
    }

    public enum Notice {
        public static let showList = "Show List"
        public static let useArchiveOnly = "Use Archive Only"
        public static let continueAnyway = "Continue Anyway"
        public static let chooseAnotherLocation = "Choose Another Location…"

        /// `kinds`: the non-JPEG source kinds present (for "18 HEIC and PNG photos will be delivered as JPEG.").
        public static func text(_ notice: ScanNotice, kinds: [SourceKind] = [], locale: Locale = .current) -> NoticeText {
            switch notice {
            case .skippedNonPhotos(let count, let extensions):
                let list = extensions.isEmpty ? "" : " (\(extensions.map { $0.uppercased() }.joined(separator: ", ")))"
                let files = count == 1 ? "1 file that isn’t a photo" : "\(count.formatted(.number.locale(locale))) files that aren’t photos"
                return NoticeText(body: "Skipped \(files)\(list).")
            case .skippedRaw(let count):
                return NoticeText(body: "Skipped \(Copy.count(count, "RAW file", "RAW files", locale: locale)). "
                                  + "holdmybyte works on finished photos: export JPEGs from Lightroom first.")
            case .cmyk(let count):
                let verb = count == 1 ? "photo can’t" : "photos can’t"
                let they = count == 1 ? "It will be listed as an issue; export it as RGB." : "They will be listed as issues; export them as RGB."
                return NoticeText(body: "\(count.formatted(.number.locale(locale))) CMYK \(verb) be compressed yet. \(they)")
            case .alreadyCompressed(let count, let total):
                let look = count == 1 ? "looks" : "look"
                return NoticeText(title: "These photos were already compressed.",
                                  body: "\(count.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) \(look) like the output of "
                                  + "another compressor. Compressing them again adds a second round of loss. Quality is still "
                                  + "measured, but against these files, not your exports.")
            case .holdMyByteOutput:
                return NoticeText(title: "These look like holdmybyte deliveries.",
                                  body: "Compressing a delivery again won’t make it meaningfully smaller and adds loss. "
                                  + "Drop your Lightroom export instead.")
            case .convertedToJPEG(let count):
                let names = kinds.filter { $0 != .jpeg }.map(kindName)
                let kindText = names.isEmpty ? "" : listJoined(names) + " "
                return NoticeText(body: "\(count.formatted(.number.locale(locale))) \(kindText)\(count == 1 ? "photo" : "photos") will be delivered as JPEG.")
            case .outputFolderExists(let existing, let used):
                return NoticeText(body: "\(Copy.quoted(existing)) already exists here. The new deliveries go into \(Copy.quoted(used)).")
            case .notEnoughSpace(let volume, let needed, let available):
                return NoticeText(title: "Not enough space on \(Copy.quoted(volume)).",
                                  body: "These deliveries need about \(Copy.gigabytes(needed, locale: locale)); "
                                  + "\(Copy.gigabytes(available, locale: locale)) is free.")
            case .notWritable(let volume):
                return NoticeText(title: "holdmybyte can’t write to \(Copy.quoted(volume)).",
                                  body: "The drive is read-only. Choose another location for the deliveries.")
            case .outputInsideSource:
                return NoticeText(title: "holdmybyte can’t save inside the folder you dropped.",
                                  body: "Choose another location for the deliveries.")
            }
        }

        static func kindName(_ kind: SourceKind) -> String {
            switch kind { case .jpeg: "JPEG"; case .heic: "HEIC"; case .png: "PNG"; case .tiff: "TIFF" }
        }

        /// "HEIC", "HEIC and PNG", "HEIC, PNG and TIFF"
        static func listJoined(_ items: [String]) -> String {
            switch items.count {
            case 0: ""
            case 1: items[0]
            default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
            }
        }
    }

    // MARK: S7 queued

    public enum Queued {
        public static let title = "Waiting to start"
        public static func description(after name: String?) -> String {
            guard let name else { return "Starts automatically when the current job finishes." }
            return "Starts automatically after \(Copy.quoted(name)) finishes."
        }
        public static let startNow = "Start Now Instead"
        public static let remove = "Remove from Queue"
    }

    // MARK: S8 running

    public enum Run {
        public static func title(_ name: String) -> String { "Compressing \(name)" }
        public static let savedSoFar = "saved so far"
        public static let deliveredSoFar = "delivered so far"
        public static func revealHelp(_ name: String) -> String { "Show \(name) in Finder" }
    }

    // MARK: S9 banners

    public struct BannerText: Equatable, Sendable {
        public var title: String
        public var message: String
        public init(title: String, message: String) { self.title = title; self.message = message }
    }

    public enum Banner {
        public static let resume = "Resume"
        public static let stop = "Stop"
        public static let showInFinder = "Show in Finder"
        public static let stopHere = "Stop Here"

        public static func paused(_ reason: PauseReason, done: Int, total: Int, locale: Locale = .current) -> BannerText {
            switch reason {
            case .user:
                return BannerText(title: "Paused", message: "\(done.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) \(done == 1 ? "is" : "are") done.")
            case .sourceUnavailable(let volume):
                return BannerText(title: "Paused: \(Copy.quoted(volume)) was disconnected.",
                                  message: "Reconnect it, then resume. Nothing has been lost.")
            case .diskFull(let volume, let needed):
                return BannerText(title: "Paused: \(Copy.quoted(volume)) is full.",
                                  message: "Free up about \(Copy.gigabytes(needed, locale: locale)), then resume.")
            case .outputNotWritable(let path):
                let name = URL(fileURLWithPath: path).lastPathComponent
                return BannerText(title: "Paused: holdmybyte can’t write to \(Copy.quoted(name)).",
                                  message: "Check the folder’s permissions, then resume.")
            }
        }

        public static func stopped(done: Int, total: Int, locale: Locale = .current) -> BannerText {
            BannerText(title: "Stopped",
                       message: "\(done.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) \(done == 1 ? "is" : "are") in the delivery folders. "
                       + "The rest can be finished any time.")
        }

        public static func interrupted(done: Int, total: Int, locale: Locale = .current) -> BannerText {
            BannerText(title: "Compression was interrupted",
                       message: "\(done.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) \(done == 1 ? "is" : "are") done and safe. "
                       + "Continue where it stopped?")
        }
    }

    // MARK: S10–S12 done

    public enum Done {
        public static func title(_ name: String, issues: Int, locale: Locale = .current) -> String {
            issues == 0 ? "\(name) is ready" : "\(name) is ready, with \(Copy.count(issues, "issue", "issues", locale: locale))"
        }
        /// "535 photos · 2 deliveries · finished in 4 min 12 s · every photo verified"
        public static func subtitle(photos: Int, deliveries: Int, seconds: Double?, locale: Locale = .current) -> String {
            var parts = [Copy.photos(photos, locale: locale), Copy.deliveries(deliveries, locale: locale)]
            if let seconds, seconds > 0 { parts.append("finished in " + HMBFormat.duration(seconds)) }
            parts.append("every photo verified")
            return parts.joined(separator: " · ")
        }
        /// "535 photos · 2 deliveries · 532 verified · 3 need attention"
        public static func subtitleWithIssues(photos: Int, deliveries: Int, verified: Int, issues: Int, locale: Locale = .current) -> String {
            [Copy.photos(photos, locale: locale), Copy.deliveries(deliveries, locale: locale),
             "\(verified.formatted(.number.locale(locale))) verified",
             "\(issues.formatted(.number.locale(locale))) \(issues == 1 ? "needs" : "need") attention"].joined(separator: " · ")
        }

        /// "from 10.95 GB · −88 %"
        public static func fromLine(source: Int64, fraction: Double, locale: Locale = .current) -> String {
            "from \(HMBFormat.bytes(source, locale: locale)) · \(HMBFormat.savedPercent(fraction, locale: locale))"
        }
        /// "2560 px · WebP · 159 MB for 535 photos"
        public static func resizedLine(longEdge: Int, format: OutputFormat, bytes: Int64, photos: Int, locale: Locale = .current) -> String {
            "\(longEdge) px · \(format.displayName) · \(HMBFormat.bytes(bytes, locale: locale)) for \(Copy.photos(photos, locale: locale))"
        }
        public static func keptOriginal(_ count: Int, locale: Locale = .current) -> String {
            count == 1
                ? "1 photo kept as original. It was already as small as this quality allows."
                : "\(count.formatted(.number.locale(locale))) photos kept as original. They were already as small as this quality allows."
        }
        /// "Every photo ≥ 85 · lowest 85.0" | "Every photo met its target · lowest 74.0"
        public static func proofLine(quality: QualityLevel, lowest: Double?) -> String {
            let lowestText = lowest.map { " · lowest " + HMBFormat.score($0) } ?? ""
            if let floor = quality.floor { return "Every photo ≥ \(Int(floor))" + lowestText }
            return "Every photo met its target" + lowestText
        }
        public static let archiveProofLine = "Byte-exact: every file restores to the identical original"
        /// Tile proof line of a delivery with failed photos (orange, no seal).
        public static func deliveredLine(delivered: Int, total: Int, locale: Locale = .current) -> String {
            "\(delivered.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) delivered"
        }
        public static let showInFinder = "Show in Finder"

        public static func proofTitle(met: Int, total: Int, locale: Locale = .current) -> String {
            "\(met.formatted(.number.locale(locale))) of \(Copy.photos(total, locale: locale)) met their quality target"
        }
        public static func proofDetail(lowest: Double, median: Double, highest: Double) -> String {
            "Each delivered photo was compared with its original. Lowest \(HMBFormat.score(lowest)) · "
                + "median \(HMBFormat.score(median)) · highest \(HMBFormat.score(highest))."
        }
        public static let spotCheck = "Spot-Check the Hardest Photos"
        public static let lowestFive = "Lowest five"
        public static func archiveOnly(byteExact: Int, total: Int, locale: Locale = .current) -> String {
            "Byte-exact: \(byteExact.formatted(.number.locale(locale))) of \(total.formatted(.number.locale(locale))) "
                + "\(total == 1 ? "file restores" : "files restore") to the identical original."
        }
        public static let explainerIntro = "holdmybyte measures every delivered photo against its original with SSIMULACRA2, "
            + "an open perceptual metric. Higher is closer to the original; 100 means identical."
        public static let explainerTitle = "How Quality Is Measured"
        /// VoiceOver chart summary: "535 photos, lowest 85.0, median 85.5, all at or above 85"
        public static func histogramSummary(photos: Int, lowest: Double, median: Double, floor: Double?) -> String {
            var text = "\(photos) photos, lowest \(HMBFormat.score(lowest)), median \(HMBFormat.score(median))"
            if let floor { text += ", all at or above \(Int(floor))" } else { text += ", all met their targets" }
            return text
        }

        public static func gridTitle(_ count: Int, locale: Locale = .current) -> String {
            count == 1 ? "1 Photo" : "\(count.formatted(.number.locale(locale))) Photos"
        }
        public static let issuesOnly = "Issues Only"
        public static let sortHelp = "Sort photos"
        public static func sortName(_ sort: GridSort) -> String {
            switch sort {
            case .captureTime: "Capture Time"
            case .lowestScore: "Lowest Score First"
            case .largestSavings: "Largest Savings First"
            case .smallestSavings: "Smallest Savings First"
            }
        }
        /// Hover caption: "−88 % · 85.4"
        public static func cellCaption(fraction: Double?, score: Double?, locale: Locale = .current) -> String {
            [fraction.map { HMBFormat.savedPercent($0, locale: locale) }, score.map(HMBFormat.score)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        /// VoiceOver: "DSC09412, done, 88 percent smaller, score 85.4"
        public static func cellAccessibility(fileName: String, status: String, fraction: Double?, score: Double?) -> String {
            var parts = [fileName, status]
            if let fraction { parts.append("\(Int((fraction * 100).rounded())) percent smaller") }
            if let score { parts.append("score \(HMBFormat.score(score))") }
            return parts.joined(separator: ", ")
        }
    }

    public enum Issues {
        public static let showOriginal = "Show Original"
        public static let tryAgain = "Try Again"
        public static let tryAgainForAll = "Try Again for All"

        /// Group heading per failure type. `delivery` names the delivery for per-delivery types.
        public static func heading(_ failure: PhotoFailure, count: Int, delivery: String?, locale: Locale = .current) -> String {
            let n = count.formatted(.number.locale(locale))
            let prefix = delivery.map { "\($0): " } ?? ""
            switch failure {
            case .unreadable:
                return count == 1
                    ? "Couldn’t read 1 photo. The file is damaged or incomplete. It is missing from every delivery."
                    : "Couldn’t read \(n) photos. The files are damaged or incomplete. They are missing from every delivery."
            case .cmykUnsupported:
                return count == 1
                    ? "1 photo is CMYK, which isn’t supported yet. Export it as RGB from Lightroom."
                    : "\(n) photos are CMYK, which isn’t supported yet. Export them as RGB from Lightroom."
            case .encodeFailed:
                return "\(prefix)\(Copy.photos(count, locale: locale)) couldn’t be saved. Try again; if it fails again, the file is unusual. Please send the log."
            case .writeFailed:
                return "\(prefix)\(Copy.photos(count, locale: locale)) couldn’t be saved to the delivery folder."
            case .sourceMissing:
                return count == 1 ? "1 photo is no longer in the wedding folder." : "\(n) photos are no longer in the wedding folder."
            case .qualityUnreachable:
                return "\(prefix)\(Copy.photos(count, locale: locale)) couldn’t reach the quality target. Please send the log."
            }
        }

        /// Short per-row reason.
        public static func reason(_ failure: PhotoFailure) -> String {
            switch failure {
            case .unreadable: "Damaged or incomplete"
            case .cmykUnsupported: "CMYK"
            case .encodeFailed: "Couldn’t be saved"
            case .writeFailed: "Couldn’t be written"
            case .sourceMissing: "No longer in the wedding folder"
            case .qualityUnreachable: "Quality target not reached"
            }
        }
    }

    public enum MissingFolder {
        public static let title = "The delivery folder has moved or was deleted."
        public static func message(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
            "Last seen at \(Copy.abbreviatedPath(url, home: home))."
        }
        public static let locate = "Locate…"
        public static let removeFromHistory = "Remove from History…"
        public static let locateFailed = "This folder doesn’t contain the deliveries of this wedding."
    }

    // MARK: S13 failed

    public enum Failed {
        public static func title(_ name: String) -> String { "Couldn’t compress \(Copy.quoted(name))" }
        public static let tryAgain = "Try Again"
        public static let remove = "Remove"
    }

    // MARK: Sidebar and S15

    public enum Sidebar {
        public static let newWedding = "New Wedding"
        public static let inProgress = "In Progress"
        public static let queued = "Queued"
        public static let searchPrompt = "Search Weddings"
        /// "Jul 12 · 535 photos"
        public static func rowSubtitle(date: Date?, photos: Int, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
            let count = Copy.photos(photos, locale: locale)
            guard let date else { return count }
            return Copy.shortDate(date, locale: locale, timeZone: timeZone) + " · " + count
        }
        /// "1.24 TB saved across 38 weddings"
        public static func lifetime(savedBytes: Int64, weddings: Int, locale: Locale = .current) -> String {
            "\(HMBFormat.bytes(savedBytes, locale: locale)) saved across \(Copy.count(weddings, "wedding", "weddings", locale: locale))"
        }
        public static let undated = "No Date"
    }

    // MARK: Toolbar, menus and help tags (§2.2, §2.8)

    public enum Toolbar {
        public static let newWedding = "New Wedding"
        public static let newWeddingHelp = "New Wedding (⌘N)"
        public static let removeFromQueue = "Remove from Queue"
        public static let removeFromQueueHelp = "Remove from the queue"
        public static let pause = "Pause"
        public static let pauseHelp = "Pause (⌥⌘P)"
        public static let resume = "Resume"
        public static let resumeHelp = "Resume (⌥⌘P)"
        public static let stop = "Stop"
        public static let stopHelp = "Stop (⌘.)"
        public static let compare = "Compare"
        public static let compareHelp = "Compare photos (⌘Y)"
        public static let showInFinder = "Show in Finder"
        public static let showInFinderHelp = "Show in Finder (⌘R)"
        public static let more = "More"
        public static let moreHelp = "More actions"
        public static let createMore = "Create More Deliveries…"
        public static let rename = "Rename…"
        public static let removeFromHistory = "Remove from History…"
        public static let comparePhotos = "Compare Photos"
        public static let spotCheck = "Spot-Check Hardest Photos"
        /// "535 photos · 10.95 GB"
        public static func subtitle(photos: Int, bytes: Int64, locale: Locale = .current) -> String {
            "\(Copy.photos(photos, locale: locale)) · \(HMBFormat.bytes(bytes, locale: locale))"
        }
    }

    public enum Rename {
        public static let title = "Rename Wedding"
        public static let field = "Name"
        public static let save = "Rename"
        public static let cancel = "Cancel"
    }

    // MARK: S17 menu-bar extra

    public enum StatusItem {
        /// "58 %"
        public static func percent(_ fraction: Double, locale: Locale = .current) -> String {
            max(0, min(1, fraction)).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        }
        public static let pause = "Pause"
        public static let resume = "Resume"
        public static let stop = "Stop…"
        public static let open = "Open holdmybyte"
    }

    // MARK: S19 notifications

    public struct NotificationText: Equatable, Sendable {
        public var title: String
        public var body: String?
        public init(title: String, body: String?) { self.title = title; self.body = body }
    }

    public enum Notification {
        public static let showInFinder = "Show in Finder"
        public static let compare = "Compare"

        /// Finished clean: "Couple’s Package 1.35 GB (−88 %) · Website 159 MB · every photo verified."
        /// Finished with issues: "532 of 535 photos delivered. Open holdmybyte to see what happened."
        public static func finished(_ record: WeddingRecord, locale: Locale = .current) -> NotificationText {
            let failedPhotos = Set(record.results.compactMap { if case .failed = $0.status { $0.photo } else { nil } })
            if !failedPhotos.isEmpty {
                let delivered = record.photos.count - failedPhotos.count
                return NotificationText(title: Done.title(record.name, issues: failedPhotos.count, locale: locale),
                                        body: "\(delivered.formatted(.number.locale(locale))) of \(Copy.photos(record.photos.count, locale: locale)) delivered. "
                                        + "Open holdmybyte to see what happened.")
            }
            let parts = record.deliveries.compactMap { preset -> String? in
                guard let summary = record.summary(for: preset.id) else { return nil }
                let size = HMBFormat.bytes(summary.outputBytes, locale: locale)
                if preset.isFullSize { return "\(preset.name) \(size) (\(HMBFormat.savedPercent(summary.savedFraction, locale: locale)))" }
                return "\(preset.name) \(size)"
            }
            return NotificationText(title: Done.title(record.name, issues: 0, locale: locale),
                                    body: (parts + ["every photo verified."]).joined(separator: " · "))
        }

        public static func pausedByDrive(volume: String) -> NotificationText {
            NotificationText(title: "Paused: \(Copy.quoted(volume)) was disconnected.", body: nil)
        }
    }

    // MARK: Help

    public enum Help {
        public static let qualityMenuItem = "How Quality Is Measured"
    }

    // MARK: Accessibility announcements (§2.9)

    public enum Announcement {
        public static func progress(_ percent: Int, name: String) -> String { "\(name): \(percent) percent done" }
        public static func paused(_ name: String) -> String { "\(name) paused" }
        public static func finished(_ name: String) -> String { "\(name) is ready" }
    }
}
