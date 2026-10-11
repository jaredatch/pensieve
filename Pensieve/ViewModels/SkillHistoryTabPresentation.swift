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

    @Observable
    fileprivate final class RestoreAttempt {
        let skillID: UUID
        var retirementMessage: String?
        @ObservationIgnored weak var library: SkillLibraryViewModel?

        init(skillID: UUID, library: SkillLibraryViewModel?) {
            self.skillID = skillID
            self.library = library
        }
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
    private var actionError: String?
    var errorMessage: String? {
        let retirement = latestRestore.flatMap { $0.skillID == skillID ? $0.retirementMessage : nil }
        let messages = [retirement, actionError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
    private(set) var isLoading = true
    private(set) var readingVersion: String?
    private(set) var restoringVersion: String?
    private var skillID: UUID?
    private var loadGeneration = 0
    private var actionGeneration = 0
    private var latestRestore: RestoreAttempt?

    func reset() {
        retireRestore(Self.selectedSkillRestoreMessage, leavingHistory: true)
        clearPresentation()
        snapshot = SkillHistorySnapshot()
        showAll = false
        actionError = nil
    }

    func close() {
        retireRestore(Self.closedRestoreMessage, leavingHistory: true)
        clearPresentation()
    }

    private func clearPresentation() {
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
        retireRestore(Self.interruptedRestoreMessage)
        actionGeneration &+= 1
        let generation = actionGeneration
        let path = SkillHistorySnapshot.path(for: skill)
        actionError = nil
        readingVersion = version.sha
        selection = nil
        let document = await BlockingWork.run { git.show(sha: version.sha, path: path, at: workingDir) }
        guard !Task.isCancelled, skillID == skill.id, actionGeneration == generation else { return }
        readingVersion = nil
        guard let document else {
            actionError = "Couldn't load that version."
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
        if leavingHistory { attempt.library?.error = message }
        restoringVersion = nil
    }

    func restore(_ version: SkillHistoryVersion, skill: Skill, git: GitServiceProtocol,
                 workingDir: String, store: SkillStoreProtocol, library: SkillLibraryViewModel?,
                 notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) -> Task<Bool, Never> {
        guard restoringVersion == nil, skillID == skill.id else { return Task { false } }
        if let message = library?.error,
           [Self.closedRestoreMessage, Self.selectedSkillRestoreMessage].contains(message) { library?.error = nil }
        actionError = nil
        latestRestore = nil
        guard let context = skill.modelContext, !skill.isDeleted,
              let rawDocument = try? store.readData(directoryName: skill.directoryName) else {
            actionError = Self.unreadableRestoreMessage
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
        latestRestore = RestoreAttempt(skillID: skill.id, library: library)
        return Task {
            let document = await BlockingWork.run { git.show(sha: version.sha, path: path, at: workingDir) }
            guard !Task.isCancelled, skillID == skill.id, actionGeneration == generation else {
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
                actionError = Self.changedRestoreMessage
                return false
            }
            guard let document else { actionError = "Couldn't load that version."; return false }
            do {
                try restoreSkillHistoryVersion(skill: skill, body: document, store: store, library: library, notifier: notifier)
                actionError = nil
                return true
            } catch {
                actionError = "Couldn't restore that version."
                return false
            }
        }
    }
}
