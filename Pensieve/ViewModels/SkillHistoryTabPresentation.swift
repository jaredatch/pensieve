import Foundation
import Observation
import SwiftData

/// Owns authored History's requests for both the tab and conflict sheet. Only path and commit values
/// enter native jobs; selection, lifetime and Restore validation remain on the main actor.
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
    var selection: SkillHistorySelection?
    var errorMessage: String?
    private(set) var isLoading = true
    private(set) var readingVersion: String?
    private(set) var restoringVersion: String?
    private var skillID: UUID?
    private var loadGeneration = 0
    private var actionGeneration = 0

    func reset() {
        close()
        snapshot = SkillHistorySnapshot()
        showAll = false
        errorMessage = nil
    }

    func close() {
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
        restoringVersion = nil
        readingVersion = version.sha
        selection = nil
        let document = await BlockingWork.run { git.show(sha: version.sha, path: path, at: workingDir) }
        guard !Task.isCancelled, skillID == skill.id, actionGeneration == generation else { return }
        readingVersion = nil
        guard let document else { errorMessage = "Couldn't load that version."; return }
        errorMessage = nil
        if asDiff {
            diff = Diff(version: version, body: SkillHistoryPresentation.previewBody(from: document))
        } else {
            selection = SkillHistorySelection(sha: version.sha, document: document)
        }
    }

    func restore(_ version: SkillHistoryVersion, skill: Skill, git: GitServiceProtocol,
                 workingDir: String, store: SkillStoreProtocol, library: SkillLibraryViewModel?,
                 notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) -> Task<Bool, Never> {
        guard restoringVersion == nil, skillID == skill.id, let context = skill.modelContext, !skill.isDeleted,
              let body = try? store.readBody(directoryName: skill.directoryName) else { return Task { false } }
        actionGeneration &+= 1
        let generation = actionGeneration
        let path = SkillHistorySnapshot.path(for: skill), slug = skill.directoryName
        let draft = library?.drafts[slug]?.body
        let editRevision = library?.textEditRevisions[slug]
        let folderRevision = library?.folderChangeRevisions[slug]
        let rawDocument = library.flatMap { try? $0.fileService.readData(at: store.baseDir + "/" + slug + "/SKILL.md") }
        readingVersion = nil
        restoringVersion = version.sha
        return Task {
            let document = await BlockingWork.run { git.show(sha: version.sha, path: path, at: workingDir) }
            guard !Task.isCancelled, skillID == skill.id, actionGeneration == generation else { return false }
            restoringVersion = nil
            guard !skill.isDeleted, skill.modelContext === context,
                  (try? context.fetch(FetchDescriptor<Skill>()))?.contains(where: { $0.id == skill.id }) == true,
                  library?.textEditRevisions[slug] == editRevision, library?.drafts[slug]?.body == draft,
                  library?.folderChangeRevisions[slug] == folderRevision,
                  library.flatMap({ try? $0.fileService.readData(at: store.baseDir + "/" + slug + "/SKILL.md") }) == rawDocument,
                  (try? store.readBody(directoryName: slug)) == body else { return false }
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
