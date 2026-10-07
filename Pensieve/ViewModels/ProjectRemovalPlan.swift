import Foundation
import SwiftData

struct ProjectRemovalPreview {
    let projectName: String
    let artifactCount: Int
    let folderIsMissing: Bool
    let folderIsShared: Bool

    init(projectName: String, artifactCount: Int, folderIsMissing: Bool, folderIsShared: Bool = false) {
        self.projectName = projectName
        self.artifactCount = artifactCount
        self.folderIsMissing = folderIsMissing
        self.folderIsShared = folderIsShared
    }

    var title: String { "Remove “\(projectName)”?" }
    var message: String {
        if folderIsMissing {
            return "Pensieve can't reach this folder, so the links and rules it added there stay. Your files stay."
        }
        if folderIsShared { return "The other registration keeps the links and rules in this folder. Your files stay." }
        if artifactCount == 0 { return "No skill links or rules will be removed. Your files stay." }
        let artifacts = artifactCount == 1 ? "skill link or rule" : "skill links and rules"
        return "Removes \(artifactCount) \(artifacts) Pensieve added to this project. Your files stay."
    }
}

/// Candidates come from this Mac's records, never a directory scan. Execution prepares from
/// current state and compares its preview with confirmation before withdrawing requests.
@MainActor
struct ProjectRemovalPlan {
    let preview: ProjectRemovalPreview
    let candidates: [Candidate]
    let hasIdentitySibling: Bool
    let folderSiblingIDs: Set<UUID>

    struct Candidate {
        let pair: DeployRemovalPair
        let path: String
        let isOwned: Bool
    }

