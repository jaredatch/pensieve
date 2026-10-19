import Foundation
import SwiftData

extension CLILibraryHandler {
    func addProject(_ suppliedPath: String, options: CLILibraryOptions) async throws -> CLIReply {
        let path = try CLINameResolver.projectPath(suppliedPath, cwd: options.workingDirectory)
        try requireAddsAllowed()
        let files = files
        let snapshots = try context.fetch(FetchDescriptor<Project>()).map { (id: $0.id, path: $0.path) }
        let existingIDs = await BlockingWork.run {
            let resolved = files.realPath(at: path)
            return Set(snapshots.filter { files.realPath(at: $0.path) == resolved }.map { $0.id })
        }
        try requireAddsAllowed()
        try requireUnchangedProjects(snapshots)
        let existing = try context.fetch(FetchDescriptor<Project>()).filter { existingIDs.contains($0.id) }
        if let project = existing.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first {
            return success(projectValue(project), changed: false)
        }
        let name = (options.name ?? (path as NSString).lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CLICommandRefusal(reply: .failure("usage", "A project needs a name.", hint: "Pass --name <name>.", exit: 64))
        }
        let previewFiles = files
        let identity = ProjectIdentityService(fileService: files)
        if options.dryRun {
            let preview = try await BlockingWork.run {
                try previewFiles.requireProjectDirectory(at: path)
                return identity.peekIdentity(forProjectAt: path)
            }
            return .success(.object(["name": .string(name), "path": .string(path),
                "identity": preview.map { .string($0.key) } ?? .null,
                "createsMarker": .bool(preview == nil)]))
        }
        // The sheet uses the same registration constructor and persistence operation.
        let project = try await BlockingWork.run {
            try ProjectRegistration.makeProject(name: name, path: path, using: identity, files: files)
        }
        try requireAddsAllowed()
        try requireUnchangedProjects(snapshots)
        let container = context.container
        let saved = try await BlockingWork.run {
            let registrationContext = ModelContext(container)
            let registered = try ProjectRegistration.register(project, context: registrationContext, files: files) {
                registrationContext.insert($0)
                try registrationContext.save()
                return $0
            }
            return (registered.persistentModelID, registered.id == project.id)
        }
        guard let registered = context.model(for: saved.0) as? Project else {
            throw CocoaError(.persistentStoreOperation)
        }
        _ = runtime.reconcileIntent(context)
        runtime.syncStateNotifier()
        return success(projectValue(registered), changed: saved.1)
    }

    private func requireUnchangedProjects(_ snapshots: [(id: UUID, path: String)]) throws {
        let current = try context.fetch(FetchDescriptor<Project>())
        guard current.count == snapshots.count, current.allSatisfy({ project in
            snapshots.contains { $0.id == project.id && $0.path == project.path }
        }) else {
            throw CLICommandRefusal(reply: .failure("project_changed", "Project registrations changed during lookup.",
                hint: "Run the command again to use the current registrations.", exit: 3, retryable: true))
        }
    }

    func removeProject(_ name: String, options: CLILibraryOptions) async throws -> CLIReply {
        let project = try await resolver.project(name, cwd: options.workingDirectory)
        let plan = try ProjectRemovalPlan.prepare(project: project, platformVM: runtime.platformVM, context: context)
        let preview = plan.preview
        let data = try removalValue(project, plan: plan)
        if let reply = try previewOrConfirmation(data, options: options) { return reply }
        var changedPlanReply: CLIReply?
        let result = removeRegisteredProject(project, reconciler: CategoryReconciler(platformVM: runtime.platformVM),
            manifestService: ManifestService(fileService: files), manifestRoot: runtime.paths.storeRoot,
            platformVM: runtime.platformVM, localMachineID: try runtime.machineObservability.identity.existingIdentifier(),
            confirmedPreview: preview, context: context, notifier: runtime.syncStateNotifier, lockPath: runtime.syncLockPath,
            admitPlan: { current in
                do {
                    changedPlanReply = try previewOrConfirmation(removalValue(project, plan: current), options: options)
                    return changedPlanReply == nil
                } catch {
                    changedPlanReply = failure(error)
                    return false
                }
            })
        if let changedPlanReply { return changedPlanReply }
        guard !result.hasFailures else {
            let changed = result.didWithdrawProjectRequests || result.didRemoveArtifacts || result.didRetireProjectEvidence
            let busy = result.syncLockUnavailable && !changed
            var envelope = CLIReply.failure(changed ? "partial" : (busy ? "sync_running" : "operation_failed"),
                ProjectRemovalModel.removalFailureMessage(projectName: project.name, result: result),
                hint: "The project stays registered. Inspect its remaining deployments, then retry.",
                exit: 1, retryable: busy).envelope
            envelope.changed = changed
            envelope.data = .object(["plan": data, "remaining": projectValue(project),
                "withdrewRequests": .bool(result.didWithdrawProjectRequests),
                "removedArtifacts": .bool(result.didRemoveArtifacts)])
            return CLIReply(envelope: envelope, exitCode: 1)
        }
        return success(data, changed: true)
    }
    private func removalValue(_ project: Project, plan: ProjectRemovalPlan) throws -> CLIValue {
        let preview = plan.preview
        let intents: [String]
        if let key = project.identityKey {
            intents = try context.fetch(FetchDescriptor<MachineDeployIntent>(
                predicate: #Predicate { $0.projectKey == key })).map(\.key).sorted()
        } else { intents = [] }
        return .object(["project": projectValue(project), "artifactCount": .number(preview.artifactCount),
            "message": .string(preview.message), "waitingRemovals": .bool(preview.hasWaitingRemovals),
            "intents": .array(intents.map(CLIValue.string)), "sharedIdentity": .bool(plan.hasIdentitySibling),
            "artifacts": .array(plan.candidates.filter(\.isOwned).map { .string($0.path) }),
            "retirements": .array(plan.candidates.map { .object(["path": .string($0.path),
                "skill": .string($0.pair.skill.directoryName), "agent": .string($0.pair.platform.cliID),
                "owned": .bool($0.isOwned)]) })])
    }
}
