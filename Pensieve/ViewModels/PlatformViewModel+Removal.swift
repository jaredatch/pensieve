import Foundation

struct SkillCleanupResult {
    var batch = BatchResult()
    var didChangeDeploys = false
    var waitingProjects: [String] = []
}

extension PlatformViewModel {
    /// Only owned artifacts are removal actions. Foreign and initially absent pairs retire silently;
    /// an absent duplicate after an earlier removal reports that selection's completion.
    func removeOwnedBatch(pairs: [DeployRemovalPair], target: DeployTarget) -> BatchResult {
        let candidates = pairs.map { removalCandidate(pair: $0, target: target, evidence: [.selection]) }
        let removal = removalService.remove(candidates)
        logRemovalStateFailure(removal)
        var result = BatchResult()
        for (pair, report) in removal.orderedOutcomes(for: pairs) {
            let outcome = report.outcome
            let reportsSelectionCompletion = (outcome.completed && outcome.attemptedDeletion) || report.absentAfterRemoval
            let key = BatchPairKey(skillID: pair.skill.id, platform: pair.platform, target: BatchPairTarget(target))
            if let error = outcome.failure {
                result.outcomes.append(BatchPairOutcome(skillID: pair.skill.id, skillName: pair.skill.name,
                    platform: pair.platform, target: key.target, error: BatchPairOutcome.failureMessage(error, target: target),
                    projectFolderError: error as? ProjectFolderError))
            } else if reportsSelectionCompletion {
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
        let (recorded, stateProblem) = skillCleanupState()
        let unavailable = Set(projects.filter { project in
            guard ProjectDirectory.canAccess(project.path) else { return false }
            do { try projectReconcilePolicy.requireDirectory(project); return false } catch { return true }
        }.map(\.id))
        if !unavailable.isEmpty, recorded == nil {
            result.batch.recordReadFailure("deploys for “\(skill.name)”", error: SkillCleanupStateFailure(message: stateProblem))
            return result
        }
        let evidence = skillCleanupEvidence(skill: skill, projects: projects, recorded: recorded, unavailable: unavailable)
        let locallyDeployed: Set<String>
        do {
            locallyDeployed = evidence.historyPaths.isEmpty ? [] : try localDeployHistory(evidence.historyPaths)
        } catch {
            result.batch.recordReadFailure("local deploy history for “\(skill.name)”", error: error)
            return result
        }
        let candidates = skillCleanupCandidates(skill: skill, evidence: evidence, locallyDeployed: locallyDeployed,
            recorded: recorded, stateProblem: stateProblem, unavailable: unavailable)
        do {
            result.waitingProjects = try saveWaitingSkillCleanup(skill: skill, candidates: candidates, unavailable: unavailable)
        } catch {
            result.batch.recordReadFailure("waiting removals for “\(skill.name)”", error: error)
            return result
        }
        let removal = removalService.remove(candidates.map(\.removal))
        for (location, report) in removal.orderedOutcomes(for: candidates.map(\.location)) {
            let outcome = report.outcome
            let reportsCleanupCompletion = outcome.completed || report.absentAfterRemoval
            let problem = outcome.failure ?? (reportsCleanupCompletion ? removal.stateWriteFailure : nil)
            guard problem != nil || reportsCleanupCompletion else { continue }
            result.batch.outcomes.append(BatchPairOutcome(skillID: skill.id, skillName: skill.name,
                platform: location.platform, target: BatchPairTarget(location.target), error: problem?.localizedDescription))
        }
        result.didChangeDeploys = removal.didRemoveArtifacts
        if result.didChangeDeploys || removal.didChangeRecords { noteDeployStateChanged() }
        return result
    }

    private func skillCleanupState() -> (paths: Set<String>?, problem: String) {
        do { return (try deployStateStore.recordedArtifactPaths(), "") } catch DeployStateError.unsupportedSchema(let version) {
            return (nil, "deploy state uses a newer schema (\(version)); update Pensieve")
        } catch { return (nil, "deploy state unreadable") }
    }

    private func saveWaitingSkillCleanup(
        skill: Skill, candidates: [(location: SkillCleanupLocation, removal: DeployRemovalCandidate)], unavailable: Set<UUID>
    ) throws -> [String] {
        let waiting = candidates.compactMap { item -> WaitingRemoval? in
            guard let project = item.location.target.project, unavailable.contains(project.id) else { return nil }
            return waitingRemoval(skill: skill, platform: item.location.platform, project: project, source: "skill:\(skill.id)")
        }
        try waitingRemovalStore.add(waiting)
        return Array(Set(waiting.map { "\($0.projectName) (\($0.projectPath))" })).sorted()
    }

    private func skillCleanupCandidates(
        skill: Skill, evidence: SkillCleanupEvidence, locallyDeployed: Set<String>,
        recorded: Set<String>?, stateProblem: String, unavailable: Set<UUID>
    ) -> [(location: SkillCleanupLocation, removal: DeployRemovalCandidate)] {
        var candidates: [(location: SkillCleanupLocation, removal: DeployRemovalCandidate)] = []
        for location in evidence.locations
            where !evidence.historyPaths.contains(location.path) || locallyDeployed.contains(location.path) {
            var sources: Set<DeployRemovalEvidence> = [.enumeratedSkillPath]
            if recorded?.contains(location.path) == true { sources.insert(.deployState) }
            if locallyDeployed.contains(location.path) { sources.insert(.localHistory) }
            let pair = DeployRemovalPair(skill: skill, platform: location.platform)
            var candidate: DeployRemovalCandidate
            if let project = location.target.project, unavailable.contains(project.id) {
                candidate = DeployRemovalCandidate(key: removalKey(pair: pair, target: location.target),
                    evidence: sources, action: .retireWithoutInspection)
            } else if let error = evidence.probeFailures[location.path] {
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
        skill: Skill, projects: [Project], recorded: Set<String>?, unavailable: Set<UUID>
    ) -> SkillCleanupEvidence {
        var evidence = SkillCleanupEvidence()
        for target in [DeployTarget.userWide] + projects.map({ .project($0) }) {
            for platform in deployablePlatforms(forProject: target.project != nil) {
                let path = artifactPath(skill: skill, platform: platform, target: target)
                // A rule's mark can arrive through git from another Mac. Check this Mac's evidence
                // before opening it. Metadata avoids a history fetch for known absent/foreign shapes.
                if platform == .cursor, let project = target.project, let recorded, !recorded.contains(path) {
                    do {
                        if !unavailable.contains(project.id) {
                            guard try projectCursorRuleMayExist(skill: skill, project: project) else { continue }
                        }
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