    static func prepare(project: Project, platformVM: PlatformViewModel, context: ModelContext,
                        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher()) throws -> ProjectRemovalPlan {
        let projects = try stateFetcher.projects(context: context)
        let hasSibling = projects.contains {
            $0.id != project.id && project.identityKey != nil && $0.identityKey == project.identityKey
        }
        do {
            try platformVM.projectReconcilePolicy.requireDirectory(project)
        } catch ProjectFolderError.missing {
            return ProjectRemovalPlan(preview: ProjectRemovalPreview(
                projectName: project.name, artifactCount: 0, folderIsMissing: true),
                candidates: [], hasIdentitySibling: hasSibling, folderSiblingIDs: [])
        }
        let directory = platformVM.projectReconcilePolicy.resolvedDirectory(project)
        let folderSiblingIDs = Set(projects.filter {
            $0.id != project.id && platformVM.projectReconcilePolicy.resolvedDirectory($0) == directory
        }.map(\.id))
        if !folderSiblingIDs.isEmpty {
            return ProjectRemovalPlan(preview: ProjectRemovalPreview(projectName: project.name,
                artifactCount: 0, folderIsMissing: false, folderIsShared: true),
                candidates: [], hasIdentitySibling: hasSibling, folderSiblingIDs: folderSiblingIDs)
        }
        let skills = try stateFetcher.skills(context: context)
        let evidence = Evidence(
            byID: Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            bySlug: Dictionary(skills.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first }),
            categoryRows: try stateFetcher.categoryAssignments(context: context),
            intentRows: try stateFetcher.intentAssignments(context: context))
        let candidates = try localCandidates(project: project, platformVM: platformVM, evidence: evidence, context: context)
        var prepared: [Candidate] = []
        for path in candidates.keys.sorted() {
            guard let pair = candidates[path] else { continue }
            let owned = try platformVM.artifactIsOwned(skill: pair.skill, platform: pair.platform, target: .project(project))
            prepared.append(Candidate(pair: pair, path: path, isOwned: owned))
        }
        let count = prepared.filter(\.isOwned).count
        return ProjectRemovalPlan(preview: ProjectRemovalPreview(
            projectName: project.name, artifactCount: count, folderIsMissing: false),
            candidates: prepared, hasIdentitySibling: hasSibling, folderSiblingIDs: [])
    }

    func removeArtifacts(project: Project, platformVM: PlatformViewModel) -> BatchResult {
        var result = BatchResult()
        if preview.folderIsShared { return result }
        if let failure = folderFailure(project: project, platformVM: platformVM) {
            result.operationFailures.append(failure)
            return result
        }
        if preview.folderIsMissing { return result }
        let admitted = candidates.map {
            DeployRemovalCandidate(key: platformVM.removalKey(pair: $0.pair, target: .project(project)),
                evidence: [.localProjectRecords], action: $0.isOwned
                    ? .inspect(platformVM.removalOperation(skill: $0.pair.skill, platform: $0.pair.platform,
                        target: .project(project))) : .retireWithoutInspection)
        }
        let removal = platformVM.removalService.remove(admitted)
        result.didRemoveArtifacts = !removal.removed.isEmpty
        let work = Array(zip(candidates, removal.outcomes))
        let failed = work.filter { $0.1.failure != nil }
        let completed = work.filter { $0.1.completed }
        for (candidate, outcome) in failed + completed {
            if let error = outcome.failure ?? (outcome.completed ? removal.stateWriteFailure : nil) {
                result.outcomes.append(failure(candidate, project: project, error: error))
            } else if outcome.removed {
                let pair = candidate.pair
                result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                    platform: pair.platform, target: .project(project.id), error: nil))
            } else if outcome.retired {
                result.retiredPairs.insert(BatchPairKey(skillID: candidate.pair.skill.id,
                    platform: candidate.pair.platform, target: .project(project.id)))
            }
        }
        if result.didRemoveArtifacts || removal.didChangeRecords { platformVM.noteDeployStateChanged() }
        return result
    }

    private func folderFailure(project: Project, platformVM: PlatformViewModel) -> String? {
        do {
            try platformVM.projectReconcilePolicy.requireDirectory(project)
            return nil
        } catch ProjectFolderError.missing {
            return preview.folderIsMissing ? nil : "The project folder changed. Please review removal again."
        } catch {
            return "Couldn't check the project folder at \(project.path): " + error.localizedDescription
        }
    }

    private func failure(_ candidate: Candidate, project: Project, error: Error) -> BatchPairOutcome {
        let pair = candidate.pair
        return BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
            platform: pair.platform, target: .project(project.id),
            error: "\(pair.skill.name) (\(pair.platform.displayName)) at \(candidate.path): \(error.localizedDescription)")
    }

    private struct Evidence {
        let byID: [UUID: Skill]
        let bySlug: [String: Skill]
        let categoryRows: [SkillProjectAssignment]
        let intentRows: [IntentAssignment]
    }

    private static func localCandidates(project: Project, platformVM: PlatformViewModel,
                                        evidence: Evidence, context: ModelContext) throws -> [String: DeployRemovalPair] {
        var candidates: [String: DeployRemovalPair] = [:]
        for row in evidence.categoryRows where row.projectID == project.id {
            if let skill = evidence.byID[row.skillID] {
                try admit(skill: skill, platform: row.platform, project: project, platformVM: platformVM, into: &candidates)
            }
        }
        for row in evidence.intentRows where row.projectID == project.id {
            if let skill = evidence.byID[row.skillID], let platform = PlatformTarget(rawValue: row.platformRaw) {
                try admit(skill: skill, platform: platform, project: project, platformVM: platformVM, into: &candidates)
            }
        }
        let state = try platformVM.deployStateStore.read()
        for row in state.records where row.scope == "project" && row.artifactPath.hasPrefix(project.path + "/") {
            guard let platform = PlatformTarget(rawValue: row.platform) else { continue }
            let skill = evidence.bySlug[row.slug] ?? Skill(name: row.slug, directoryName: row.slug)
            try admit(skill: skill, platform: platform, project: project, platformVM: platformVM,
                      recordedPath: row.artifactPath, into: &candidates)
        }
        let projectID = project.id
        let history = try context.fetch(FetchDescriptor<DeployRecord>(predicate: #Predicate { $0.projectID == projectID }))
        for row in history where row.targetPath.hasPrefix(project.path + "/") {
            guard let slug = DeployPaths.slug(artifactPath: row.targetPath, platform: row.platform,
                                              projectPath: project.path) else { continue }
            guard (try? LinkService.validatePathComponent(slug)) != nil else { continue }
            let matchingSkill = evidence.byID[row.skillID].flatMap { skill in
                platformVM.artifactPath(skill: skill, platform: row.platform, target: .project(project)) == row.targetPath
                    ? skill : nil
            }
            let skill = matchingSkill ?? evidence.bySlug[slug] ?? Skill(name: slug, directoryName: slug)
            try admit(skill: skill, platform: row.platform, project: project, platformVM: platformVM,
                      recordedPath: row.targetPath, into: &candidates)
        }
        return candidates
    }

    private static func admit(skill: Skill, platform: PlatformTarget, project: Project,
                              platformVM: PlatformViewModel, recordedPath: String? = nil,
                              into candidates: inout [String: DeployRemovalPair]) throws {
        guard platform.supportsProjectScope else { return }
        try LinkService.validatePathComponent(skill.directoryName)
        let path = platformVM.artifactPath(skill: skill, platform: platform, target: .project(project))
        guard recordedPath == nil || recordedPath == path else { return }
        if candidates[path] == nil { candidates[path] = DeployRemovalPair(skill: skill, platform: platform) }
    }
}
