import SwiftUI
import SwiftData

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var model: AddProjectModel
    @State private var didSubmit = false
    @State private var saveError: String?
    @FocusState private var nameFocused: Bool

    private let notifier: SyncStateNotifying
    private let intentReconciler: @MainActor (ModelContext) -> BatchResult
    private let onCreated: (Project) -> Void

    init(
        model: AddProjectModel = AddProjectModel(),
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        intentReconciler: @escaping @MainActor (ModelContext) -> BatchResult = { _ in BatchResult() },
        onCreated: @escaping (Project) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.notifier = notifier
        self.intentReconciler = intentReconciler
        self.onCreated = onCreated
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Add Project").font(.title2.bold())
            TextField("Project Name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(submit)
            HStack {
                TextField("Path", text: $model.path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Browse…") {
                    browseForDirectory()
                }
            }

            if let message = model.identityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.hasExistingIdentity ? .secondary : .tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: submit).keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 450)
        .alert("Couldn’t Add Project", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .onAppear { nameFocused = true }
        .onDisappear { model.cancelSubmission() }
    }

    private func submit() {
        guard !didSubmit else { return }
        model.submit(onCreated: registerAndDismiss)
    }

    private func registerAndDismiss(_ project: Project) {
        guard !didSubmit else { return }
        do {
            let created = try registerProject(project, context: context,
                intentReconciler: intentReconciler, notifier: notifier)
            didSubmit = true
            onCreated(created)
            dismiss()
        } catch {
            model.allowSubmissionRetry()
            saveError = error.localizedDescription
        }
    }

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"

        if panel.runModal() == .OK, let url = panel.url {
            model.path = url.path
            if model.name.isEmpty {
                model.name = url.lastPathComponent
            }
        }
    }
}
