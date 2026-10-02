import Observation
import SwiftUI

enum SkillHistorySyncSignal: Hashable {
    case idle
    case syncing
    case synced(Date)
    case conflicted([String])
    case error(String)
    case unconfigured

    init(_ state: SyncModel.SyncState) {
        switch state {
        case .idle: self = .idle
        case .syncing: self = .syncing
        case let .synced(at): self = .synced(at)
        case let .conflicted(paths): self = .conflicted(paths)
        case let .error(message): self = .error(message)
        case .unconfigured: self = .unconfigured
        }
    }
}

private struct SkillHistorySyncSignalKey: EnvironmentKey {
    static let defaultValue = SkillHistorySyncSignal.idle
}

extension EnvironmentValues {
    var skillHistorySyncSignal: SkillHistorySyncSignal {
        get { self[SkillHistorySyncSignalKey.self] }
        set { self[SkillHistorySyncSignalKey.self] = newValue }
    }
}

@MainActor
@Observable
final class SkillHistoryTabPresentation {
    struct Diff: Identifiable {
        let version: SkillHistoryVersion
        let body: String
        var id: String { version.sha }
    }

    var snapshot = SkillHistorySnapshot()
    var showAll = false
    var diff: Diff?
    var restoring: SkillHistoryVersion?
    var errorMessage: String?

    func reset() {
        snapshot = SkillHistorySnapshot()
        showAll = false
        diff = nil
        restoring = nil
        errorMessage = nil
    }
}

/// The sync repo's versions of SKILL.md as a timeline (the master `Commit row`): a 12 pt dot column with
/// a 10 pt dot and the 1 pt connector, the body at 28 on 6 pt gaps, 24 pt between rows. View Diff opens
/// PLAN-09's line diff against the current file; Restore This Version… confirms, then writes the version
/// back through the existing boundary, which drops any draft only after the write.
struct SkillHistoryTab: View {
    let skill: Skill
    let currentBody: String
    @Bindable var library: SkillLibraryViewModel
    @Bindable var upstreamHistory: UpstreamHistoryViewModel
    let localRevision: UpstreamHistoryLocalRevision
    let onOpenUpdates: () -> Void
    let onUpdateCheck: UpstreamHistoryViewModel.UpdateCheckRequest
    private let hostedPresentation: SkillHistoryTabPresentation?
    private let git: GitServiceProtocol
    private let store: SkillStoreProtocol
    private let workingDir: String

    @Environment(\.skillHistorySyncSignal) private var syncSignal
    @State private var ownedPresentation = SkillHistoryTabPresentation()

    private var presentation: SkillHistoryTabPresentation { hostedPresentation ?? ownedPresentation }

    init(skill: Skill, currentBody: String, library: SkillLibraryViewModel,
         upstreamHistory: UpstreamHistoryViewModel,
         localRevision: UpstreamHistoryLocalRevision,
         onOpenUpdates: @escaping () -> Void,
         onUpdateCheck: @escaping UpstreamHistoryViewModel.UpdateCheckRequest,
         git: GitServiceProtocol = GitService(),
         store: SkillStoreProtocol = SkillStore(fileService: FileService()),
         workingDir: String = Constants.pensieveBaseDir,
         hostedPresentation: SkillHistoryTabPresentation? = nil) {
        self.skill = skill
        self.currentBody = currentBody
        self.library = library
        self.upstreamHistory = upstreamHistory
        self.localRevision = localRevision
        self.onOpenUpdates = onOpenUpdates
        self.onUpdateCheck = onUpdateCheck
        self.git = git
        self.store = store
        self.workingDir = workingDir
        self.hostedPresentation = hostedPresentation
    }

    var body: some View {
        Group {
            if skill.hasLinkedOrigin, let origin = skill.installedOrigin {
                InstalledSkillHistoryView(
                    skill: skill,
                    currentBody: currentBody,
                    origin: origin,
                    updateAvailable: skill.updateAvailable,
                    localRevision: localRevision,
                    onOpenUpdates: onOpenUpdates,
                    onUpdateCheck: onUpdateCheck,
                    history: upstreamHistory
                )
            } else {
                authoredHistory
            }
        }
        .onChange(of: skill.id) { _, _ in presentation.reset() }
    }

