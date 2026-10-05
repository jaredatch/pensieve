import Foundation

struct SkillCleanupResult {
    var batch = BatchResult()
    var didChangeDeploys = false
}

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
    ) -> SkillCleanupResult {
        var result = SkillCleanupResult()
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
        let evidence = skillCleanupEvidence(skill: skill, projects: projects, recorded: recorded)
        result.batch.outcomes.append(contentsOf: evidence.validationFailures)
        let locallyDeployed: Set<String>
        do {
            locallyDeployed = evidence.historyPaths.isEmpty ? [] : try localDeployHistory(evidence.historyPaths)
        } catch {
            result.batch.recordReadFailure("local deploy history for “\(skill.name)”", error: error)
            return result
        }
        var candidates: [SkillCleanupCandidate] = []
        for location in evidence.locations
            where !evidence.historyPaths.contains(location.path) || locallyDeployed.contains(location.path) {
            if let error = evidence.probeFailures[location.path] {
                result.batch.outcomes.append(BatchPairOutcome(
                    skillID: skill.id, skillName: skill.name, platform: location.platform,
                    target: BatchPairTarget(location.target), error: error.localizedDescription))
            } else if let candidate = skillCleanupCandidate(skill: skill, location: location,
                recorded: recorded, stateProblem: stateProblem, result: &result.batch) {
                candidates.append(candidate)
            }
        }
        for candidate in candidates {
            let pair = removeAllDeployPair(skill: skill, candidate: candidate)
            result.batch.outcomes.append(pair.outcome)
            result.didChangeDeploys = pair.didChangeDeploys || result.didChangeDeploys
        }
        if !result.batch.outcomes.isEmpty { noteDeployStateChanged() }
        return result
    }

    private func skillCleanupEvidence(
        skill: Skill, projects: [Project], recorded: Set<String>?
    ) -> SkillCleanupEvidence {
        var evidence = SkillCleanupEvidence()
        for target in [DeployTarget.userWide] + projects.map({ .project($0) }) {
            for platform in deployablePlatforms(forProject: target.project != nil) {
                let path = artifactPath(skill: skill, platform: platform, target: target)
                // A rule's mark can arrive through git from another Mac. Check this Mac's evidence
                // before opening it. Metadata avoids a history fetch for known absent/foreign shapes.
                if platform == .cursor, let project = target.project, let recorded, !recorded.contains(path) {
                    do {
                        guard try projectCursorRuleMayExist(skill: skill, project: project) else { continue }
                    } catch LinkError.invalidPathComponent(let component) {
                        evidence.validationFailures.append(BatchPairOutcome(
                            skillID: skill.id, skillName: skill.name, platform: platform, target: BatchPairTarget(target),
                            error: LinkError.invalidPathComponent(component).localizedDescription))
                        continue
                    } catch {
                        // A failed metadata probe matters only if local history admits this path.
                        evidence.probeFailures[path] = error
                    }
                    evidence.historyPaths.insert(path)
                }
                evidence.locations.append(SkillCleanupLocation(platform: platform, target: target, path: path))
            }
        }
        return evidence
    }

    private func skillCleanupCandidate(
        skill: Skill, location: SkillCleanupLocation,
        recorded: Set<String>?, stateProblem: String, result: inout BatchResult
    ) -> SkillCleanupCandidate? {
        let platform = location.platform, target = location.target, path = location.path
        do {
            let ours = try artifactIsOwned(skill: skill, platform: platform, target: target)
            guard let recorded else {
                guard ours else { return nil }
                result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                    target: BatchPairTarget(target), error: "\(stateProblem); nothing removed at \(path)"))
                return nil
            }
            guard ours || recorded.contains(path) else { return nil }
            return SkillCleanupCandidate(location: location, isOwned: ours)
        } catch {
            result.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: platform,
                target: BatchPairTarget(target), error: error.localizedDescription))
            return nil
        }
    }

    private func removeAllDeployPair(
        skill: Skill, candidate: SkillCleanupCandidate
    ) -> (outcome: BatchPairOutcome, didChangeDeploys: Bool) {
        let location = candidate.location
        let problem: String?
        var didChangeDeploys = false
        do {
            if candidate.isOwned {
                try removeArtifact(skill: skill, platform: location.platform, target: location.target)
                didChangeDeploys = true
            }
            let retired = try deployStateStore.remove(artifactPath: location.path)
            didChangeDeploys = retired || didChangeDeploys
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        return (BatchPairOutcome(skillID: skill.id, skillName: skill.name, platform: location.platform,
                                 target: BatchPairTarget(location.target), error: problem), didChangeDeploys)
    }

    private struct SkillCleanupCandidate {
        let location: SkillCleanupLocation
        let isOwned: Bool
    }

    private struct SkillCleanupLocation {
        let platform: PlatformTarget
        let target: DeployTarget
        let path: String
    }

    private struct SkillCleanupEvidence {
        var locations: [SkillCleanupLocation] = []
        var historyPaths: Set<String> = []
        var probeFailures: [String: Error] = [:]
        var validationFailures: [BatchPairOutcome] = []
    }
}
