// WP0 stub; WP4 owns this file (§2.4 S16: Settings).
import SwiftUI
import HMBModel

public struct SettingsView: View {
    @Bindable public var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Form { Text("Settings arrive with WP4.") }
            .formStyle(.grouped)
            .frame(width: Tokens.Layout.settingsWidth)
    }
}
