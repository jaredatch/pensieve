import SwiftUI

struct EntityNameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let fieldLabel: String
    let actionTitle: String
    let onCommit: (String) -> Void

    @State private var name: String
    @State private var didSubmit = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
    }

    init(title: String, fieldLabel: String, actionTitle: String,
         initialName: String = "", onCommit: @escaping (String) -> Void) {
        self.title = title
        self.fieldLabel = fieldLabel
        self.actionTitle = actionTitle
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(title).font(.title2.bold())
            TextField(fieldLabel, text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit).keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard isValid, !didSubmit else { return }
        didSubmit = true
        onCommit(trimmedName)
        dismiss()
    }
}
