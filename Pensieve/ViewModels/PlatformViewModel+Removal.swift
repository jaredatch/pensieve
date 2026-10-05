import Foundation

extension PlatformViewModel {
    func artifactExists(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide) -> Bool {
        (try? artifactIsOwned(skill: skill, platform: platform, target: target)) ?? false
    }

    /// Throwing ownership for consumers that retain their ledger when an occupant cannot be checked.
    func artifactIsOwned(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide) throws -> Bool {
        guard target.project == nil || platform.supportsProjectScope else { return false }
        guard ProjectDirectory.canAccess(target.project?.path) else { return false }
        if platform.usesSymlinks {
            return try linkService.ownsArtifact(skill: skill, platform: platform, projectPath: target.project?.path)
        }
        return try cursorCompiler.ownsArtifact(skill: skill, projectPath: target.project?.path)
    }

    /// Remove owned deploys user-wide and in registered projects; stale records are dropped
    /// without removing foreign occupants. An unreadable state file fences existing owned artifacts.
    func removeAllDeploys(skill: Skill, projects: [Project]) -> BatchResult {
        var result = BatchResult()
        let targets: [DeployTarget] = [.userWide] + projects.map { .project($0) }
        let recorded: Set<String>?
        let stateProblem: String
        do {
            recorded = try deployStateStore.recordedArtifactPaths()
            stateProblem = ""
        } catch DeployStateError.unsupportedSchema(let version) {
            recorded = nil
            stateProblem = "deploy state uses a newer schema (\(version)); update Pensieve"
        } catch {
            recorded = nil
            stateProblem = "deploy state unreadable"
        }
        for target in targets {
            for platform in deployablePlatforms(forProject: target.project != nil) {
                if let outcome = removeAllDeployPair(skill: skill, platform: platform, target: target,
                                                     recorded: recorded, stateProblem: stateProblem) {
                    result.outcomes.append(outcome)
                }
            }
        }
        if !result.outcomes.isEmpty { noteDeployStateChanged() }
        return result
    }

    private func removeAllDeployPair(skill: Skill, platform: PlatformTarget, target: DeployTarget,
                                     recorded: Set<String>?, stateProblem: String) -> BatchPairOutcome? {
        let path = artifactPath(skill: skill, platform: platform, target: target)
        let problem: String?
        do {
            let ours = try artifactIsOwned(skill: skill, platform: platform, target: target)
            guard let recorded else {
                guard ours else { return nil }
                return BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                                        target: BatchPairTarget(target), error: "\(stateProblem); nothing removed at \(path)")
            }
            guard ours || recorded.contains(path) else { return nil }
            if ours { try removeArtifact(skill: skill, platform: platform, target: target) }
            try deployStateStore.remove(artifactPath: path)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        return BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                                target: BatchPairTarget(target), error: problem)
    }
}
