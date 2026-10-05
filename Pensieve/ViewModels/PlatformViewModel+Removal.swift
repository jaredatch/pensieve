import Foundation

extension PlatformViewModel {
    /// Only owned artifacts are removal actions. Foreign and absent pairs retire silently.
    func removeOwnedBatch(pairs: [DeployRemovalPair], target: DeployTarget) -> BatchResult {
        var result = BatchResult()
        var owned: [DeployRemovalPair] = []
        var stateChanged = false
        for pair in pairs {
            let skill = pair.skill, platform = pair.platform
            do {
                if try artifactIsOwned(skill: skill, platform: platform, target: target) {
                    owned.append(pair)
                } else {
                    let changed = retireDeployState(artifactPath: artifactPath(skill: skill, platform: platform, target: target))
                    stateChanged = changed || stateChanged
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
        if !owned.isEmpty {
            result.append(removeBatch(pairs: owned, target: target))
        } else if stateChanged {
            noteDeployStateChanged()
        }
        return result
    }

    /// Remove owned deploys using one state snapshot and history only for unrecorded project rules.
    /// An unreadable snapshot fences owned artifacts; absent and foreign occupants remain no-ops.
    func removeAllDeploys(
        skill: Skill, projects: [Project], localDeployHistory: (Set<String>) throws -> Set<String>
    ) -> BatchResult {
        var result = BatchResult()
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
        var candidates: [SkillCleanupCandidate] = []
        for target in [DeployTarget.userWide] + projects.map({ .project($0) }) {
            for platform in deployablePlatforms(forProject: target.project != nil) {
                if let candidate = skillCleanupCandidate(skill: skill, platform: platform, target: target,
                    recorded: recorded, stateProblem: stateProblem, result: &result) {
                    candidates.append(candidate)
                }
            }
        }
        // A project rule's mark can arrive through git from another Mac.
        let historyPaths = Set(candidates.filter {
            $0.platform == .cursor && $0.target.project != nil && recorded?.contains($0.path) == false
        }.map(\.path))
        let locallyDeployed: Set<String>
        do {
            locallyDeployed = historyPaths.isEmpty ? [] : try localDeployHistory(historyPaths)
        } catch {
            result.recordReadFailure("local deploy history for “\(skill.name)”", error: error)
            return result
        }
        for candidate in candidates where !historyPaths.contains(candidate.path) || locallyDeployed.contains(candidate.path) {
            result.outcomes.append(removeAllDeployPair(skill: skill, candidate: candidate))
        }
        if !result.outcomes.isEmpty { noteDeployStateChanged() }
        return result
    }

    private func skillCleanupCandidate(
        skill: Skill, platform: PlatformTarget, target: DeployTarget,
        recorded: Set<String>?, stateProblem: String, result: inout BatchResult
    ) -> SkillCleanupCandidate? {
        let path = artifactPath(skill: skill, platform: platform, target: target)
        do {
            let ours = try artifactIsOwned(skill: skill, platform: platform, target: target)
            guard let recorded else {
                guard ours else { return nil }
                result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                    target: BatchPairTarget(target), error: "\(stateProblem); nothing removed at \(path)"))
                return nil
            }
            guard ours || recorded.contains(path) else { return nil }
            return SkillCleanupCandidate(platform: platform, target: target, path: path, isOwned: ours)
        } catch {
            result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                target: BatchPairTarget(target), error: error.localizedDescription))
            return nil
        }
    }

    private func removeAllDeployPair(skill: Skill, candidate: SkillCleanupCandidate) -> BatchPairOutcome {
        let problem: String?
        do {
            if candidate.isOwned { try removeArtifact(skill: skill, platform: candidate.platform, target: candidate.target) }
            try deployStateStore.remove(artifactPath: candidate.path)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        return BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: candidate.platform,
                                target: BatchPairTarget(candidate.target), error: problem)
    }

    private struct SkillCleanupCandidate {
        let platform: PlatformTarget
        let target: DeployTarget
        let path: String
        let isOwned: Bool
    }
}
