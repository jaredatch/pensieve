import Foundation
import SwiftData

struct SkillProjectDeployEvidence {
    var paths: Set<String>
    var historyFailure: Error?
}

extension PlatformViewModel {
    /// Local evidence selects deferred pairs. Shared category
    /// membership and another machine's intent alone cannot authorize cleanup on this Mac.
    func localSkillProjectDeployEvidence(
        skill: Skill, projects: [Project], context: ModelContext
    ) throws -> SkillProjectDeployEvidence {
        var paths: Set<String> = []
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func admit(_ projectID: UUID?, _ platform: PlatformTarget?) {
            guard let projectID, let project = byID[projectID], let platform, platform.usesSymlinks,
                  platform.supportsProjectScope else { return }
            paths.insert(artifactPath(skill: skill, platform: platform, target: .project(project)))
        }
        for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>()) where row.skillID == skill.id {
            admit(row.projectID, row.platform)
        }
        for row in try context.fetch(FetchDescriptor<IntentAssignment>()) where row.skillID == skill.id {
            admit(row.projectID, PlatformTarget(rawValue: row.platformRaw))
        }
        let intents = try context.fetch(FetchDescriptor<MachineDeployIntent>()).filter {
            $0.skillSlug == skill.directoryName && $0.projectKey != nil
        }
        if !intents.isEmpty {
            let machineID = try MachineIdentity(fileService: deployStateStore.fileService,
                appSupportDir: deployStateStore.appSupportDir).identifier()
            for intent in intents where intent.machineID == machineID {
                for project in projects where project.identityKey == intent.projectKey {
                    admit(project.id, PlatformTarget(rawValue: intent.platformRaw))
                }
            }
        }
        do {
            paths.formUnion(try localSkillCursorHistory(skill: skill, projects: projects, context: context))
            return SkillProjectDeployEvidence(paths: paths)
        } catch {
            // Incomplete history needs a broader folder fence. The cleanup coordinator keeps
            // this history error for the notice, even when a folder is also unavailable.
            return SkillProjectDeployEvidence(paths: paths, historyFailure: error)
        }
    }

    private func localSkillCursorHistory(skill: Skill, projects: [Project], context: ModelContext) throws -> Set<String> {
        guard deployablePlatforms(forProject: true).contains(.cursor) else { return [] }
        let allowed = Set(projects.map { artifactPath(skill: skill, platform: .cursor, target: .project($0)) })
        let skillID = skill.id
        return Set(try context.fetch(FetchDescriptor(predicate: #Predicate<DeployRecord> { $0.skillID == skillID }))
            .filter { $0.platform == .cursor && $0.projectID != nil && allowed.contains($0.targetPath) }.map(\.targetPath))
    }

    func finishWaitingSkillCleanup(_ cleanup: SkillCleanupResult) -> String? {
        guard !cleanup.deferredRemovals.isEmpty else { return nil }
        let result = removalService.remove(cleanup.deferredRemovals)
        if result.didChangeRecords { noteDeployStateChanged() }
        return result.stateWriteFailure?.localizedDescription
    }

    func abandonWaitingSkillCleanup(_ cleanup: SkillCleanupResult) throws {
        // Prepared UUIDs absent because creation deduplicated with an older source/path are harmless.
        try waitingRemovalStore.retire(ids: cleanup.waitingRemovalIDs)
    }
}
