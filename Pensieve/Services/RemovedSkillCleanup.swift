import Foundation
import SwiftData

@MainActor
protocol RemovedSkillCleaning {
    func reconcile(context: ModelContext) -> BatchResult
}

/// Uses this Mac's historical paths once, after the rebuild has removed a skill's UUID.
/// An unavailable project retains its history as the durable retry marker, separate from Delete's
/// waiting removals, whose ownership policy also admits links pointing at live skills.
@MainActor
struct RemovedSkillCleanup: RemovedSkillCleaning {
    let fileService: FileServiceProtocol
    let paths: DeployPaths
    let stateStore: DeployStateStore

    func reconcile(context: ModelContext) -> BatchResult {
        var result = BatchResult()
        do {
            let skills = try context.fetch(FetchDescriptor<Skill>())
            let liveIDs = Set(skills.map(\.id)), liveSlugs = Set(skills.map(\.directoryName))
            let projects = try context.fetch(FetchDescriptor<Project>())
            let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let history = try context.fetch(FetchDescriptor<DeployRecord>()).filter { !liveIDs.contains($0.skillID) }
            let folders = ProjectFolderProbe(fileService: fileService)
            var settled: [DeployRecord] = []
            var pending: [(DeployRecord, DeployRemovalCandidate)] = []
            for row in history {
                do {
                    let project = row.projectID.flatMap { byID[$0] }
                    guard row.projectID == nil || project != nil,
                          project.map({ ProjectDirectory.canAccess($0.path) }) ?? true,
                          let slug = paths.slug(artifactPath: row.targetPath, platform: row.platform,
                                                projectPath: project?.path) else {
                        // A removed registration or a path outside the recorded layout authorizes no disk access.
                        settled.append(row)
                        continue
                    }
                    guard (try? LinkService.validatePathComponent(slug)) != nil else {
                        settled.append(row)
                        continue
                    }
                    // Reusing a name hands its artifacts to the ordinary reconcilers. Do not retire
                    // the new skill's deploy-state record at the same path along with the old UUID.
                    if try liveSlugs.contains(slug)
                        || fileService.directoryExistsFollowingLinks(at: paths.skillsDirectory + "/" + slug) {
                        settled.append(row)
                        continue
                    }
                    if let project { try folders.require(project.path) }
                    pending.append((row, candidate(row: row, slug: slug, projectPath: project?.path)))
                } catch ProjectFolderError.missing {
                    // The persisted history row, rather than a waiting removal, keeps this work alive.
                    continue
                } catch {
                    result.recordReadFailure(row.targetPath, error: error)
                }
            }
            settle(pending, settled: &settled, result: &result)
            for row in settled { context.delete(row) }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            result.recordReadFailure("removed skill deployment history", error: error)
        }
        return result
    }

    private func settle(_ pending: [(DeployRecord, DeployRemovalCandidate)],
                        settled: inout [DeployRecord], result: inout BatchResult) {
        guard !pending.isEmpty else { return }
        let removal = DeployRemovalService(stateStore: stateStore).remove(pending.map { $0.1 })
        result.didRemoveArtifacts = removal.didRemoveArtifacts
        if let error = removal.stateWriteFailure { result.recordReadFailure("removed skill deploy state", error: error) }
        for ((row, _), outcome) in zip(pending, removal.outcomes) {
            if let error = outcome.failure { result.recordReadFailure(row.targetPath, error: error) }
            // A failed derived-state write keeps the original evidence for a later pass, even if
            // unlinking already succeeded. An absent or foreign occupant otherwise settles it once.
            if outcome.completed && removal.stateWriteFailure == nil { settled.append(row) }
        }
    }

    private func candidate(row: DeployRecord, slug: String, projectPath: String?) -> DeployRemovalCandidate {
        let path = row.targetPath, platform = row.platform
        let ownership = DeployArtifactOwnership(fileService: fileService)
        let operation = DeployRemovalOperation(fileService: fileService, path: path) {
            if let projectPath { _ = try fileService.requireProjectDirectory(at: projectPath) }
            if platform == .cursor {
                // Without the source, only the mark proves ownership. History never proves file ownership.
                return try ownership.cursor(at: path, legacyContent: nil)
            }
            let occupant = try ownership.link(at: path, skillsDirectory: paths.skillsDirectory,
                                             linksFile: platform == .codex && projectPath != nil)
            guard occupant.isOwned else { return occupant }
            do {
                _ = try fileService.resolveRealPath(at: path)
                return .foreignLink
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR)) {
                return .owned
            }
        }
        return DeployRemovalCandidate(key: DeployRemovalKey(slug: slug, platform: platform,
            projectPath: projectPath, artifactPath: path), evidence: [.localHistory, .danglingLink], operation: operation)
    }
}
