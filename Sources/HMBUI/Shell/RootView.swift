// WP0 stub; WP3 owns this file (§2.1–§2.4: sidebar, drop zone, setup, run and done views).
import SwiftUI
import HMBModel

public struct RootView: View {
    @Bindable public var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ContentUnavailableView("holdmybyte", systemImage: "photo.stack",
                               description: Text("Scaffold (WP0). The app shell arrives with WP3."))
            .frame(minWidth: Tokens.Layout.windowMinimum.width, minHeight: Tokens.Layout.windowMinimum.height)
            .hmbAccent()
    }
}
