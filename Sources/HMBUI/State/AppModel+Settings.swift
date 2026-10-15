// WP0 stub (Docs/SPEC.md §5.0.3); WP4 owns this file and implements every body.
import SwiftUI
import HMBModel

extension AppModel {
    public func editDelivery(_ preset: DeliveryPreset) {}
    public func addDelivery() {}
    public func savePreset(_ preset: DeliveryPreset) {}
    public func deletePreset(_ id: DeliveryID) {}
    public func movePresets(from: IndexSet, to: Int) {}
    public func setDefaultOn(_ id: DeliveryID, _ on: Bool) {}
    public func restoreDefaultDeliveries() {}
    public func updateSettings(_ body: (inout AppSettings) -> Void) {}
    public func clearHistory() {}
    public func resetLearnedEstimates() {}
}
