import SwiftData

struct DeployMutationPair {
    let skill: Skill
    let platform: PlatformTarget
    let machineID: String
    let target: DeployTarget
    let isLocal: Bool

    var hasIntent: Bool {
        target.project.map { $0.identityKey.map(ManifestService.isAdmittedProjectKey) == true } ?? true
    }
}

struct DeployMutationChange {
    let pair: DeployMutationPair
    let intentChanges: Bool
    let artifactChanges: Bool
    var warning: String?
}

struct DeployMutationReport {
    let changes: [DeployMutationChange]
    var results = BatchResult()
    var intentSaved = false
    var applied = false
}

extension DeployMutationService {
    /// The same read-only plan gates both previews and application. The selection lock covers
    /// planning through persistence; keyless projects retain the window's direct local path.
    func change(_ selected: Bool, pairs: [DeployMutationPair], dryRun: Bool,
                context: ModelContext) throws -> DeployMutationReport {
        let operation = {
            let expanded = try self.expandProjects(pairs, context: context)
            let changes = try self.plan(selected, pairs: expanded, context: context)
            var report = DeployMutationReport(changes: changes)
            guard !dryRun, !changes.isEmpty else { return report }
            report = try self.applyChanges(selected, changes: changes, context: context)
            return report
        }
        if pairs.contains(where: \.hasIntent) {
            // Dry runs do not ingest into SwiftData. They refuse stale state rather than mutate it.
            if dryRun {
                guard let lock = dependencies.lockProvider(dependencies.lockPath) else {
                    throw DeployIntentModelError.syncInProgress
                }
                defer { lock.release() }
                guard !StoreIngestState.shared(for: context.container).needsRebuild else {
                    throw DeployIntentModelError.ingestPending
                }
                return try operation()
            }
            return try withSelectionLock(skills: pairs.map(\.skill), context: context, operation)
        }
        return try operation()
    }

    private func applyChanges(_ selected: Bool, changes: [DeployMutationChange],
                              context: ModelContext) throws -> DeployMutationReport {
        var report = DeployMutationReport(changes: changes)
        let intended = changes.filter { $0.pair.hasIntent }
        var reconciliation = BatchResult()
        if !intended.isEmpty {
            let localID = try dependencies.identity.identifier()
            let reconcile: (ModelContext) -> BatchResult = { [self] context in
                dependencies.reconcileSelection?(intended.map(\.pair), context)
                    ?? dependencies.reconcile(context)
            }
            let persistence = try persistAndReconcile(localMachineID: localID, context: context,
                reconcile: reconcile) {
                var mutated = false
                for change in intended {
                    let pair = change.pair
                    let changed = try mutateOne(selected, machineID: pair.machineID, skill: pair.skill,
                        platform: pair.platform, projectKey: pair.target.project?.identityKey, context: context)
                    mutated = mutated || changed
                }
                return mutated
            }
            report.intentSaved = persistence.mutated
            report.applied = persistence.mutated
            reconciliation = persistence.reconciliation
            if !persistence.mutated { reconciliation.append(reconcile(context)) }
        }
        for change in changes where change.pair.isLocal {
            let pair = change.pair
            let result = pair.hasIntent ? realizeSelection(selected, skills: [pair.skill],
                platforms: [pair.platform], target: pair.target,
                reconciliation: reconciliation, context: context)
                : directSet(selected, skills: [pair.skill], platforms: [pair.platform],
                                 target: pair.target, context: context)
            report.results.append(result)
            report.applied = report.applied || !result.successes.isEmpty || result.didRemoveArtifacts
                || result.outcomes.contains(where: \.artifactApplied)
        }
        presentFailures(report.results)
        return report
    }

    private func expandProjects(_ pairs: [DeployMutationPair], context: ModelContext) throws -> [DeployMutationPair] {
        let projects = try context.fetch(FetchDescriptor<Project>())
        return pairs.flatMap { pair in
            guard pair.isLocal, pair.hasIntent, let key = pair.target.project?.identityKey else { return [pair] }
            return projects.filter { $0.identityKey == key }.map { project in
                DeployMutationPair(skill: pair.skill, platform: pair.platform, machineID: pair.machineID,
                    target: .project(project), isLocal: true)
            }
        }
    }

    func plan(_ selected: Bool, pairs: [DeployMutationPair], context: ModelContext) throws -> [DeployMutationChange] {
        let rows = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        let keys = Set(rows.map(\.key))
        var changes: [DeployMutationChange] = []
        for pair in pairs {
            if pair.hasIntent {
                try Self.validate(machineID: pair.machineID, slug: pair.skill.directoryName, platformRaw: pair.platform.rawValue)
            } else { try LinkService.validatePathComponent(pair.skill.directoryName) }
            let key = MachineDeployIntent.makeKey(machineID: pair.machineID, skillSlug: pair.skill.directoryName,
                platformRaw: pair.platform.rawValue, projectKey: pair.target.project?.identityKey)
            let intentChanges = pair.hasIntent && keys.contains(key) != selected
            var artifactChanges = false
            var warning: String?
            if pair.isLocal {
                if selected {
                    artifactChanges = !platformVM.isDeployed(skill: pair.skill, platform: pair.platform, target: pair.target)
                } else {
                    do {
                        artifactChanges = try platformVM.removalOperation(skill: pair.skill, platform: pair.platform,
                            target: pair.target).classify().isOwned
                    } catch {
                        // A failed preview probe cannot suppress the window's intent withdrawal.
                        artifactChanges = true
                        warning = error.localizedDescription
                    }
                }
            }
            if intentChanges || artifactChanges {
                changes.append(DeployMutationChange(pair: pair, intentChanges: intentChanges,
                    artifactChanges: artifactChanges, warning: warning))
            }
        }
        return changes
    }
}