    private var authoredHistory: some View {
        @Bindable var presentation = presentation
        let rows = SkillHistoryTimeline.rows(presentation.snapshot.versions, showAll: presentation.showAll)
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No versions saved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                SkillHistoryRowView(row: row, onViewDiff: { presentDiff(row.version) },
                                    onRestore: { presentation.restoring = row.version })
            }
            if let older = SkillHistoryTimeline.olderLabel(
                total: presentation.snapshot.versions.count,
                shown: rows.count
            ) {
                Button(older) { presentation.showAll = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if let errorMessage = presentation.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, DesignTokens.historyContentTop)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: SkillHistorySnapshot.ReloadKey(
            skillID: skill.id, reloadToken: library.reloadToken,
            appWriteRevision: library.appWriteRevision, syncSignal: syncSignal
        )) {
            presentation.snapshot = SkillHistorySnapshot.load(skill: skill, git: git, workingDir: workingDir)
        }
        .sheet(item: $presentation.diff) { diff in
            SkillHistoryDiffSheet(version: diff.version, versionBody: diff.body,
                                  currentBody: currentBody, onClose: { presentation.diff = nil })
        }
        .confirmationDialog("Restore this version?", isPresented: Binding(
            get: { presentation.restoring != nil }, set: { if !$0 { presentation.restoring = nil } }
        ), titleVisibility: .visible, presenting: presentation.restoring) { version in
            Button("Restore", role: .destructive) { restore(version) }
        } message: { version in
            Text(Self.restoreMessage(version: version, unsaved: library.hasUnsavedChanges(for: skill)))
        }
    }

    /// The unsaved arm is reachable: a draft the file caught up with reads clean (dirty is measured — PLAN-33)
    /// and lets every gate through, and a later external change makes it dirty again while History shows
    /// (the external-change sheet's Cancel keeps it), so the message says what Restore drops.
    static func restoreMessage(version: SkillHistoryVersion, unsaved: Bool, locale: Locale = .current) -> String {
        let base = "SKILL.md will be replaced with the version from "
            + version.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)) + "."
        return unsaved ? base + " Your unsaved changes will be lost." : base
    }

    private func presentDiff(_ version: SkillHistoryVersion) {
        guard let document = git.show(sha: version.sha, path: SkillHistorySnapshot.path(for: skill), at: workingDir) else {
            presentation.errorMessage = "Couldn't load that version."
            return
        }
        presentation.errorMessage = nil
        presentation.diff = SkillHistoryTabPresentation.Diff(
            version: version,
            body: SkillHistoryPresentation.previewBody(from: document)
        )
    }

    private func restore(_ version: SkillHistoryVersion) {
        guard let document = git.show(sha: version.sha, path: SkillHistorySnapshot.path(for: skill), at: workingDir) else {
            presentation.errorMessage = "Couldn't load that version."
            return
        }
        do {
            try restoreSkillHistoryVersion(skill: skill, body: document, store: store, library: library,
                                           notifier: SyncStateNotifier.suppressed)
            presentation.errorMessage = nil
        } catch {
            presentation.errorMessage = "Couldn't restore that version."
        }
    }
}

private struct SkillHistoryRowView: View {
    let row: SkillHistoryTimeline.Row
    let onViewDiff: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            VStack(spacing: 0) {
                Rectangle().fill(DesignTokens.timelineRule).frame(width: 1, height: 4)
                    .opacity(row.connectsUp ? 1 : 0)
                Circle().fill(row.isCurrent ? Color.green : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 10, height: 10)
                Rectangle().fill(DesignTokens.timelineRule).frame(width: 1).frame(maxHeight: .infinity)
                    .opacity(row.connectsDown ? 1 : 0)
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Spacing.sm) {
                    Text(SkillHistoryTimeline.meta(for: row.version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.isCurrent {
                        Text("Current")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1), in: Capsule())
                    }
                }
                Text(row.version.subject)
                    .font(.body)
                if !row.isCurrent {
                    HStack(spacing: Spacing.sm) {
                        Button("View Diff", action: onViewDiff)
                            .controlSize(.large)
                        Button("Restore This Version…", action: onRestore)
                            .controlSize(.large)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.bottom, Spacing.xxl)
        }
        .accessibilityElement(children: .contain)
    }
}

/// PLAN-09's line diff in a sheet: the version on the left, the current file on the right.
private struct SkillHistoryDiffSheet: View {
    let version: SkillHistoryVersion
    let versionBody: String
    let currentBody: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Changes since " + SkillHistoryTimeline.meta(for: version))
                .font(.headline)
            ScrollView {
                LineDiffView(this: versionBody, other: currentBody,
                             thisLabel: "That version", otherLabel: "Current")
            }
            .frame(minHeight: 420)
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760)
    }
}
