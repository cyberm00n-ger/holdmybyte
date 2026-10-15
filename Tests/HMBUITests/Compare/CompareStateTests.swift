// WP4 acceptance 1 (Docs/SPEC.md §5.4): the Compare state machine.
import CoreGraphics
import Foundation
import HMBFixtures
import HMBModel
@testable import HMBUI
import Testing

@MainActor func makeModel(records: [WeddingRecord] = [Fixtures.finnUndLissy], engine: FixtureEngine = FixtureEngine(),
                          presets: InMemoryPresets = InMemoryPresets(), settings: InMemorySettings = InMemorySettings(),
                          history: InMemoryHistory? = nil) -> AppModel {
    var state = AppState()
    state.records = records
    return AppModel(state: state, engine: engine, history: history ?? InMemoryHistory(records), presetsStore: presets,
                    settingsStore: settings, thumbnails: FixtureThumbnails(photoFolder: nil))
}

@MainActor @Suite struct CompareStateTests {
    static let wedding = Fixtures.finnUndLissyID

    /// Opens Compare; a spot-check starts on the lowest-scoring photo (as the proof card does) unless `start` is given.
    func open(_ model: AppModel, delivery: DeliveryID = .couple, start: Int? = nil, spotCheck: Bool = false) {
        var first = PhotoID(start ?? 0)
        if spotCheck, start == nil, let record = model.state.records.first,
           let lowest = CompareSequence.make(record, delivery: delivery, order: .lowestScore).first {
            first = lowest
        }
        model.openCompare(CompareRoute(wedding: Self.wedding, delivery: delivery, start: first, spotCheck: spotCheck))
    }

    @Test func openPushesRouteInCaptureOrderAtTheStartPhoto() throws {
        let model = makeModel()
        open(model, start: 200)
        let compare = try #require(model.state.compare)
        #expect(compare.order == .captureTime)
        #expect(compare.sequence == (0..<535).map(PhotoID.init))
        #expect(compare.position == 200)
        #expect(model.state.detailPath == [compare.route])
        // Opening the route that is already on top does not push it twice.
        open(model, start: 200)
        #expect(model.state.detailPath.count == 1)
    }

    @Test func spotCheckStartsLowestScoreFirst() throws {
        let model = makeModel()
        let lowest = CompareSequence.make(Fixtures.finnUndLissy, delivery: .couple, order: .lowestScore)
        open(model, start: lowest[0].index, spotCheck: true)
        let compare = try #require(model.state.compare)
        #expect(compare.order == .lowestScore && compare.position == 0)
        let results = CompareSequence.deliveredResults(Fixtures.finnUndLissy, delivery: .couple)
        let scores = compare.sequence.compactMap { results[$0]?.score }
        #expect(scores == scores.sorted())
        #expect(scores.first == 74.0)
        #expect(CompareCopy.counter(compare, locale: Locale(identifier: "en_US")) == "Hardest 1 of 12")
    }

    @Test func archiveIsExcluded() throws {
        let model = makeModel()
        open(model, delivery: .archive, start: 3)
        #expect(model.state.compare?.route.delivery == .couple)            // falls back to the first lossy delivery
        #expect(model.state.compare?.position == 3)
        model.setCompareDelivery(.archive)
        #expect(model.state.compare?.route.delivery == .couple)
        #expect(!CompareSequence.lossyDeliveries(Fixtures.finnUndLissy).contains { $0.id == .archive })
        // A wedding with only the archive has nothing to compare.
        let archiveOnly = Fixtures.only([.archive], of: Fixtures.finnUndLissy)
        let other = makeModel(records: [archiveOnly])
        open(other, delivery: .archive)
        #expect(other.state.compare == nil && other.state.detailPath.isEmpty)
    }

