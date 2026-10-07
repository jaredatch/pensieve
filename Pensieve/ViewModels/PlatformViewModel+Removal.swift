import Foundation

struct SkillCleanupResult {
    var batch = BatchResult()
    var didChangeDeploys = false
}

extension PlatformViewModel {
    /// Only owned artifacts are removal actions. Foreign and absent pairs retire silently.
    func removeOwnedBatch(pairs: [DeployRemovalPair], target: DeployTarget) -> BatchResult {
        let candidates = pairs.map { removalCandidate(pair: $0, target: target, evidence: [.selection]) }
        let removal = removalService.remove(candidates, inspection: .beforeBatch)
        logRemovalStateFailure(removal)
        var result = BatchResult()
        for (pair, outcome) in removal.orderedOutcomes(for: pairs) {
            let key = BatchPairKey(skillID: pair.skill.id, platform: pair.platform, target: BatchPairTarget(target))
            if let error = outcome.failure {
                result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                    platform: pair.platform, target: key.target, error: BatchPairOutcome.failureMessage(error, target: target),
                    projectFolderError: error as? ProjectFolderError))
            } else if outcome.completed, outcome.attemptedDeletion {
                result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                    platform: pair.platform, target: key.target, error: nil))
            } else if outcome.retired {
                result.retiredPairs.insert(key)
            }
        }
        // A checked owned removal refreshes even when its delete failed, as the old batch did.
        if removal.didAttemptDeletion || removal.didChangeRecords { noteDeployStateChanged() }
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
        let candidates = skillCleanupCandidates(skill: skill, evidence: evidence, locallyDeployed: locallyDeployed,
            recorded: recorded, stateProblem: stateProblem)
        let removal = removalService.remove(candidates.map(\.removal), inspection: .beforeBatch)
        for (location, outcome) in removal.orderedOutcomes(for: candidates.map(\.location)) {
            let problem = outcome.failure ?? (outcome.completed ? removal.stateWriteFailure : nil)
            guard problem != nil || outcome.completed else { continue }
            result.batch.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name,
                platform: location.platform, target: BatchPairTarget(location.target), error: problem?.localizedDescription))
        }
        result.didChangeDeploys = !removal.removed.isEmpty
        if result.didChangeDeploys || removal.didChangeRecords { noteDeployStateChanged() }
        return result
    }

    private func skillCleanupCandidates(
        skill: Skill, evidence: SkillCleanupEvidence, locallyDeployed: Set<String>,
        recorded: Set<String>?, stateProblem: String
    ) -> [(location: SkillCleanupLocation, removal: DeployRemovalCandidate)] {
        var candidates: [(location: SkillCleanupLocation, removal: DeployRemovalCandidate)] = []
        for location in evidence.locations
            where !evidence.historyPaths.contains(location.path) || locallyDeployed.contains(location.path) {
            var sources: Set<DeployRemovalEvidence> = [.enumeratedSkillPath]
            if recorded?.contains(location.path) == true { sources.insert(.deployState) }
            if locallyDeployed.contains(location.path) { sources.insert(.localHistory) }
            let pair = DeployRemovalPair(skill: skill, platform: location.platform)
            var candidate: DeployRemovalCandidate
            if let error = evidence.probeFailures[location.path] {
                candidate = DeployRemovalCandidate(key: removalKey(pair: pair, target: location.target),
                    evidence: sources, action: .fail(error))
            } else {
                candidate = removalCandidate(pair: pair, target: location.target, evidence: sources)
            }
            candidate.retireIfUnowned = recorded?.contains(location.path) == true
            if recorded == nil {
                candidate.removalBlocker = SkillCleanupStateFailure(
                    message: "\(stateProblem); nothing removed at \(location.path)")
            }
            candidates.append((location, candidate))
        }
        return candidates
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

    private struct SkillCleanupStateFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
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
