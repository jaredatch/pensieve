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

    /// Execute the owned pairs admitted by `removeOwnedBatch`, retaining per-pair failures.
    private func removeBatch(pairs: [DeployRemovalPair], target: DeployTarget) -> BatchResult {
        var result = BatchResult()
        for pair in pairs {
            let skill = pair.skill, platform = pair.platform
            do {
                let path = artifactPath(skill: skill, platform: platform, target: target)
                try removeArtifact(skill: skill, platform: platform, target: target)
                retireDeployState(artifactPath: path)
                result.outcomes.append(BatchPairOutcome(
                    skillID: skill.id, skillName: skill.name, platform: platform,
                    target: BatchPairTarget(target), error: nil
                ))
            } catch {
                result.outcomes.append(BatchPairOutcome(
                    skillID: skill.id, skillName: skill.name, platform: platform,
                    target: BatchPairTarget(target), error: BatchPairOutcome.failureMessage(error, target: target),
                    projectFolderError: error as? ProjectFolderError
                ))
            }
        }
        noteDeployStateChanged()
        return result
    }

    /// Remove owned deploys using one state snapshot and history only for unrecorded project rules.
    /// An unreadable snapshot fences owned artifacts; absent and foreign occupants remain no-ops.
    func removeAllDeploys(
        skill: Skill, projects: [Project], localDeployHistory: (Set<String>) throws -> Set<String>
    ) -> SkillCleanupResult {
        var result = SkillCleanupResult()
        do {
            try LinkService.validatePathComponent(skill.directoryName)
        } catch {
            result.batch.recordReadFailure("deploys for “\(skill.name)”", error: error)
            return result
        }
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
        var stateChanged = false
        for candidate in candidates {
            let pair = removeAllDeployPair(skill: skill, candidate: candidate)
            result.batch.outcomes.append(pair.outcome)
            result.didChangeDeploys = pair.didChangeDeploys || result.didChangeDeploys
            stateChanged = pair.didChangeRecords || stateChanged
        }
        if result.didChangeDeploys || stateChanged { noteDeployStateChanged() }
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
    ) -> SkillCleanupPairResult {
        let location = candidate.location
        let problem: String?
        var didChangeDeploys = false
        var didChangeRecords = false
        do {
            if candidate.isOwned {
                didChangeDeploys = try removeArtifact(skill: skill, platform: location.platform, target: location.target)
            }
            didChangeRecords = try deployStateStore.remove(artifactPath: location.path)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        return SkillCleanupPairResult(outcome: BatchPairOutcome(
            skillID: skill.id, skillName: skill.name, platform: location.platform,
            target: BatchPairTarget(location.target), error: problem),
            didChangeDeploys: didChangeDeploys, didChangeRecords: didChangeRecords)
    }

    private struct SkillCleanupPairResult {
        let outcome: BatchPairOutcome
        let didChangeDeploys: Bool
        let didChangeRecords: Bool
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
    }
}
