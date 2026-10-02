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

    @State private var commits: [GitCommit] = []
    @State private var selection: SkillHistorySelection?
    @State private var errorMessage: String?

    init(skill: Skill,
         git: GitServiceProtocol = GitService(),
         fileService: FileServiceProtocol = FileService(),
         store: SkillStoreProtocol = SkillStore(fileService: FileService()),
         workingDir: String = Constants.pensieveBaseDir,
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

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore this version") {
                    restoreSelectedVersion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760)
        .task { loadHistory() }
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                if commits.isEmpty {
                    Text("No history")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(commits, id: \.sha) { commit in
                        commitRow(commit)
                    }
                }
            }
        }
    }

    @ViewBuilder private var previewPane: some View {
        if let selection {
            SkillPreviewView(markdownBody: selection.previewBody)
        } else {
            ContentUnavailableView {
                Label("Select a version", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        Button {
            select(commit)
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
            .background(selection?.sha == commit.sha ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func loadHistory() {
        let path = historyPath
        commits = git.log(forPath: path, at: workingDir, limit: 50)
        guard let first = commits.first else { return }
        select(first)
    }

    private func select(_ commit: GitCommit) {
        selection = git.show(sha: commit.sha, path: historyPath, at: workingDir).map {
            SkillHistorySelection(sha: commit.sha, document: $0)
        }
        if selection == nil {
            errorMessage = "Couldn't load that version."
        } else {
            errorMessage = nil
        }
    }

    private func restoreSelectedVersion() {
        guard let library else { restore(); return }
        library.confirmLeaving(skill) { proceed in if proceed { restore() } }
    }

    private func restore() {
        guard let selection else { return }
        do {
            try restoreSkillHistoryVersion(
                skill: skill,
                body: selection.document,
                store: store,
                library: library,
                notifier: notifier
            )
            onDismiss()
        } catch {
            errorMessage = "Couldn't restore that version."
        }
    }

    private var historyPath: String {
        "skills/\(skill.directoryName)/SKILL.md"
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
    try store.writeBody(directoryName: skill.directoryName, body: body)
    // A draft for this skill is stale once the version is written back — and only then: a refused write keeps it
    // (the sheet was answered at the button, 33.2; batch Layer-2).
    library?.discardDraft(skill)
    if let library {
        library.noteAppAuthoredBody(skill, body: SkillParser.stripFrontmatter(body))
        library.notifySyncedStateMutation()
    } else {
        notifier()
    }
}
