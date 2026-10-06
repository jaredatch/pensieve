import SwiftData

extension DeployIntentModel {
    func setRemote(
        _ selected: Bool,
        machineID: String,
        projectKey: String?,
        skill: Skill,
        platform: PlatformTarget,
        context: ModelContext
    ) throws {
        try reportErrors {
            try Self.validate(machineID: machineID, slug: skill.directoryName, platformRaw: platform.rawValue)
            if let projectKey, !ManifestService.isAdmittedProjectKey(projectKey) {
                throw DeployIntentModelError.invalidComponent(projectKey)
            }
            try withIntentLock {
                let localID = try dependencies.identity.identifier()
                guard machineID != localID else { throw DeployIntentModelError.remoteTargetIsThisMac }
                try persistIntentOnly(localMachineID: localID, context: context) {
                    try mutateOne(
                        selected, machineID: machineID, skill: skill, platform: platform,
                        projectKey: projectKey, context: context
                    )
                }
            }
        }
    }

    func set(
        _ selected: Bool,
        skill: Skill,
        platform: PlatformTarget,
        target: DeployTarget,
        context: ModelContext
    ) throws -> BatchResult {
        let result: BatchResult = try reportErrors {
            if let project = target.project,
               project.identityKey.map(ManifestService.isAdmittedProjectKey) != true {
                return directSet(selected, skills: [skill], platforms: [platform], target: target, context: context)
            }
            return try withIntentLock {
                let machineID = try dependencies.identity.identifier()
                try Self.validate(machineID: machineID, slug: skill.directoryName, platformRaw: platform.rawValue)
                let projectKey = target.project?.identityKey
                let persistence = try persistAndReconcile(localMachineID: machineID, context: context) {
                    try mutateOne(
                        selected, machineID: machineID, skill: skill, platform: platform,
                        projectKey: projectKey, context: context
                    )
                }
                var reconciliation = persistence.reconciliation
                if !persistence.mutated {
                    reconciliation.append(dependencies.reconcile(context))
                }
                return realizeSelection(
                    selected, skills: [skill], platforms: [platform], target: target,
                    reconciliation: reconciliation, context: context
                )
            }
        }
        presentFailures(result)
        return result
    }

    func setProjectSelection(
        _ selected: Bool,
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        project: Project,
        context: ModelContext
    ) throws -> DeployIntentApplyOutcome {
        let target = DeployTarget.project(project)
        guard let projectKey = project.identityKey,
              ManifestService.isAdmittedProjectKey(projectKey) else {
            let result = directSet(selected, skills: skills, platforms: Array(platforms),
                                   target: target, context: context)
            presentFailures(result)
            return .localDeploy(result)
        }
        let result: BatchResult = try reportErrors {
            try withIntentLock {
                let machineID = try dependencies.identity.identifier()
                try Self.validateSelection(
                    machineIDs: [machineID], slugs: Set(skills.map(\.directoryName)),
                    platformRaws: Set(platforms.map(\.rawValue))
                )
                let persistence = try persistAndReconcile(localMachineID: machineID, context: context) {
                    try reconcileProjectRows(
                        selected, machineID: machineID, projectKey: projectKey,
                        skills: skills, platforms: platforms, context: context
                    )
                }
                var reconciliation = persistence.reconciliation
                if !persistence.mutated {
                    reconciliation.append(dependencies.reconcile(context))
                }
                return realizeSelection(
                    selected, skills: skills, platforms: Array(platforms), target: target,
                    reconciliation: reconciliation, context: context
                )
            }
        }
        presentFailures(result)
        return .localDeploy(result)
    }

    @discardableResult
    func setSelected(
        _ selected: Bool,
        machineID: String,
        skill: Skill,
        platform: PlatformTarget,
        context: ModelContext
    ) throws -> BatchResult? {
        try reportErrors {
            try Self.validate(machineID: machineID, slug: skill.directoryName, platformRaw: platform.rawValue)
            return try withIntentLock {
                let localID = try dependencies.identity.identifier()
                let persistence = try persistAndReconcile(localMachineID: localID, context: context) {
                    try mutateOne(
                        selected, machineID: machineID, skill: skill, platform: platform,
                        projectKey: nil, context: context
                    )
                }
                var reconciliation = persistence.reconciliation
                guard machineID == localID else {
                    reload(context: context)
                    return nil
                }
                if !persistence.mutated { reconciliation.append(dependencies.reconcile(context)) }
                let result = realizeSelection(
                    selected, skills: [skill], platforms: [platform], target: .userWide,
                    reconciliation: reconciliation, context: context
                )
                reload(context: context)
                return result
            }
        }
    }

    func apply(
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        selectedMachineIDs: Set<String>,
        context: ModelContext
    ) throws -> DeployIntentApplyOutcome {
        try reportErrors {
            try withIntentLock {
                let localID = try dependencies.identity.identifier()
                let slugs = Set(skills.map(\.directoryName))
                let platformRaws = Set(platforms.map(\.rawValue))
                try Self.validateSelection(
                    machineIDs: selectedMachineIDs, slugs: slugs, platformRaws: platformRaws
                )
                let persistence = try persistAndReconcile(localMachineID: localID, context: context) {
                    try reconcileRows(
                        skills: skills, platforms: platforms,
                        selectedMachineIDs: selectedMachineIDs, context: context
                    )
                }
                var reconciliation = persistence.reconciliation
                guard selectedMachineIDs.contains(localID) else { return .intentOnly }
                if !persistence.mutated {
                    reconciliation.append(dependencies.reconcile(context))
                }
                let installed = Set(platformVM.installedPlatforms())
                let localPlatforms = Array(platforms.filter(installed.contains))
                return .localDeploy(realizeSelection(
                    true, skills: skills, platforms: localPlatforms, target: .userWide,
                    reconciliation: reconciliation, context: context
                ))
            }
        }
    }

