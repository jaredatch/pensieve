import SwiftUI

enum SkillHistoryRestoreError: Error {
    case skillFilesUnavailable
}

/// The version list and preview in a sheet, kept for the conflict-resolution flow (`ConflictResolutionView`);
/// the skill detail's History is the inline tab (`SkillHistoryTab`, PLAN-34).
struct SkillHistoryView: View {
    let skill: Skill
    let onDismiss: () -> Void

    private let git: GitServiceProtocol
    private let fileService: FileServiceProtocol
    private let store: SkillStoreProtocol
    private let workingDir: String
    private let library: SkillLibraryViewModel?
    private let notifier: SyncStateNotifying

    @State private var presentation = SkillHistoryTabPresentation()

    init(skill: Skill,
         git: GitServiceProtocol,
         fileService: FileServiceProtocol = FileService(),
         store: SkillStoreProtocol,
         workingDir: String,
         library: SkillLibraryViewModel? = nil,
         notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed,
         onDismiss: @escaping () -> Void) {
        self.skill = skill
        self.git = git
        self.fileService = fileService
        self.store = store
        self.workingDir = workingDir
        self.library = library
        self.notifier = notifier
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("History")
                .font(.headline)
            Text(skill.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: Spacing.lg) {
                historyList
                    .frame(width: 260)
                Divider()
                previewPane
            }
            .frame(minHeight: 420)

            if let errorMessage = presentation.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                Button("Cancel") { presentation.close(); onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: restoreSelectedVersion) {
                    HStack {
                        if presentation.restoringVersion != nil { ProgressView().controlSize(.small) }
                        Text("Restore this version")
                    }
                }
                .accessibilityLabel("Restore this version")
                .buttonStyle(.borderedProminent)
                .disabled(presentation.selection == nil || presentation.restoringVersion != nil)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760)
        .task(id: skill.id) {
            await presentation.load(skill: skill, git: git, workingDir: workingDir, selectFirst: true)
        }
        .onChange(of: skill.id) { _, _ in presentation.reset() }
        .onDisappear { presentation.close() }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                if presentation.isLoading {
                    ProgressView("Loading history…")
                } else if presentation.snapshot.versions.isEmpty {
                    Text("No history")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(presentation.snapshot.versions) { commit in
                        commitRow(commit)
                    }
                }
            }
        }
    }

    @ViewBuilder private var previewPane: some View {
        if presentation.readingVersion != nil {
            ProgressView("Loading version…")
        } else if let selection = presentation.selection {
            preview(for: selection)
        } else {
            ContentUnavailableView {
                Label("Select a version", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    func preview(for selection: SkillHistorySelection) -> SkillPreviewView {
        SkillPreviewView(markdownBody: selection.previewBody,
                         imageLoader: PreviewImageLoader(fileService: fileService))
    }

    private func commitRow(_ commit: SkillHistoryVersion) -> some View {
        Button {
            Task { await presentation.read(commit, skill: skill, git: git, workingDir: workingDir, asDiff: false) }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(SkillHistoryPresentation.rowTitle(for: commit))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(SkillHistoryPresentation.rowSubtitle(for: commit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .background(presentation.selection?.sha == commit.sha ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func restoreSelectedVersion() {
        guard let library else { restore(); return }
        library.confirmLeaving(skill) { proceed in if proceed { restore() } }
    }

    private func restore() {
        guard let selection = presentation.selection,
              let version = presentation.snapshot.versions.first(where: { $0.sha == selection.sha }) else { return }
        let restore = presentation.restore(version, skill: skill, git: git, workingDir: workingDir,
            store: store, library: library, notifier: notifier)
        Task {
            if await restore.value {
                presentation.close()
                onDismiss()
            }
        }
    }
}

/// The user-action boundary for a history restore. Keeping this outside the View makes the write,
/// self-write echo registration, and exactly-once nudge one indivisible, directly testable operation.
@MainActor
func restoreSkillHistoryVersion(
    skill: Skill,
    body: String,
    store: SkillStoreProtocol,
    library: SkillLibraryViewModel?,
    notifier: @escaping SyncStateNotifying
) throws {
    if let library, library.isWriteFenced(skill) {
        throw SkillHistoryRestoreError.skillFilesUnavailable
    }
    do {
        try store.writeBody(directoryName: skill.directoryName, body: body)
    } catch {
        let message = "Couldn't restore this version: \(error.localizedDescription)"
        library?.historyRestoreFailureMessage = message
        library?.error = message
        throw error
    }
    StoreRebuildService.refreshIdentity(of: skill, document: body, retainingBOM: true)
    if let library {
        if library.error == library.historyRestoreFailureMessage { library.error = nil }
        library.historyRestoreFailureMessage = nil
    }
    // A draft for this skill is stale once the version is written back — and only then: a refused write keeps it
    // (the sheet was answered at the button, 33.2; batch Layer-2).
    library?.discardDraft(skill)
    if let library {
        library.noteAppAuthoredBody(skill, body: body)
        library.notifySyncedStateMutation()
    } else {
        notifier()
    }
}
