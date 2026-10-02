import SwiftUI
import SwiftData

struct AddProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var path = ""
    @State private var identityStatus: IdentityStatus?
    @State private var didSubmit = false
    @FocusState private var nameFocused: Bool

    private let identityService: ProjectIdentityServiceProtocol = ProjectIdentityService()
    private let notifier: SyncStateNotifying
    private let intentReconciler: @MainActor (ModelContext) -> BatchResult
    private let onCreated: (Project) -> Void

    init(
        notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
        intentReconciler: @escaping @MainActor (ModelContext) -> BatchResult = { _ in BatchResult() },
        onCreated: @escaping (Project) -> Void = { _ in }
    ) {
        self.notifier = notifier
        self.intentReconciler = intentReconciler
        self.onCreated = onCreated
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Add Project").font(.title2.bold())
            TextField("Project Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(submit)
            HStack {
                TextField("Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Browse…") {
                    browseForDirectory()
                }
            }

            if let identityStatus {
                Text(identityStatus.message)
                    .font(.caption)
                    .foregroundStyle(identityStatus.foregroundStyle)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: submit).keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 450)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard isValid, !didSubmit else { return }
        didSubmit = true
        let created = registerProject(
            makeProject(),
            manifestService: ManifestService(),
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
            path = url.path
            if name.isEmpty {
                name = url.lastPathComponent
            }
            refreshIdentityStatus()
        }
    }

    private func refreshIdentityStatus() {
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        guard !trimmedPath.isEmpty else {
            identityStatus = nil
            return
        }
        identityStatus = IdentityStatus(identity: identityService.peekIdentity(forProjectAt: trimmedPath))
    }

    private func makeProject() -> Project {
        ProjectRegistration.makeProject(
            name: name.trimmingCharacters(in: .whitespaces),
            path: path.trimmingCharacters(in: .whitespaces),
            using: identityService
        )
    }
}

private struct IdentityStatus {
    let message: String
    let foregroundStyle: HierarchicalShapeStyle

    init(identity: ProjectIdentity?) {
        switch identity?.kind {
        case .remote:
            message = "Git remote: \(identity?.key ?? "")"
            foregroundStyle = .secondary
        case .marker:
            message = "Marker found"
            foregroundStyle = .secondary
        case nil:
            message = "Marker will be created on Add"
            foregroundStyle = .tertiary
        }
    }
}