    func retract(
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        machineIDs: Set<String>,
        context: ModelContext
    ) throws -> DeployIntentApplyOutcome {
        try reportErrors {
            try withIntentLock {
                let localID = try dependencies.identity.identifier()
                let slugs = Set(skills.map(\.directoryName))
                let platformRaws = Set(platforms.map(\.rawValue))
                try Self.validateSelection(machineIDs: machineIDs, slugs: slugs, platformRaws: platformRaws)
                let persistence = try persistAndReconcile(localMachineID: localID, context: context) {
                    let rows = try context.fetch(FetchDescriptor<MachineDeployIntent>())
                    var mutated = false
                    for row in rows where row.projectKey == nil && machineIDs.contains(row.machineID)
                        && slugs.contains(row.skillSlug) && platformRaws.contains(row.platformRaw) {
                        context.delete(row)
                        mutated = true
                    }
                    return mutated
                }
                var reconciliation = persistence.reconciliation
                guard machineIDs.contains(localID) else { return .intentOnly }
                if !persistence.mutated {
                    reconciliation.append(dependencies.reconcile(context))
                }
                return .localDeploy(realizeSelection(
                    false, skills: skills, platforms: Array(platforms), target: .userWide,
                    reconciliation: reconciliation, context: context
                ))
            }
        }
    }

    static func validate(machineID: String, slug: String, platformRaw: String) throws {
        guard ManifestService.isCanonicalMachineID(machineID),
              ManifestService.isAdmittedIntentComponent(slug),
              SkillStore.isPathSafeSlug(slug),
              ManifestService.isAdmittedIntentComponent(platformRaw) else {
            throw DeployIntentModelError.invalidComponent(machineID + "|" + slug + "|" + platformRaw)
        }
    }
}

private extension DeployIntentModel {
    func withIntentLock<T>(_ operation: () throws -> T) throws -> T {
        guard let lock = dependencies.lockProvider(dependencies.lockPath) else {
            throw DeployIntentModelError.syncInProgress
        }
        defer { lock.release() }
        return try operation()
    }

    func reportErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            let value = try operation()
            error = nil
            return value
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func directSet(
        _ selected: Bool,
        skills: [Skill],
        platforms: [PlatformTarget],
        target: DeployTarget,
        context: ModelContext
    ) -> BatchResult {
        if selected {
            return platformVM.deployBatch(
                skills: skills, platforms: platforms, target: target, context: context
            )
        }
        return platformVM.removeSelection(skills: skills, platforms: platforms, target: target)
    }

    func presentFailures(_ result: BatchResult) {
        let messages = result.readFailures.map(\.message) + result.failures.compactMap(\.error)
        error = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func mutateOne(
        _ selected: Bool,
        machineID: String,
        skill: Skill,
        platform: PlatformTarget,
        projectKey: String?,
        context: ModelContext
    ) throws -> Bool {
        let key = MachineDeployIntent.makeKey(
            machineID: machineID, skillSlug: skill.directoryName,
            platformRaw: platform.rawValue, projectKey: projectKey
        )
        let rows = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        let existing = rows.first { $0.key == key }
        if selected, existing == nil {
            context.insert(MachineDeployIntent(
                machineID: machineID, skillSlug: skill.directoryName,
                platformRaw: platform.rawValue, projectKey: projectKey
            ))
            return true
        }
        if !selected, let existing {
            context.delete(existing)
            return true
        }
        return false
    }

    static func validateSelection(
        machineIDs: Set<String>,
        slugs: Set<String>,
        platformRaws: Set<String>
    ) throws {
        for machineID in machineIDs {
            for slug in slugs {
                for platformRaw in platformRaws {
                    try validate(machineID: machineID, slug: slug, platformRaw: platformRaw)
                }
            }
        }
    }

    func reconcileProjectRows(
        _ selected: Bool,
        machineID: String,
        projectKey: String,
        skills: [Skill],
        platforms: Set<PlatformTarget>,
        context: ModelContext
    ) throws -> Bool {
        let slugs = Set(skills.map(\.directoryName))
        let platformRaws = Set(platforms.map(\.rawValue))
        let rows = try context.fetch(FetchDescriptor<MachineDeployIntent>())
        var existingKeys = Set(rows.map(\.key))
        var mutated = false
        for row in rows where row.machineID == machineID && row.projectKey == projectKey
            && slugs.contains(row.skillSlug) && platformRaws.contains(row.platformRaw) {
            guard !selected else { continue }
            context.delete(row)
            existingKeys.remove(row.key)
            mutated = true
        }
        guard selected else { return mutated }
        for skill in skills {
            for platform in platforms {
                let key = MachineDeployIntent.makeKey(
                    machineID: machineID, skillSlug: skill.directoryName,
                    platformRaw: platform.rawValue, projectKey: projectKey
                )
                guard existingKeys.insert(key).inserted else { continue }
                context.insert(MachineDeployIntent(
                    machineID: machineID, skillSlug: skill.directoryName,
                    platformRaw: platform.rawValue, projectKey: projectKey
                ))
                mutated = true
            }
        }
        return mutated
    }
}
