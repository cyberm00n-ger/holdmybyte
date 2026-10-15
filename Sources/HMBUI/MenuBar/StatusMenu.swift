// WP0 stub; WP3 owns this file (§2.4 S17: transient menu-bar status item).
import SwiftUI
import HMBModel

public struct StatusMenu: View {
    @Bindable public var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ProgressView(value: model.overallFraction).padding(Tokens.Spacing.s12)
    }
}
