// Hosts the Edit Delivery sheet (S6) in the main window. The sheet itself is WP4's (Sources/HMBUI/EditDelivery/);
// at merge, the lead replaces the body below with WP4's view (see Docs/WP3-NOTES.md, question Q1).
import HMBModel
import SwiftUI

struct EditDeliverySheetHost: View {
    let model: AppModel
    let preset: DeliveryPreset
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s12) {
            Label(preset.name, systemImage: preset.symbol).font(.headline)
            Text(preset.specLine).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(Copy.Setup.cancel, role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.Spacing.s20)
        .frame(width: 500)
    }
}
