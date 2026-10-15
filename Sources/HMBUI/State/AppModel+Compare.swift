// WP4 (Docs/SPEC.md §5.0.3, §2.4 S14): the Compare state machine. The view only calls these; every rule
// (spot-check count and toast, hold vs latch, no-original restrictions, kept zoom) lives here or in CompareLogic.
import SwiftUI
import HMBModel

extension AppModel {
    // MARK: Frozen API

    /// Opens Compare for `route` and pushes it on the detail stack (unless it is already on top).
    /// The archive is never compared: a non-lossy delivery falls back to the wedding's first lossy delivery.
    /// A spot-check starts in Lowest Score First, otherwise in capture order. Viewing preferences (mode, zoom,
    /// centre, inspector) carry over from a previous Compare of the same wedding.
    public func openCompare(_ route: CompareRoute) {
        guard let compare = Self.compareState(for: route, records: state.records, previous: state.compare) else { return }
        state.compare = compare
        if state.detailPath.last != route && state.detailPath.last != compare.route { state.detailPath.append(compare.route) }
    }

    /// The state `openCompare(route)` produces (nil: nothing to compare). Also used to build snapshot states.
    public nonisolated static func compareState(for route: CompareRoute, records: [WeddingRecord],
                                                previous: CompareState? = nil) -> CompareState? {
        guard let record = records.first(where: { $0.id == route.wedding }),
              let delivery = CompareSequence.resolvedDelivery(route.delivery, in: record) else { return nil }
        let order: CompareOrder = route.spotCheck ? .lowestScore : .captureTime
        let sequence = CompareSequence.make(record, delivery: delivery, order: order)
        guard !sequence.isEmpty else { return nil }
        var resolved = route
        resolved.delivery = delivery
        var compare = CompareState(route: resolved, order: order, sequence: sequence,
                                   position: sequence.firstIndex(of: route.start) ?? 0)
        if let previous, previous.route.wedding == route.wedding {
            compare.mode = previous.mode
            compare.zoom = previous.zoom
            compare.zoomCenter = previous.zoomCenter
            compare.divider = previous.divider
            compare.showsInspector = previous.showsInspector
        }
        compare.normalise()
        return compare
    }

    /// Leaves Compare (Back, Esc, ⌘[): pops the route and forgets the compare state and its toast.
    public func closeCompare() {
        if let compare = state.compare {
            if let toast = state.toast, toast == CompareCopy.spotCheckToast(CompareSequence.hardestCount(compare.sequence.count)) {
                state.toast = nil
            }
        }
        state.compare = nil
        if !state.detailPath.isEmpty { state.detailPath.removeLast() }
    }

    /// Applies `body` to the compare state, then re-establishes its invariants (see `CompareState.normalise`).
    public func updateCompare(_ body: (inout CompareState) -> Void) {
        guard var compare = state.compare else { return }
        body(&compare)
        compare.normalise()
        if compare != state.compare { state.compare = compare }
    }

    /// Next (+1) or previous (−1) photo. Zoom, centre, mode and the Show Original latch are kept.
    /// In a spot-check (Lowest Score First), stepping forward from the K-th photo shows the one-time toast.
    public func stepCompare(by delta: Int) {
        guard var compare = state.compare, !compare.sequence.isEmpty, delta != 0 else { return }
        let old = compare.position
        compare.position = min(compare.sequence.count - 1, max(0, old + delta))
        if delta > 0, compare.route.spotCheck, compare.order == .lowestScore, !compare.spotCheckToastShown {
            let k = CompareSequence.hardestCount(compare.sequence.count)
            if old <= k - 1, old + delta > k - 1 {
                compare.spotCheckToastShown = true
                state.toast = CompareCopy.spotCheckToast(k)
            }
        }
        compare.normalise()
        if compare != state.compare { state.compare = compare }
    }

    // MARK: Additions (WP4) — used by CompareView and available to AppCommands (WP3)

    /// The record Compare shows.
    public var compareRecord: WeddingRecord? {
        guard let id = state.compare?.route.wedding else { return nil }
        return state.records.first { $0.id == id }
    }

    /// Changes the order (HUD menu), staying on the current photo.
    public func setCompareOrder(_ order: CompareOrder) {
        guard let compare = state.compare, let record = compareRecord else { return }
        let current = compare.currentPhoto
        let sequence = CompareSequence.make(record, delivery: compare.route.delivery, order: order)
        updateCompare {
            $0.order = order
            $0.sequence = sequence
            $0.position = current.flatMap { sequence.firstIndex(of: $0) } ?? 0
        }
    }

    /// Switches the compared delivery (toolbar Delivery menu), staying on the current photo when it was delivered.
    public func setCompareDelivery(_ delivery: DeliveryID) {
        guard let compare = state.compare, let record = compareRecord,
              let resolved = CompareSequence.resolvedDelivery(delivery, in: record), resolved == delivery,
              delivery != compare.route.delivery else { return }
        let current = compare.currentPhoto
        let sequence = CompareSequence.make(record, delivery: delivery, order: compare.order)
        guard !sequence.isEmpty else { return }
        updateCompare {
            $0.route.delivery = delivery
            $0.sequence = sequence
            $0.position = current.flatMap { sequence.firstIndex(of: $0) } ?? 0
        }
    }

    /// `Y`: Split ⇄ Side by Side (needs the original).
    public func toggleCompareMode() {
        updateCompare { compare in
            guard compare.canSplit else { return }
            compare.mode = compare.mode == .split ? .sideBySide : .split
        }
    }

    /// `D`: amplified differences on/off (needs the original).
    public func toggleCompareDifferences() {
        updateCompare { compare in
            guard compare.canShowDifferences else { return }
            compare.showsDifferences.toggle()
        }
    }

    /// `I` / ⌥⌘I: inspector on/off.
    public func toggleCompareInspector() {
        updateCompare { $0.showsInspector.toggle() }
    }

    /// Menu command "Show Original": latches the original on, or turns a shown original off.
    public func toggleCompareOriginalLatch() {
        updateCompare { compare in
            guard compare.canShowOriginal else { return }
            if compare.showsOriginal {
                compare.showsOriginal = false
            } else {
                compare.showsOriginal = true
                compare.originalLatched = true
            }
        }
    }

    /// `\` key down. Returns whether this press started showing the original (pass it to `compareOriginalKeyUp`).
    public func compareOriginalKeyDown() -> Bool {
        var started = false
        updateCompare { started = $0.originalKeyDown() }
        return started
    }

    /// `\` key up after `heldFor` seconds: within 200 ms the original latches on, otherwise it goes away.
    public func compareOriginalKeyUp(heldFor: TimeInterval, pressStarted: Bool) {
        updateCompare { $0.originalKeyUp(heldFor: heldFor, pressStarted: pressStarted) }
    }

    /// The `\` key-up was lost (the window stopped being key while `\` was held): ends the hold, keeps a latch.
    public func compareOriginalHoldInterrupted() {
        updateCompare { $0.originalHoldInterrupted() }
    }

    /// Fit ⇄ 100 % around `center` (unit image coordinates of the point that should end up in the middle).
    /// Without a point (menu command), 100 % opens on the kept centre.
    public func toggleCompareZoom(center: CGPoint? = nil) {
        updateCompare { compare in
            if compare.zoom == .fit {
                compare.zoom = .actual
                if let center { compare.zoomCenter = center }
            } else {
                compare.zoom = .fit
            }
        }
    }

    /// Set by the view once a pair has loaded: whether the original could be read.
    public func setCompareOriginalAvailable(_ available: Bool) {
        updateCompare { $0.originalAvailable = available }
    }
}
