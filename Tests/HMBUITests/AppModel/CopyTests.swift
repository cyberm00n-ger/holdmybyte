// §5.3 acceptance 2: every S1–S19 string in Components/Copy.swift (and AppAlert.copy) against the spec text,
// including pluralised and interpolated variants.
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@Suite struct CopyTests {
    static let us = Locale(identifier: "en_US")
    static let de = Locale(identifier: "en_DE")
    static let berlin = FixtureFactory.timeZone
    static let july12 = FixtureFactory.date(2026, 7, 12, 15, 42)
    static let july14 = FixtureFactory.date(2026, 7, 14, 9, 16)

    struct Case: CustomTestStringConvertible, Sendable {
        let actual: String
        let expected: String
        let line: Int
        init(_ actual: String, _ expected: String, line: Int = #line) { self.actual = actual; self.expected = expected; self.line = line }
        var testDescription: String { "line \(line): \(expected)" }
    }

    static let cases: [Case] = [
        // S1
        Case(Copy.Empty.title, "Drop a wedding"),
        Case(Copy.Empty.subtitle, "A folder or a selection of finished photos."),
        Case(Copy.Empty.choosePhotos, "Choose Photos…"),
        Case(Copy.Empty.creates(["Couple’s Package", "Website"]), "Creates: Couple’s Package · Website"),
        Case(Copy.Empty.editDeliveries, "Edit Deliveries…"),
        Case(Copy.Empty.footerNote, "Everything stays on this Mac. Originals are never changed."),
        Case(Copy.Empty.accessibilityLabel, "Drop zone"),
        Case(Copy.Empty.accessibilityHint, "Drop photos or folders, or press Command-O to choose photos."),
        // S2
        Case(Copy.DropError.title, "No photos found"),
        Case(Copy.DropError.onlyRaw(folderName: "Finn und Lissy", count: 535, locale: us),
             "“Finn und Lissy” contains 535 RAW files. holdmybyte compresses finished photos: export JPEGs first."),
        Case(Copy.DropError.onlyRaw(folderName: "X", count: 1, locale: us),
             "“X” contains 1 RAW file. holdmybyte compresses finished photos: export JPEGs first."),
        Case(Copy.DropError.noPhotos, "The dropped items don’t contain JPEG, HEIC, PNG or TIFF photos."),
        Case(Copy.DropError.chooseOther, "Choose Other Photos…"),
        // S3
        Case(Copy.DragTarget.title(.folder(name: "Finn und Lissy"), locale: us), "Release to add “Finn und Lissy”"),
        Case(Copy.DragTarget.title(.photos(count: 535), locale: us), "Release to add 535 photos"),
        Case(Copy.DragTarget.title(.photos(count: 1), locale: us), "Release to add 1 photo"),
        Case(Copy.DragTarget.title(.items(count: 3), locale: us), "Release to add 3 items"),
        Case(Copy.DragTarget.subtitle, "Folders are searched, including subfolders."),
        Case(Copy.DragTarget.addToThisWedding, "Add to this wedding"),
        Case(Copy.DragTarget.startNewWedding, "Start a new wedding"),
        // S4
        Case(Copy.Setup.scanning(found: 212, locale: us), "Reading photos… 212 found"),
        Case(Copy.Setup.meta(photos: 535, bytes: 10_950_000_000, date: july12, camera: "ILCE-7RM5", locale: us, timeZone: berlin),
             "535 photos · 10.95 GB · July 12, 2026 · ILCE-7RM5"),
        Case(Copy.Setup.meta(photos: 535, bytes: 10_950_000_000, date: nil, camera: nil, locale: us), "535 photos · 10.95 GB"),
        Case(Copy.Setup.deliveriesFooter, "Each photo is read once and saved in every delivery you choose."),
        Case(Copy.Setup.addDelivery, "Add Delivery…"),
        Case(Copy.Setup.saveTo, "Save To"),
        Case(Copy.Setup.change, "Change…"),
        Case(Copy.Setup.breadcrumb(URL(fileURLWithPath: "/Users/sebastian/Weddings/Finn und Lissy/Finn und Lissy – Deliveries")),
             "Weddings › Finn und Lissy › Finn und Lissy – Deliveries"),
        Case(Copy.Setup.subfolders(["Couple", "Website"]), "Couple · Website"),
        Case(Copy.Setup.renameToggle, "Rename by capture time"),
        Case(Copy.Setup.renamePreview(pattern: "{wedding}-{number}", wedding: "Finn und Lissy", count: 535),
             "Finn-und-Lissy-0001.jpg … Finn-und-Lissy-0535.jpg"),
        Case(Copy.Setup.renameOff, "Original file names are kept."),
        Case(Copy.Setup.estimate(1_400_000_000, locale: us), "≈ 1.4 GB"),
        Case(Copy.Setup.estimating, "Estimating…"),
        Case(Copy.Setup.estimateOff, "–"),
        Case(Copy.Setup.longEdge(2560), "2560 px"),
        Case(Copy.Setup.byteExact, "byte-exact"),
        Case(Copy.Setup.done(july14, locale: us, timeZone: berlin), "Done Jul 14"),
        Case(Copy.Setup.summary(deliveries: 2, totalBytes: nil, seconds: nil, locale: us), "2 deliveries"),
        Case(Copy.Setup.summary(deliveries: 2, totalBytes: 1_600_000_000, seconds: 294, locale: us),
             "2 deliveries · ≈ 1.6 GB in total · about 5 min"),
        Case(Copy.Setup.summary(deliveries: 1, totalBytes: nil, seconds: nil, locale: us), "1 delivery"),
        Case(Copy.Setup.summary(deliveries: 0, totalBytes: nil, seconds: nil, locale: us), "Choose at least one delivery."),
        Case(Copy.Setup.compress(535, locale: us), "Compress 535 Photos"),
        Case(Copy.Setup.compressWhileScanning, "Compress Photos"),
        Case(Copy.Setup.addToQueue, "Add to Queue"),
        Case(Copy.Setup.cancel, "Cancel"),
        Case(Copy.Setup.rowAccessibility(preset: DeliveryPreset.builtIns[0], estimate: Fixtures.estimates[.couple], isOn: true,
                                         completed: nil, locale: us),
             "Couple’s Package, full size JPEG, Balanced quality, estimated 1.4 gigabytes, 87 percent smaller, checked"),
        // S5
        Case(Copy.Notice.text(.skippedNonPhotos(count: 14, extensions: ["xmp", "mov"]), locale: us).body,
             "Skipped 14 files that aren’t photos (XMP, MOV)."),
        Case(Copy.Notice.text(.skippedRaw(count: 12), locale: us).body,
             "Skipped 12 RAW files. holdmybyte works on finished photos: export JPEGs from Lightroom first."),
        Case(Copy.Notice.text(.cmyk(count: 2), locale: us).body,
             "2 CMYK photos can’t be compressed yet. They will be listed as issues; export them as RGB."),
        Case(Copy.Notice.text(.alreadyCompressed(count: 312, of: 535), locale: us).title ?? "", "These photos were already compressed."),
        Case(Copy.Notice.text(.alreadyCompressed(count: 312, of: 535), locale: us).body,
             "312 of 535 photos look like the output of another compressor. Compressing them again adds a second round of loss. "
             + "Quality is still measured, but against these files, not your exports."),
        Case(Copy.Notice.text(.holdMyByteOutput(count: 3), locale: us).title ?? "", "These look like holdmybyte deliveries."),
        Case(Copy.Notice.text(.holdMyByteOutput(count: 3), locale: us).body,
             "Compressing a delivery again won’t make it meaningfully smaller and adds loss. Drop your Lightroom export instead."),
        Case(Copy.Notice.text(.outputFolderExists(existing: "Finn und Lissy – Deliveries", used: "Finn und Lissy – Deliveries 2"), locale: us).body,
             "“Finn und Lissy – Deliveries” already exists here. The new deliveries go into “Finn und Lissy – Deliveries 2”."),
        Case(Copy.Notice.text(.notEnoughSpace(volume: "Macintosh HD", needed: 1_900_000_000, available: 800_000_000), locale: us).title ?? "",
             "Not enough space on “Macintosh HD”."),
        Case(Copy.Notice.text(.notEnoughSpace(volume: "Macintosh HD", needed: 1_900_000_000, available: 800_000_000), locale: us).body,
             "These deliveries need about 1.9 GB; 0.8 GB is free."),
        Case(Copy.Notice.text(.notWritable(volume: "Wedding SSD"), locale: us).title ?? "", "holdmybyte can’t write to “Wedding SSD”."),
        Case(Copy.Notice.text(.notWritable(volume: "Wedding SSD"), locale: us).body,
             "The drive is read-only. Choose another location for the deliveries."),
        Case(Copy.Notice.text(.convertedToJPEG(count: 18), kinds: [.heic, .png], locale: us).body,
             "18 HEIC and PNG photos will be delivered as JPEG."),
        Case(Copy.Notice.text(.outputInsideSource, locale: us).title ?? "", "holdmybyte can’t save inside the folder you dropped."),
        Case(Copy.Notice.text(.outputInsideSource, locale: us).body, "Choose another location for the deliveries."),
        Case(Copy.Notice.showList, "Show List"),
        Case(Copy.Notice.useArchiveOnly, "Use Archive Only"),
        Case(Copy.Notice.continueAnyway, "Continue Anyway"),
        Case(Copy.Notice.chooseAnotherLocation, "Choose Another Location…"),
        // S7
        Case(Copy.Queued.title, "Waiting to start"),
        Case(Copy.Queued.description(after: "Anna & Ben"), "Starts automatically after “Anna & Ben” finishes."),
        Case(Copy.Queued.startNow, "Start Now Instead"),
        Case(Copy.Queued.remove, "Remove from Queue"),
        // S8
        Case(Copy.Run.title("Finn und Lissy"), "Compressing Finn und Lissy"),
        Case(Copy.Run.savedSoFar, "saved so far"),
        Case(Copy.Run.deliveredSoFar, "delivered so far"),
        Case(HMBFormat.statusLine(done: 0, total: 535, etaSeconds: nil, finishing: false, locale: us), "Starting…"),
        Case(HMBFormat.statusLine(done: 12, total: 535, etaSeconds: nil, finishing: false, locale: us), "12 of 535 photos · estimating time…"),
        Case(HMBFormat.statusLine(done: 312, total: 535, etaSeconds: 180, finishing: false, locale: us), "312 of 535 photos · about 3 min left"),
        // S9
        Case(Copy.Banner.paused(.user, done: 312, total: 535, locale: us).title, "Paused"),
        Case(Copy.Banner.paused(.user, done: 312, total: 535, locale: us).message, "312 of 535 photos are done."),
        Case(Copy.Banner.paused(.sourceUnavailable(volume: "Wedding SSD"), done: 1, total: 2, locale: us).title,
             "Paused: “Wedding SSD” was disconnected."),
        Case(Copy.Banner.paused(.sourceUnavailable(volume: "Wedding SSD"), done: 1, total: 2, locale: us).message,
             "Reconnect it, then resume. Nothing has been lost."),
        Case(Copy.Banner.paused(.diskFull(volume: "Macintosh HD", neededBytes: 600_000_000), done: 1, total: 2, locale: us).title,
             "Paused: “Macintosh HD” is full."),
        Case(Copy.Banner.paused(.diskFull(volume: "Macintosh HD", neededBytes: 600_000_000), done: 1, total: 2, locale: us).message,
             "Free up about 0.6 GB, then resume."),
        Case(Copy.Banner.paused(.outputNotWritable(path: "/Volumes/X/Deliveries"), done: 1, total: 2, locale: us).title,
             "Paused: holdmybyte can’t write to “Deliveries”."),
        Case(Copy.Banner.paused(.outputNotWritable(path: "/Volumes/X/Deliveries"), done: 1, total: 2, locale: us).message,
             "Check the folder’s permissions, then resume."),
        Case(Copy.Banner.stopped(done: 312, total: 535, locale: us).title, "Stopped"),
        Case(Copy.Banner.stopped(done: 312, total: 535, locale: us).message,
             "312 of 535 photos are in the delivery folders. The rest can be finished any time."),
        Case(Copy.Banner.interrupted(done: 312, total: 535, locale: us).title, "Compression was interrupted"),
        Case(Copy.Banner.interrupted(done: 312, total: 535, locale: us).message,
             "312 of 535 photos are done and safe. Continue where it stopped?"),
        Case(Copy.Banner.stopHere, "Stop Here"),
        // S10
        Case(Copy.Done.title("Finn und Lissy", issues: 0), "Finn und Lissy is ready"),
        Case(Copy.Done.subtitle(photos: 535, deliveries: 2, seconds: 252, locale: us),
             "535 photos · 2 deliveries · finished in 4 min 12 s · every photo verified"),
        Case(Copy.Done.fromLine(source: 10_950_000_000, fraction: 0.877, locale: de), "from 10,95 GB · −88\u{00A0}%"),
        Case(Copy.Done.fromLine(source: 10_950_000_000, fraction: 0.877, locale: us), "from 10.95 GB · −88%"),
        Case(Copy.Done.resizedLine(longEdge: 2560, format: .webp, bytes: 159_000_000, photos: 535, locale: us),
             "2560 px · WebP · 159 MB for 535 photos"),
        Case(Copy.Done.keptOriginal(7), "7 photos kept as original. They were already as small as this quality allows."),
        Case(Copy.Done.proofLine(quality: .high, lowest: 85.0), "Every photo ≥ 85 · lowest 85.0"),
        Case(Copy.Done.proofLine(quality: .balanced, lowest: 74.0), "Every photo met its target · lowest 74.0"),
        Case(Copy.Done.archiveProofLine, "Byte-exact: every file restores to the identical original"),
        Case(Copy.Done.proofTitle(met: 535, total: 535, locale: us), "535 of 535 photos met their quality target"),
        Case(Copy.Done.proofDetail(lowest: 85.0, median: 85.5, highest: 87.3),
             "Each delivered photo was compared with its original. Lowest 85.0 · median 85.5 · highest 87.3."),
        Case(Copy.Done.spotCheck, "Spot-Check the Hardest Photos"),
        Case(Copy.Done.lowestFive, "Lowest five"),
        Case(Copy.Done.archiveOnly(byteExact: 535, total: 535, locale: us), "Byte-exact: 535 of 535 files restore to the identical original."),
        Case(Copy.Done.explainerIntro, "holdmybyte measures every delivered photo against its original with SSIMULACRA2, an open perceptual "
             + "metric. Higher is closer to the original; 100 means identical."),
        Case(Copy.Done.histogramSummary(photos: 535, lowest: 85.0, median: 85.5, floor: 85),
             "535 photos, lowest 85.0, median 85.5, all at or above 85"),
        Case(Copy.Done.gridTitle(535, locale: us), "535 Photos"),
        Case(Copy.Done.sortName(.captureTime), "Capture Time"),
        Case(Copy.Done.sortName(.lowestScore), "Lowest Score First"),
        Case(Copy.Done.sortName(.largestSavings), "Largest Savings First"),
        Case(Copy.Done.sortName(.smallestSavings), "Smallest Savings First"),
        Case(Copy.Done.issuesOnly, "Issues Only"),
        Case(Copy.Done.cellCaption(fraction: 0.88, score: 85.4, locale: de), "−88\u{00A0}% · 85.4"),
        Case(Copy.Done.cellAccessibility(fileName: "DSC09412", status: "done", fraction: 0.88, score: 85.4),
             "DSC09412, done, 88 percent smaller, score 85.4"),
        // S11
        Case(Copy.Done.title("Finn und Lissy", issues: 3), "Finn und Lissy is ready, with 3 issues"),
        Case(Copy.Done.title("Finn und Lissy", issues: 1), "Finn und Lissy is ready, with 1 issue"),
        Case(Copy.Done.subtitleWithIssues(photos: 535, deliveries: 2, verified: 532, issues: 3, locale: us),
             "535 photos · 2 deliveries · 532 verified · 3 need attention"),
        Case(Copy.Issues.heading(.unreadable, count: 2, delivery: nil),
             "Couldn’t read 2 photos. The files are damaged or incomplete. They are missing from every delivery."),
        Case(Copy.Issues.heading(.cmykUnsupported, count: 2, delivery: nil),
             "2 photos are CMYK, which isn’t supported yet. Export them as RGB from Lightroom."),
        Case(Copy.Issues.heading(.encodeFailed, count: 1, delivery: "Website"),
             "Website: 1 photo couldn’t be saved. Try again; if it fails again, the file is unusual. Please send the log."),
        Case(Copy.Issues.heading(.writeFailed, count: 1, delivery: "Couple’s Package"),
             "Couple’s Package: 1 photo couldn’t be saved to the delivery folder."),
        Case(Copy.Issues.heading(.sourceMissing, count: 1, delivery: nil), "1 photo is no longer in the wedding folder."),
        Case(Copy.Issues.showOriginal, "Show Original"),
        Case(Copy.Issues.tryAgain, "Try Again"),
        Case(Copy.Issues.tryAgainForAll, "Try Again for All"),
        Case(Copy.Done.deliveredLine(delivered: 532, total: 535, locale: us), "532 of 535 photos delivered"),
        // S12
        Case(Copy.MissingFolder.title, "The delivery folder has moved or was deleted."),
        Case(Copy.MissingFolder.message(URL(fileURLWithPath: "/Users/sebastian/Weddings/Finn und Lissy/Finn und Lissy – Deliveries"),
                                        home: URL(fileURLWithPath: "/Users/sebastian")),
             "Last seen at ~/Weddings/Finn und Lissy/Finn und Lissy – Deliveries."),
        Case(Copy.MissingFolder.locate, "Locate…"),
        Case(Copy.MissingFolder.removeFromHistory, "Remove from History…"),
        // S13
        Case(Copy.Failed.title("Finn und Lissy"), "Couldn’t compress “Finn und Lissy”"),
        Case(Copy.Failed.tryAgain, "Try Again"),
        Case(Copy.Failed.remove, "Remove"),
        // Sidebar, S15
        Case(Copy.Sidebar.newWedding, "New Wedding"),
        Case(Copy.Sidebar.inProgress, "In Progress"),
        Case(Copy.Sidebar.queued, "Queued"),
        Case(Copy.Sidebar.searchPrompt, "Search Weddings"),
        Case(Copy.Sidebar.rowSubtitle(date: july12, photos: 535, locale: us, timeZone: berlin), "Jul 12 · 535 photos"),
        Case(Copy.monthYear(july12, locale: us, timeZone: berlin), "July 2026"),
        Case(Copy.Sidebar.lifetime(savedBytes: 1_240_000_000_000, weddings: 38, locale: us), "1.24 TB saved across 38 weddings"),
        // §2.2 toolbar
        Case(Copy.Toolbar.subtitle(photos: 535, bytes: 10_950_000_000, locale: us), "535 photos · 10.95 GB"),
        Case(Copy.Toolbar.compareHelp, "Compare photos (⌘Y)"),
        Case(Copy.Toolbar.createMore, "Create More Deliveries…"),
        Case(Copy.Toolbar.rename, "Rename…"),
        Case(Copy.Toolbar.removeFromHistory, "Remove from History…"),
        // S17
        Case(Copy.StatusItem.percent(0.58, locale: de), "58\u{00A0}%"),
        Case(Copy.StatusItem.pause, "Pause"),
        Case(Copy.StatusItem.resume, "Resume"),
        Case(Copy.StatusItem.stop, "Stop…"),
        Case(Copy.StatusItem.open, "Open holdmybyte"),
        // S19
        Case(Copy.Notification.pausedByDrive(volume: "Wedding SSD").title, "Paused: “Wedding SSD” was disconnected."),
        Case(Copy.Notification.showInFinder, "Show in Finder"),
        Case(Copy.Notification.compare, "Compare"),
    ]

    @Test(arguments: cases) func copyMatchesSpec(_ c: Case) {
        #expect(c.actual == c.expected)
    }

    @Test func approximateDurations() {
        #expect(Copy.approximateDuration(30) == "less than a minute")
        #expect(Copy.approximateDuration(294) == "about 5 min")
        #expect(Copy.approximateDuration(4800) == "about 1 h 20 min")
    }

    @Test func notificationCopy() {
        let clean = Fixtures.only([.couple, .website], of: Fixtures.finnUndLissy)
        let text = Copy.Notification.finished(clean, locale: Self.de)
        #expect(text.title == "Finn und Lissy is ready")
        #expect(text.body == "Couple’s Package 1,35 GB (−88\u{00A0}%) · Website 159 MB · every photo verified.")
        let issues = Copy.Notification.finished(Fixtures.withIssues(clean), locale: Self.us)
        #expect(issues.title == "Finn und Lissy is ready, with 3 issues")
        #expect(issues.body == "532 of 535 photos delivered. Open holdmybyte to see what happened.")
    }

    @Test func alertCopy() {
        var state = AppState()
        let (record, progress) = Fixtures.inProgress(Fixtures.finnUndLissy, done: 312)
        state.records = [record] + Fixtures.history.filter { $0.id != record.id }
        state.live[record.id] = progress
        let stop = AppAlert.stop(record.id).copy(in: state, locale: Self.us)
        #expect(stop.title == "Stop compressing “Finn und Lissy”?")
        #expect(stop.message == "The 312 finished photos stay in the delivery folders. You can finish the rest later.")
        #expect(stop.buttons == ["Stop", "Continue"] && AppAlert.stop(record.id).defaultButtonIndex == 1)
        let quit = AppAlert.quitWhileRunning(record.id).copy(in: state, locale: Self.us)
        #expect(quit.title == "Stop compressing “Finn und Lissy” and quit?")
        #expect(quit.message == "312 of 535 photos are done. holdmybyte will offer to resume next time it opens.")
        #expect(quit.buttons == ["Quit", "Cancel"] && AppAlert.quitWhileRunning(record.id).defaultButtonIndex == 1)
        let remove = AppAlert.removeFromHistory(record.id).copy(in: state, locale: Self.us)
        #expect(remove.title == "Remove “Finn und Lissy” from history?")
        #expect(remove.message == "The delivered photos stay where they are. Only this entry is removed.")
        #expect(remove.buttons == ["Remove", "Cancel"] && AppAlert.removeFromHistory(record.id).destructiveButtonIndex == 0)
        let clear = AppAlert.clearHistory.copy(in: state, locale: Self.us)
        #expect(clear.title == "Clear the history of all 37 weddings?")   // Finn und Lissy is in progress here
        #expect(clear.message == "Delivered photos are not touched.")
        #expect(clear.buttons == ["Clear", "Cancel"])
    }
}
