import Foundation
import SwiftData

extension UpdateCheckService {
    func evaluateSkills(_ trees: [(Snapshot, Result<String, Error>)], head: String, commitDate: Date,
                        checkedAt: Date, context: ModelContext) throws {
        for (snapshot, tree) in trees {
            try evaluateSkill(snapshot, tree: tree, head: head, commitDate: commitDate,
                              checkedAt: checkedAt, context: context)
        }
    }

    func evaluateSkill(_ snapshot: Snapshot, tree: Result<String, Error>, head: String, commitDate: Date,
                       checkedAt: Date,
                       context: ModelContext) throws {
        do {
            let tree = try tree.get()
            try updateCurrentSkill(snapshot: snapshot, sourceContext: context) { skill in
                let available = tree != snapshot.origin.installedTree
                skill.updateAvailable = available
                skill.lastCheckedAt = checkedAt
                skill.lastCheckedHead = head
                skill.upstreamTree = tree
                skill.upstreamCommit = available ? head : nil
                skill.upstreamCommitDate = available ? commitDate : nil
                skill.checkError = nil
            }
        } catch {
            try writeError(errorMessage(SkillInstallService.mappedRepositoryError(error)), snapshot: snapshot, context: context)
        }
    }

    func writeUnmoved(snapshot: Snapshot, checkedAt: Date,
                      context: ModelContext) throws {
        try updateCurrentSkill(snapshot: snapshot, sourceContext: context) { skill in
            skill.lastCheckedAt = checkedAt
            skill.checkError = nil
        }
    }

    func writeError(_ message: String, snapshots: [Snapshot],
                    context: ModelContext) throws {
        for snapshot in snapshots {
            try writeError(message, snapshot: snapshot, context: context)
        }
    }

    func writeError(_ message: String, snapshot: Snapshot,
                    context: ModelContext) throws {
        try updateCurrentSkill(snapshot: snapshot, sourceContext: context) { skill in
            skill.lastCheckedAt = now()
            skill.checkError = DisplayTextSanitizer.singleLine(message)
        }
    }

    func updateCurrentSkill(snapshot: Snapshot, sourceContext: ModelContext,
                            mutation: (Skill) -> Void) throws {
        // A long-lived ModelContext returns its registered object even after a sibling context saves.
        // Re-read in a fresh context so the compare-and-set sees sync/adopt/update changes that landed
        // while the network work was in flight.
        let writeContext = ModelContext(sourceContext.container)
        guard let skill = try writeContext.fetch(FetchDescriptor<Skill>()).first(where: {
            $0.id == snapshot.id
                && $0.directoryName == snapshot.directoryName
                && $0.installedOrigin == snapshot.origin
        }) else { return }
        mutation(skill)
        try writeContext.save()
    }

    func updateCursor(key: BatchKey, head: String, checkedAt: Date,
                      context: ModelContext) throws {
        let writeContext = ModelContext(context.container)
        let cursors = try writeContext.fetch(FetchDescriptor<RepoUpdateCursor>())
        if let cursor = cursors.first(where: { $0.repo == key.repo && $0.ref == key.ref }) {
            cursor.lastSeenHead = head
            cursor.lastCheckedAt = checkedAt
        } else {
            writeContext.insert(RepoUpdateCursor(
                repo: key.repo,
                ref: key.ref,
                lastSeenHead: head,
                lastCheckedAt: checkedAt
            ))
        }
        try writeContext.save()
    }

    func prepareScratchRoot() throws {
        if fileService.isSymlink(at: scratchRoot) {
            try fileService.deleteDirectory(at: scratchRoot)
        } else if fileService.fileExists(at: scratchRoot) {
            try fileService.deleteFile(at: scratchRoot)
        }
        if !fileService.directoryExists(at: scratchRoot) {
            try fileService.createDirectory(at: scratchRoot)
        }
    }

    func makeSnapshot(skill: Skill, origin: InstalledOrigin) -> Snapshot {
        Snapshot(
            id: skill.id,
            directoryName: skill.directoryName,
            origin: origin,
            lastCheckedHead: skill.lastCheckedHead
        )
    }

    func errorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    func batchOrder(_ lhs: BatchKey, _ rhs: BatchKey) -> Bool {
        lhs.repo == rhs.repo ? lhs.ref < rhs.ref : lhs.repo < rhs.repo
    }
}