    @Test func failedPhotosAreNotInTheSequenceAndKeptOriginalsComeLast() throws {
        let model = makeModel(records: [Fixtures.withIssues(Fixtures.keptOriginal(7))])
        open(model, spotCheck: true)
        let compare = try #require(model.state.compare)
        #expect(compare.sequence.count == 533)
        #expect(!compare.sequence.contains(PhotoID(41)) && !compare.sequence.contains(PhotoID(207)))
        let results = CompareSequence.deliveredResults(model.state.records[0], delivery: .couple)
        #expect(compare.sequence.suffix(7).allSatisfy { results[$0]?.status == .keptOriginal })
    }

    @Test func nextAndPreviousKeepZoomCentreModeAndLatch() throws {
        let model = makeModel()
        open(model, start: 10)
        model.updateCompare {
            $0.zoom = .actual
            $0.zoomCenter = CGPoint(x: 0.3, y: 0.7)
            $0.mode = .sideBySide
            $0.divider = 0.25
        }
        _ = model.compareOriginalKeyDown()
        model.compareOriginalKeyUp(heldFor: 0.05, pressStarted: true)
        model.stepCompare(by: 1)
        model.stepCompare(by: 1)
        model.stepCompare(by: -1)
        let compare = try #require(model.state.compare)
        #expect(compare.position == 11)
        #expect(compare.zoom == .actual && compare.zoomCenter == CGPoint(x: 0.3, y: 0.7))
        #expect(compare.mode == .sideBySide && compare.divider == 0.25)
        #expect(compare.showsOriginal && compare.originalLatched)
        // Clamped at both ends.
        model.stepCompare(by: -100)
        #expect(model.state.compare?.position == 0)
        model.stepCompare(by: 10_000)
        #expect(model.state.compare?.position == 534)
    }

    @Test func spotCheckCount() {
        #expect(CompareSequence.hardestCount(535) == 12)     // ceil(16.05) clamped to 12
        #expect(CompareSequence.hardestCount(100) == 5)      // ceil(3) raised to 5
        #expect(CompareSequence.hardestCount(300) == 9)
        #expect(CompareSequence.hardestCount(167) == 6)      // ceil(5.01)
        #expect(CompareSequence.hardestCount(400) == 12)
        #expect(CompareSequence.hardestCount(3) == 3)        // never more than there are photos
        #expect(CompareSequence.hardestCount(0) == 0)
    }

    @Test func toastFiresOnceAfterTheKthPhoto() throws {
        let model = makeModel()
        open(model, spotCheck: true)
        for _ in 0..<11 { model.stepCompare(by: 1) }           // now on the 12th (K-th) photo
        #expect(model.state.toast == nil)
        #expect(CompareCopy.counter(model.state.compare!, locale: Locale(identifier: "en_US")) == "Hardest 12 of 12")
        model.stepCompare(by: 1)
        #expect(model.state.toast == "You’ve checked the 12 hardest photos. Everything else scored higher.")
        #expect(model.state.compare?.spotCheckToastShown == true)
        #expect(CompareCopy.counter(model.state.compare!, locale: Locale(identifier: "en_US")) == "13 of 535")
        model.state.toast = nil                                // dismissed after 2.5 s
        model.stepCompare(by: -1)
        model.stepCompare(by: 1)
        model.stepCompare(by: 1)
        #expect(model.state.toast == nil)                      // once
    }

    @Test func toastWhenTheWeddingHasOnlyKPhotos() throws {
        var record = Fixtures.finnUndLissy
        record.photos = Array(record.photos.prefix(5))
        record.results = record.results.filter { $0.photo.index < 5 }
        let model = makeModel(records: [record])
        open(model, spotCheck: true)
        for _ in 0..<4 { model.stepCompare(by: 1) }
        #expect(model.state.toast == nil)
        model.stepCompare(by: 1)                               // "next" on the last (K-th) photo
        #expect(model.state.toast == "You’ve checked the 5 hardest photos. Everything else scored higher.")
    }

    @Test func noToastOutsideSpotCheck() {
        let model = makeModel()
        open(model)
        for _ in 0..<20 { model.stepCompare(by: 1) }
        #expect(model.state.toast == nil)
    }

