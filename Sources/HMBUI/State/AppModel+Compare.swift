// WP0 stub (Docs/SPEC.md §5.0.3); WP4 owns this file and implements every body.
import SwiftUI
import HMBModel

extension AppModel {
    public func openCompare(_ route: CompareRoute) {}
    public func closeCompare() {}
    public func updateCompare(_ body: (inout CompareState) -> Void) {}
    public func stepCompare(by delta: Int) {}
}
