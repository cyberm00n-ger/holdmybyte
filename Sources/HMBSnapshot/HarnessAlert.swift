// Alert copy for the harness (§2.3, §2.4 S9, S18): a forward to WP3's `AppAlert.copy(in:locale:)`, the single source
// of this copy (§5.3), plus its default and destructive button indices.
import Foundation
import HMBModel
import HMBUI

struct AlertContent: Equatable {
    var title: String
    var message: String
    /// Display order, left to right.
    var buttons: [String]
    /// Index into `buttons` of the default (Return) button.
    var defaultButton: Int
    /// Index of the destructive button, if any.
    var destructiveButton: Int?
}

enum HarnessAlert {
    static func copy(for alert: AppAlert, in state: AppState, locale: Locale) -> AlertContent {
        let copy = alert.copy(in: state, locale: locale)
        return AlertContent(title: copy.title, message: copy.message, buttons: copy.buttons,
                            defaultButton: alert.defaultButtonIndex, destructiveButton: alert.destructiveButtonIndex)
    }
}
