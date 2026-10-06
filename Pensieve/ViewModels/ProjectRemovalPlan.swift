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
        if let failure = folderFailure(project: project, platformVM: platformVM) {
            result.operationFailures.append(failure)
            return result
        }
        if preview.folderIsMissing || preview.folderIsShared { return result }
        var changed = false
        var completed: [(candidate: Candidate, deleted: Bool)] = []
        for candidate in candidates {
            let pair = candidate.pair
            do {
                let deleted = candidate.isOwned ? try platformVM.removeArtifact(
                    skill: pair.skill, platform: pair.platform, target: .project(project)) : false
                result.didRemoveArtifacts = deleted || result.didRemoveArtifacts
                changed = deleted || changed
                completed.append((candidate, deleted))
            } catch {
                result.outcomes.append(failure(candidate, project: project, error: error))
            }
        }
        do {
            let retired = try platformVM.deployStateStore.remove(artifactPaths: Set(completed.map { $0.candidate.path }))
            changed = retired || changed
            for item in completed {
                let pair = item.candidate.pair
                if item.deleted {
                    result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                        platform: pair.platform, target: .project(project.id), error: nil))
                } else {
                    result.retiredPairs.insert(BatchPairKey(skillID: pair.skill.id,
                        platform: pair.platform, target: .project(project.id)))
                }
            }
        } catch {
            for item in completed { result.outcomes.append(failure(item.candidate, project: project, error: error)) }
        }
        if changed { platformVM.noteDeployStateChanged() }
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
            let skill = evidence.byID[row.skillID] ?? historicalSkill(path: row.targetPath, platform: row.platform)
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
        candidates[path] = DeployRemovalPair(skill: skill, platform: platform)
    }

    private static func historicalSkill(path: String, platform: PlatformTarget) -> Skill {
        let file = path as NSString
        let slug: String
        if platform == .cursor {
            slug = file.deletingPathExtension.components(separatedBy: "/").last ?? ""
        } else if platform == .codex {
            slug = (file.deletingLastPathComponent as NSString).lastPathComponent
        } else {
            slug = file.lastPathComponent
        }
        return Skill(name: slug, directoryName: slug)
    }
}
