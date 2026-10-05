import Foundation

extension PlatformViewModel {
    /// A foreign or absent occupant retires only our record; it is not a removal action.
    func prepareArtifactRemoval(skill: Skill, platform: PlatformTarget, target: DeployTarget = .userWide) throws -> Bool {
        if try artifactIsOwned(skill: skill, platform: platform, target: target) { return true }
        if retireDeployState(artifactPath: artifactPath(skill: skill, platform: platform, target: target)) {
            noteDeployStateChanged()
        }
        return false
    }

    /// Only owned artifacts are removal actions. Foreign and absent pairs retire silently.
    func removeOwnedBatch(skills: [Skill], platforms: [PlatformTarget], target: DeployTarget) -> BatchResult {
        var result = BatchResult()
        for skill in skills {
            for platform in platforms {
                do {
                    if try prepareArtifactRemoval(skill: skill, platform: platform, target: target) {
                        result.append(removeBatch(skills: [skill], platforms: [platform], target: target))
                    } else {
                        result.retiredPairs.insert(BatchPairKey(
                            skillID: skill.id, platform: platform, target: BatchPairTarget(target)))
                    }
                } catch {
                    result.outcomes.append(BatchPairOutcome(
                        skillID: skill.id, skillName: skill.name, platform: platform, target: BatchPairTarget(target),
                        error: BatchPairOutcome.failureMessage(error, target: target)
                    ))
                }
            }
        }
        return result
    }

    /// Remove owned deploys user-wide and in registered projects; stale records are dropped
    /// without removing foreign occupants. An unreadable state file fences existing owned artifacts.
    func removeAllDeploys(skill: Skill, projects: [Project], locallyDeployedPaths: Set<String> = []) -> BatchResult {
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
                    recorded: recorded, locallyDeployedPaths: locallyDeployedPaths, stateProblem: stateProblem) {
                    result.outcomes.append(outcome)
                }
            }
        }
        if !result.outcomes.isEmpty { noteDeployStateChanged() }
        return result
    }

    private func removeAllDeployPair(
        skill: Skill, platform: PlatformTarget, target: DeployTarget,
        recorded: Set<String>?, locallyDeployedPaths: Set<String>, stateProblem: String
    ) -> BatchPairOutcome? {
        let path = artifactPath(skill: skill, platform: platform, target: target)
        // A project rule's mark can arrive through git from another Mac.
        if platform == .cursor, target.project != nil, let recorded,
           !recorded.contains(path), !locallyDeployedPaths.contains(path) { return nil }
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