    @Test func showOriginalHoldVersusLatch() throws {
        let model = makeModel()
        open(model)
        // Hold (released after 200 ms or more): shown while held, gone after.
        let held = model.compareOriginalKeyDown()
        #expect(held && model.state.compare?.showsOriginal == true)
        #expect(model.compareOriginalKeyDown() == false)       // key repeat
        model.compareOriginalKeyUp(heldFor: 0.35, pressStarted: held)
        #expect(model.state.compare?.showsOriginal == false && model.state.compare?.originalLatched == false)
        // Exactly at the threshold counts as a hold.
        let edge = model.compareOriginalKeyDown()
        model.compareOriginalKeyUp(heldFor: 0.2, pressStarted: edge)
        #expect(model.state.compare?.showsOriginal == false)
        // Tap (released within 200 ms): latched on.
        let tap = model.compareOriginalKeyDown()
        model.compareOriginalKeyUp(heldFor: 0.12, pressStarted: tap)
        #expect(model.state.compare?.showsOriginal == true && model.state.compare?.originalLatched == true)
        // The next press releases the latch; its key-up changes nothing.
        let release = model.compareOriginalKeyDown()
        #expect(!release)
        #expect(model.state.compare?.showsOriginal == false && model.state.compare?.originalLatched == false)
        model.compareOriginalKeyUp(heldFor: 0.05, pressStarted: release)
        #expect(model.state.compare?.showsOriginal == false)
    }

    @Test func lostKeyUpEndsTheHoldButKeepsALatch() throws {
        let model = makeModel()
        open(model)
        // Held, then the window lost key status: the key-up never arrives.
        #expect(model.compareOriginalKeyDown())
        model.compareOriginalHoldInterrupted()
        #expect(model.state.compare?.showsOriginal == false)
        // The next press works normally again (shows, and a tap latches).
        let tap = model.compareOriginalKeyDown()
        #expect(tap && model.state.compare?.showsOriginal == true)
        model.compareOriginalKeyUp(heldFor: 0.1, pressStarted: tap)
        // A latch is a deliberate state: losing focus keeps it.
        model.compareOriginalHoldInterrupted()
        #expect(model.state.compare?.showsOriginal == true && model.state.compare?.originalLatched == true)
    }

    @Test func noOriginalDisablesSplitBackslashAndDifferences() throws {
        let model = makeModel()
        open(model)
        model.updateCompare { $0.showsDifferences = true; $0.showsOriginal = true; $0.originalLatched = true }
        model.setCompareOriginalAvailable(false)
        var compare = try #require(model.state.compare)
        #expect(!compare.showsDifferences && !compare.showsOriginal && !compare.originalLatched)
        #expect(!compare.canSplit && !compare.canShowOriginal && !compare.canShowDifferences)
        #expect(model.compareOriginalKeyDown() == false)
        model.toggleCompareDifferences()
        model.toggleCompareOriginalLatch()
        model.toggleCompareMode()
        model.updateCompare { $0.showsDifferences = true }      // even a direct change is undone
        compare = try #require(model.state.compare)
        #expect(!compare.showsDifferences && !compare.showsOriginal && compare.mode == .split)
        // The canvas shows the delivered photo alone, in one pane.
        let plan = CompareCanvasPlan(.init(geometry: CompareGeometry(viewSize: CGSize(width: 1000, height: 700),
                                                                     imageSize: CGSize(width: 3000, height: 2000),
                                                                     backingScale: 2, mode: .sideBySide),
                                           zoom: .fit, center: CGPoint(x: 0.5, y: 0.5), divider: 0.5, showsOriginal: false,
                                           showsDifferences: false, originalAvailable: false, hasOriginalImage: false,
                                           hasDifferencesImage: false))
        #expect(plan.placements[.delivered]?.visible == true)
        #expect(plan.placements[.delivered]?.clip == CGRect(x: 0, y: 0, width: 1000, height: 700))
        #expect(plan.placements.filter { $0.value.visible }.count == 1)
        #expect(plan.dividerX == nil)
        // Reconnected: available again.
        model.setCompareOriginalAvailable(true)
        model.toggleCompareMode()
        #expect(model.state.compare?.mode == .sideBySide)
    }

