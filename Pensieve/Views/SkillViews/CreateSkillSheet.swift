import SwiftUI
import SwiftData

struct CreateSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Bindable var library: SkillLibraryViewModel
    /// Called with the created skill before the sheet dismisses; the window reveals it once the sheet is gone.
    var onCreated: (Skill) -> Void = { _ in }

    @State private var name = ""
    @State private var description = ""
    @State private var tagsText = ""
    @State private var initialBody = "# New Skill\n\nDescribe your skill here.\n"

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Skill")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Form {
                TextField("Name", text: $name)

                TextField("Description", text: $description)

                TextField("Tags (comma-separated)", text: $tagsText)

                Section("Initial Content") {
                    TextEditor(text: $initialBody)
                        .font(.body.monospaced())
                        .frame(minHeight: 150)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                if let error = library.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 500, height: 490)
    }

    private func create() {
        let tags = tagsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let created = library.createSkill(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description,
            body: initialBody,
            tags: tags,
            context: context
        ) {
            onCreated(created)
        }

        if library.error == nil {
            dismiss()
        }
    }
}
