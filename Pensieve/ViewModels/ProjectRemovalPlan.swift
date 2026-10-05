import Foundation
import SwiftData

struct ProjectRemovalPreview {
    let projectName: String
    let artifactCount: Int
    let folderIsMissing: Bool

    var title: String { "Remove “\(projectName)”?" }
    var message: String {
        if folderIsMissing {
            return "Pensieve can't reach this folder, so the links and rules it added there stay. Your files stay."
        }
        if artifactCount == 0 { return "No skill links or rules will be removed. Your files stay." }
        let artifacts = artifactCount == 1 ? "skill link or rule" : "skill links and rules"
        return "Removes \(artifactCount) \(artifacts) Pensieve added to this project. Your files stay."
    }
}

/// Candidates come from this Mac's records, never a directory scan. The same preparation feeds
/// confirmation and execution; execution prepares again and the leaf removal rechecks ownership.
@MainActor
struct ProjectRemovalPlan {
    let preview: ProjectRemovalPreview
    let pairs: [DeployRemovalPair]

    static func prepare(project: Project, platformVM: PlatformViewModel, context: ModelContext,
                        stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher()) throws -> ProjectRemovalPlan {
        do {
            try platformVM.projectReconcilePolicy.requireDirectory(project)
        } catch ProjectFolderError.missing {
            return ProjectRemovalPlan(preview: ProjectRemovalPreview(
                projectName: project.name, artifactCount: 0, folderIsMissing: true), pairs: [])
        }
        let skills = try stateFetcher.skills(context: context)
        let byID = Dictionary(skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bySlug = Dictionary(skills.map { ($0.directoryName, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [String: DeployRemovalPair] = [:]
        for row in try stateFetcher.categoryAssignments(context: context) where row.projectID == project.id {
            if let skill = byID[row.skillID] {
                try admit(skill: skill, platform: row.platform, project: project, platformVM: platformVM, into: &candidates)
            }
        }
        for row in try stateFetcher.intentAssignments(context: context) where row.projectID == project.id {
            if let skill = byID[row.skillID], let platform = PlatformTarget(rawValue: row.platformRaw) {
                try admit(skill: skill, platform: platform, project: project, platformVM: platformVM, into: &candidates)
            }
        }
        let state = try platformVM.deployStateStore.read()
        for row in state.records where row.scope == "project" && row.artifactPath.hasPrefix(project.path + "/") {
            guard let platform = PlatformTarget(rawValue: row.platform) else { continue }
            let skill = bySlug[row.slug] ?? Skill(name: row.slug, directoryName: row.slug)
            try admit(skill: skill, platform: platform, project: project, platformVM: platformVM,
                      recordedPath: row.artifactPath, into: &candidates)
        }
        let projectID = project.id
        let history = try context.fetch(FetchDescriptor<DeployRecord>(predicate: #Predicate { $0.projectID == projectID }))
        for row in history where row.targetPath.hasPrefix(project.path + "/") {
            let skill = byID[row.skillID] ?? historicalSkill(path: row.targetPath, platform: row.platform)
            try admit(skill: skill, platform: row.platform, project: project, platformVM: platformVM,
                      recordedPath: row.targetPath, into: &candidates)
        }
        let pairs = candidates.keys.sorted().compactMap { candidates[$0] }
        var count = 0
        for pair in pairs where try platformVM.artifactIsOwned(
            skill: pair.skill, platform: pair.platform, target: .project(project)) { count += 1 }
        return ProjectRemovalPlan(preview: ProjectRemovalPreview(
            projectName: project.name, artifactCount: count, folderIsMissing: false), pairs: pairs)
    }

    func removeArtifacts(project: Project, platformVM: PlatformViewModel) -> BatchResult {
        var result = BatchResult()
        var changed = false
        for pair in pairs {
            let target = DeployTarget.project(project)
            let path = platformVM.artifactPath(skill: pair.skill, platform: pair.platform, target: target)
            do {
                let owned = try platformVM.artifactIsOwned(skill: pair.skill, platform: pair.platform, target: target)
                let deleted = owned
                    ? try platformVM.removeArtifact(skill: pair.skill, platform: pair.platform, target: target) : false
                changed = deleted || changed
                let retired = try platformVM.deployStateStore.remove(artifactPath: path)
                changed = retired || changed
                if deleted {
                    result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                        platform: pair.platform, target: .project(project.id), error: nil))
                } else {
                    result.retiredPairs.insert(BatchPairKey(skillID: pair.skill.id,
                        platform: pair.platform, target: .project(project.id)))
                }
            } catch {
                result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                    platform: pair.platform, target: .project(project.id),
                    error: "\(pair.skill.name) (\(pair.platform.displayName)) at \(path): \(error.localizedDescription)"))
            }
        }
        if changed { platformVM.noteDeployStateChanged() }
        return result
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
