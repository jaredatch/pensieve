import SwiftUI
import SwiftData

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var model: AddProjectModel
    @State private var didSubmit = false
    @FocusState private var nameFocused: Bool

    private let manifestService: ManifestSnapshotting
    private let manifestRoot: String
    private let notifier: SyncStateNotifying
    private let intentReconciler: @MainActor (ModelContext) -> BatchResult
    private let onCreated: (Project) -> Void

    init(
        model: AddProjectModel = AddProjectModel(),
        manifestService: ManifestSnapshotting = ManifestService(),
        manifestRoot: String = Constants.pensieveBaseDir,
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        intentReconciler: @escaping @MainActor (ModelContext) -> BatchResult = { _ in BatchResult() },
        onCreated: @escaping (Project) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        self.manifestService = manifestService
        self.manifestRoot = manifestRoot
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
        .onAppear { nameFocused = true }
        .onDisappear { model.cancelSubmission() }
    }

    private func submit() {
        guard !didSubmit else { return }
        model.submit(onCreated: registerAndDismiss)
    }

    private func registerAndDismiss(_ project: Project) {
        guard !didSubmit else { return }
        didSubmit = true
        let created = registerProject(
            project,
            manifestService: manifestService,
            manifestRoot: manifestRoot,
            context: context,
            intentReconciler: intentReconciler,
            notifier: notifier
        )
        onCreated(created)
        dismiss()
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
