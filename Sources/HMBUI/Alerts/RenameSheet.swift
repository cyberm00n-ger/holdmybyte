// Rename Wedding sheet (§2.1 Sheets): one field, Cancel (Esc) and Rename (Return).
import HMBModel
import SwiftUI

struct RenameSheet: View {
    let model: AppModel
    let wedding: WeddingID
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField(Copy.Rename.field, text: $name)
                    .onSubmit(save)
            } header: {
                Text(Copy.Rename.title).font(.headline)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(Copy.Rename.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(Copy.Rename.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .hmbGlassButtonStyle(prominent: true)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Tokens.Spacing.s16)
        }
        .onAppear { name = model.record(wedding)?.name ?? "" }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.renameWedding(wedding, to: trimmed)
        dismiss()
    }
}
