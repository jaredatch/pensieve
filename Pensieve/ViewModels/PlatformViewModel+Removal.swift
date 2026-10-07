import Foundation

struct SkillCleanupResult {
    var batch = BatchResult()
    var didChangeDeploys = false
    var waitingProjects: [String] = []
    var waitingRemovalIDs: Set<UUID> = []
    var deferredRemovals: [DeployRemovalCandidate] = []
}

extension PlatformViewModel {
    /// Only owned artifacts are removal actions. Foreign pairs and absence without an earlier removal retire silently;
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
        skill: Skill, projects: [Project], localProjectEvidence: () throws -> SkillProjectDeployEvidence
    ) -> SkillCleanupResult {
        var result = SkillCleanupResult()
        do {
            try LinkService.validatePathComponent(skill.directoryName)
        } catch {
            result.batch.recordReadFailure("deploys for “\(skill.name)”", error: error)
            return result
        }
        let (recorded, stateProblem) = skillCleanupState()
        let localEvidence: SkillProjectDeployEvidence
        do { localEvidence = try localProjectEvidence() } catch {
            if recorded == nil {
                recordSkillCleanupStateFailure(skill: skill, problem: stateProblem, batch: &result.batch)
            }
            result.batch.recordReadFailure("local deploy history and assignments for “\(skill.name)”", error: error)
            return result
        }
        let folders = skillCleanupFolderProbe()
        let localPaths = localEvidence.paths
        let incomplete = recorded == nil || localEvidence.historyFailure != nil
        let selected = skillCleanupProjects(skill: skill, projects: projects,
            paths: (recorded ?? []).union(localPaths), includeAll: incomplete)
        let unavailable = unavailableSkillCleanupProjects(selected, folders: folders)
        result.batch = skillCleanupReadFailures(skill: skill, recorded: recorded, stateProblem: stateProblem,
            localEvidence: localEvidence, projects: selected, unavailable: unavailable)
        if result.batch.hasFailures { return result }
        let evidence = skillCleanupEvidence(skill: skill, projects: projects, recorded: recorded,
            localPaths: localPaths, unavailable: unavailable, probedProjects: Set(selected.map(\.id)))
        let locallyDeployed = localEvidence.cursorHistoryPaths.intersection(evidence.historyPaths)
        let candidates = skillCleanupCandidates(skill: skill, evidence: evidence, locallyDeployed: locallyDeployed,
            recorded: recorded, stateProblem: stateProblem)
        do {
            try saveWaitingSkillCleanup(skill: skill, candidates: candidates.deferred, result: &result)
        } catch {
            result.batch.recordReadFailure("waiting removals for “\(skill.name)”", error: error)
            return result
        }
        let removal = removalService.remove(candidates.available.map(\.removal))
        applySkillCleanupReport(removal, skill: skill, candidates: candidates.available, result: &result)
        return result
    }

    private func recordSkillCleanupStateFailure(skill: Skill, problem: String, batch: inout BatchResult) {
        batch.recordReadFailure("deploys for “\(skill.name)”", error: SkillCleanupStateFailure(message: problem))
    }

    private func skillCleanupReadFailures(skill: Skill, recorded: Set<String>?, stateProblem: String,
                                          localEvidence: SkillProjectDeployEvidence, projects: [Project],
                                          unavailable: Set<UUID>) -> BatchResult {
        var result = BatchResult()
        if let error = localEvidence.historyFailure,
           !unavailable.isEmpty || skillCleanupNeedsCursorHistory(skill: skill, projects: projects) {
            result.recordReadFailure("local deploy history for “\(skill.name)”", error: error)
        }
        if recorded == nil, !unavailable.isEmpty || result.hasFailures {
            recordSkillCleanupStateFailure(skill: skill, problem: stateProblem, batch: &result)
        }
        return result
    }

    private func skillCleanupProjects(skill: Skill, projects: [Project], paths: Set<String>, includeAll: Bool) -> [Project] {
        guard !includeAll else { return projects }
        return projects.filter { project in
            deployablePlatforms(forProject: true).contains {
                paths.contains(artifactPath(skill: skill, platform: $0, target: .project(project)))
            }
        }
    }

    private func unavailableSkillCleanupProjects(_ projects: [Project], folders: ProjectFolderProbe) -> Set<UUID> {
        return Set(projects.filter { project in
            guard ProjectDirectory.canAccess(project.path) else { return false }
            return !folders.isAvailable(project.path)
        }.map(\.id))
    }

    private func skillCleanupNeedsCursorHistory(skill: Skill, projects: [Project]) -> Bool {
        for project in projects where ProjectDirectory.canAccess(project.path) {
            do { if try projectCursorRuleMayExist(skill: skill, project: project) { return true } } catch { return true }
        }
        return false
    }

    private func applySkillCleanupReport(
        _ removal: DeployRemovalResult, skill: Skill,
        candidates: [SkillCleanupCandidate], result: inout SkillCleanupResult) {
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
    }

    private func skillCleanupState() -> (paths: Set<String>?, problem: String) {
        do { return (try deployStateStore.recordedArtifactPaths(), "") } catch DeployStateError.unsupportedSchema(let version) {
            return (nil, "deploy state uses a newer schema (\(version)); update Pensieve")
        } catch { return (nil, "deploy state unreadable") }
    }

    private func saveWaitingSkillCleanup(
        skill: Skill, candidates: [SkillCleanupCandidate], result: inout SkillCleanupResult
    ) throws {
        let waiting = candidates.compactMap { item -> WaitingRemoval? in
            guard let project = item.location.target.project else { return nil }
            return waitingRemoval(skill: skill, platform: item.location.platform, project: project, source: "skill:\(skill.id)")
        }
        try waitingRemovalStore.add(waiting)
        result.waitingProjects = Array(Set(waiting.map { "\($0.projectName) (\($0.projectPath))" })).sorted()
        result.waitingRemovalIDs = Set(waiting.map(\.id))
        result.deferredRemovals = candidates.map(\.removal)
    }

    private func skillCleanupCandidates(
        skill: Skill, evidence: SkillCleanupEvidence, locallyDeployed: Set<String>,
        recorded: Set<String>?, stateProblem: String
    ) -> (available: [SkillCleanupCandidate], deferred: [SkillCleanupCandidate]) {
        var available: [SkillCleanupCandidate] = []
        var deferred: [SkillCleanupCandidate] = []
        for location in evidence.locations
            where !evidence.historyPaths.contains(location.path) || locallyDeployed.contains(location.path) {
            var sources: Set<DeployRemovalEvidence> = [.enumeratedSkillPath]
            if recorded?.contains(location.path) == true { sources.insert(.deployState) }
            if locallyDeployed.contains(location.path) { sources.insert(.localHistory) }
            let pair = DeployRemovalPair(skill: skill, platform: location.platform)
            var candidate: DeployRemovalCandidate
            if location.isDeferred {
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
            if location.isDeferred { deferred.append((location, candidate)) } else { available.append((location, candidate)) }
        }
        return (available, deferred)
    }

    private func skillCleanupEvidence(
        skill: Skill, projects: [Project], recorded: Set<String>?, localPaths: Set<String>,
        unavailable: Set<UUID>, probedProjects: Set<UUID>
    ) -> SkillCleanupEvidence {
        var evidence = SkillCleanupEvidence()
        for target in [DeployTarget.userWide] + projects.map({ .project($0) }) {
            let isDeferred = target.project.map { unavailable.contains($0.id) } ?? false
            for platform in deployablePlatforms(forProject: target.project != nil) {
                let path = artifactPath(skill: skill, platform: platform, target: target)
                if isDeferred, recorded?.contains(path) != true, !localPaths.contains(path) { continue }
                if let project = target.project, ProjectDirectory.canAccess(project.path), !probedProjects.contains(project.id) {
                    // Preserve cleanup of available unrecorded links. An unadmitted path with no
                    // readable leaf supplies no candidate or deferred evidence; do not inspect it.
                    guard unrecordedArtifactMayExist(at: path, platform: platform) else { continue }
                }
                // A rule's mark can arrive through git from another Mac. Check this Mac's evidence
                // before opening it. Metadata avoids a history fetch for known absent/foreign shapes.
                if platform == .cursor, let project = target.project, let recorded, !recorded.contains(path) {
                    do {
                        if !isDeferred {
                            guard try projectCursorRuleMayExist(skill: skill, project: project) else { continue }
                        }
                    } catch {
                        // A failed metadata probe matters only if local history admits this path.
                        evidence.probeFailures[path] = error
                    }
                    if !isDeferred { evidence.historyPaths.insert(path) }
                }
                evidence.locations.append(SkillCleanupLocation(platform: platform, target: target,
                    path: path, isDeferred: isDeferred))
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
        let isDeferred: Bool
    }

    private typealias SkillCleanupCandidate = (location: SkillCleanupLocation, removal: DeployRemovalCandidate)

    private struct SkillCleanupEvidence {
        var locations: [SkillCleanupLocation] = []
        var historyPaths: Set<String> = []
        var probeFailures: [String: Error] = [:]
    }
}