    @Test func orderAndDeliveryChangesStayOnThePhoto() throws {
        let model = makeModel()
        open(model, start: 77)
        model.setCompareOrder(.largestSavings)
        var compare = try #require(model.state.compare)
        #expect(compare.order == .largestSavings && compare.currentPhoto == PhotoID(77))
        let results = CompareSequence.deliveredResults(Fixtures.finnUndLissy, delivery: .couple)
        let fractions = compare.sequence.map { CompareSequence.savedFraction(results[$0]) }
        #expect(fractions == fractions.sorted(by: >))
        model.setCompareDelivery(.website)
        compare = try #require(model.state.compare)
        #expect(compare.route.delivery == .website && compare.currentPhoto == PhotoID(77))
    }

    @Test func closePopsAndForgets() {
        let model = makeModel()
        open(model, spotCheck: true)
        for _ in 0..<12 { model.stepCompare(by: 1) }
        #expect(model.state.toast != nil)
        model.closeCompare()
        #expect(model.state.compare == nil && model.state.detailPath.isEmpty && model.state.toast == nil)
    }

    @Test func invariantsAreKept() throws {
        let model = makeModel()
        open(model)
        model.updateCompare { $0.divider = 3; $0.zoomCenter = CGPoint(x: -1, y: CGFloat.nan); $0.position = 9_999 }
        let compare = try #require(model.state.compare)
        #expect(compare.divider == 1 && compare.zoomCenter == CGPoint(x: 0, y: 0.5) && compare.position == 534)
        model.updateCompare { $0.divider = -0.4 }
        #expect(model.state.compare?.divider == 0)
    }

    @Test func zoomToggleAndReopenKeepPreferences() throws {
        let model = makeModel()
        open(model)
        model.toggleCompareZoom(center: CGPoint(x: 0.2, y: 0.8))
        #expect(model.state.compare?.zoom == .actual && model.state.compare?.zoomCenter == CGPoint(x: 0.2, y: 0.8))
        model.toggleCompareZoom()
        #expect(model.state.compare?.zoom == .fit && model.state.compare?.zoomCenter == CGPoint(x: 0.2, y: 0.8))
        model.toggleCompareInspector()
        model.toggleCompareMode()
        open(model, start: 5)                                   // e.g. clicking another proof thumbnail
        #expect(model.state.compare?.showsInspector == true && model.state.compare?.mode == .sideBySide)
    }

    @Test func hudAndLabelCopy() {
        let en = Locale(identifier: "en_US"), de = Locale(identifier: "en_DE")
        // Byte and percent text comes from HMBFormat (WP0: Finder-style, "2.6 MB").
        #expect(CompareCopy.sizeLine(original: 21_400_000, delivered: 2_610_000, locale: en)
                == "\(HMBFormat.bytes(21_400_000, locale: en)) → \(HMBFormat.bytes(2_610_000, locale: en)) · −88%")
        #expect(CompareCopy.sizeLine(original: 21_400_000, delivered: 2_610_000, locale: de)
                == "21,4 MB → \(HMBFormat.bytes(2_610_000, locale: de)) · −88\u{00A0}%")
        #expect(CompareCopy.originalLabel(bytes: 21_400_000, available: true, locale: en) == "Original · 21.4 MB")
        #expect(CompareCopy.originalLabel(bytes: 21_400_000, available: false, locale: en) == "Original not available")
        #expect(CompareCopy.deliveredLabel(bytes: 2_610_000, locale: en) == "Delivered · \(HMBFormat.bytes(2_610_000, locale: en))")
        #expect(CompareCopy.connectVolume("Wedding SSD") == "Connect “Wedding SSD” to compare.")
        #expect(CompareCopy.comparedResized(2560, locale: de) == "Compared with the original resized to 2560 px.")
        #expect(CompareCopy.targetLine(target: 85, quality: .high) == "Target 85 · High")
        #expect(CompareCopy.differencesLegend == "Differences amplified 10×")
        #expect(CompareCopy.orderTitle(.lowestScore) == "Lowest Score First")
    }
}
