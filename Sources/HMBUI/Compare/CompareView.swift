// WP0 stub; WP4 owns this file (§2.4 S14: Compare).
import SwiftUI
import HMBModel

public struct CompareView: View {
    @Bindable public var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Tokens.Palette.compareSurround.ignoresSafeArea()
    }
}
