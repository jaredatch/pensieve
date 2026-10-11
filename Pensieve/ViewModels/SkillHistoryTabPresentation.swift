import Foundation
import Observation
import SwiftData

/// Owns authored History's requests for both the tab and conflict sheet. Only path and commit values
/// enter native jobs; selection, lifetime and Restore validation remain on the main actor.
@MainActor
@Observable
final class SkillHistoryTabPresentation {
    static let unreadableRestoreMessage = "Nothing was restored. Pensieve couldn't read this skill."
    static let changedRestoreMessage =
        "Nothing was restored. The skill changed while Pensieve was reading that version."
    static let interruptedRestoreMessage =
        "Nothing was restored. Another History read started before Restore finished."
    static let closedRestoreMessage = "Nothing was restored. History was closed before Restore finished."
    static let selectedSkillRestoreMessage = "Nothing was restored. You selected another skill before Restore finished."

    private final class RestoreAttempt {
        var retirementMessage: String?
        weak var library: SkillLibraryViewModel?

        init(library: SkillLibraryViewModel?) { self.library = library }
    }

    struct Diff: Identifiable {
        let version: SkillHistoryVersion
        let body: String
        var id: String { version.sha }
    }

    var snapshot = SkillHistorySnapshot()
    var showAll = false
    var diff: Diff?
    var restoring: SkillHistoryVersion?
    var selection: SkillHistorySelection?
    var errorMessage: String?
    private(set) var isLoading = true
    private(set) var readingVersion: String?
    private(set) var restoringVersion: String?
    private var skillID: UUID?
    private var loadGeneration = 0
    private var actionGeneration = 0
    @ObservationIgnored private var latestRestore: RestoreAttempt?

    func reset() {
        retireRestore(Self.selectedSkillRestoreMessage, leavingHistory: true)
        close()
        snapshot = SkillHistorySnapshot()
        showAll = false
        errorMessage = latestRestore?.retirementMessage
    }

    func close() {
        retireRestore(Self.closedRestoreMessage, leavingHistory: true)
        loadGeneration &+= 1
        actionGeneration &+= 1
        skillID = nil
        diff = nil
        selection = nil
        restoring = nil
        readingVersion = nil
        restoringVersion = nil
    }

    func load(skill: Skill, git: GitServiceProtocol, workingDir: String, selectFirst: Bool = false) async {
        if skillID != skill.id { reset() }
        skillID = skill.id
        loadGeneration &+= 1
        let generation = loadGeneration, id = skill.id
        let path = SkillHistorySnapshot.path(for: skill)
        isLoading = true
        let loaded = await BlockingWork.run {
            SkillHistorySnapshot.load(path: path, git: git, workingDir: workingDir)
        }
        guard !Task.isCancelled, skillID == id, loadGeneration == generation else { return }
        snapshot = loaded
        isLoading = false
        if selectFirst, let first = loaded.versions.first {
            await read(first, skill: skill, git: git, workingDir: workingDir, asDiff: false)
        }
    }

    func read(_ version: SkillHistoryVersion, skill: Skill, git: GitServiceProtocol,
              workingDir: String, asDiff: Bool) async {
        guard skillID == skill.id else { return }
        actionGeneration &+= 1
        let generation = actionGeneration
        let path = SkillHistorySnapshot.path(for: skill)
        retireRestore(Self.interruptedRestoreMessage)
        errorMessage = latestRestore?.retirementMessage
        readingVersion = version.sha
        selection = nil
        let document = await BlockingWork.run { git.show(sha: version.sha, path: path, at: workingDir) }
        guard !Task.isCancelled, skillID == skill.id, actionGeneration == generation else { return }
        readingVersion = nil
        guard let document else {
            errorMessage = (errorMessage.map { $0 + " " } ?? "") + "Couldn't load that version."
            return
        }
        if asDiff {
            diff = Diff(version: version, body: SkillHistoryPresentation.previewBody(from: document))
        } else {
            selection = SkillHistorySelection(sha: version.sha, document: document)
        }
    }

    private func retireRestore(_ message: String, leavingHistory: Bool = false) {
        guard restoringVersion != nil, let attempt = latestRestore, attempt.retirementMessage == nil else { return }
        attempt.retirementMessage = message
        errorMessage = message
        if leavingHistory { attempt.library?.error = message }
        restoringVersion = nil
    }

    func restore(_ version: SkillHistoryVersion, skill: Skill, git: GitServiceProtocol,
                 workingDir: String, store: SkillStoreProtocol, library: SkillLibraryViewModel?,
                 notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) -> Task<Bool, Never> {
        guard restoringVersion == nil, skillID == skill.id else { return Task { false } }
        if let message = library?.error,
           [Self.closedRestoreMessage, Self.selectedSkillRestoreMessage].contains(message) { library?.error = nil }
        errorMessage = nil
        latestRestore = nil
        guard let context = skill.modelContext, !skill.isDeleted,
              let rawDocument = try? store.readData(directoryName: skill.directoryName) else {
            errorMessage = Self.unreadableRestoreMessage
            return Task { false }
        }
        actionGeneration &+= 1
        let generation = actionGeneration
        let path = SkillHistorySnapshot.path(for: skill), slug = skill.directoryName
        let draft = library?.drafts[slug]?.body
        let editRevision = library?.textEditRevisions[slug]
        let folderRevision = library?.folderChangeRevisions[slug]
        readingVersion = nil
        restoringVersion = version.sha
        let attempt = RestoreAttempt(library: library)
        latestRestore = attempt
        return Task {
            let document = await BlockingWork.run { git.show(sha: version.sha, path: path, at: workingDir) }
            guard !Task.isCancelled, skillID == skill.id, actionGeneration == generation else {
                if latestRestore === attempt, attempt.retirementMessage == nil {
                    retireRestore("Nothing was restored. Restore was cancelled before it finished.")
                }
                return false
            }
            restoringVersion = nil
            let id = skill.id
            let descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })
            guard !skill.isDeleted, skill.modelContext === context,
                  (try? context.fetchCount(descriptor)) == 1,
                  library?.textEditRevisions[slug] == editRevision, library?.drafts[slug]?.body == draft,
                  library?.folderChangeRevisions[slug] == folderRevision,
                  (try? store.readData(directoryName: slug)) == rawDocument else {
                errorMessage = Self.changedRestoreMessage
                return false
            }
            guard let document else { errorMessage = "Couldn't load that version."; return false }
            do {
                try restoreSkillHistoryVersion(skill: skill, body: document, store: store, library: library, notifier: notifier)
                errorMessage = nil
                return true
            } catch {
                errorMessage = "Couldn't restore that version."
                return false
            }
        }
    }
}
