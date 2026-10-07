import os
import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var section: SidebarSection?
    let showsMachines: Bool

    var body: some View {
        SidebarOutline(items: SidebarRows.items(showsMachines: showsMachines), selection: $section)
            .navigationTitle("Pensieve")
    }
}

// File scope and internal for CategoryReconcileWiringTests; this is the only raw Project delete path.
/// Insert + persist a freshly-built Project, then regenerate the manifest (best-effort, surfaced via
/// log). Extracted from AddProjectSheet so the register path is unit-testable and the manifest stays
/// current after a registration. (PLAN-07 / 07.3)
@discardableResult
@MainActor
func registerProject(_ project: Project,
                     manifestService: ManifestSnapshotting? = nil,
                     manifestRoot: String = Constants.pensieveBaseDir,
                     context: ModelContext,
                     intentReconciler: (@MainActor (ModelContext) -> BatchResult)? = nil,
                     notifier: SyncStateNotifying = SyncStateNotifier.suppressed) -> Project {
    context.insert(project)
    try? context.save()
    regenerateProjectManifest(manifestService: manifestService, manifestRoot: manifestRoot, context: context)
    _ = intentReconciler?(context)
    notifier()
    return project
}

private func regenerateProjectManifest(manifestService: ManifestSnapshotting?,
                                       manifestRoot: String,
                                       context: ModelContext) {
    guard let manifestService else { return }
    do {
        try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
    } catch {
        Logger(subsystem: "com.jaredatch.pensieve", category: "manifest")
            .warning("Project mutation saved, but manifest regeneration failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Save and publish request withdrawal, remove prepared artifacts while the project is live,
/// then unregister. Failures retain registration and allow a retry to finish partial cleanup.
@discardableResult
@MainActor
func removeRegisteredProject(_ project: Project,
                             reconciler: CategoryReconcilerProtocol,
                             manifestService: ManifestSnapshotting? = nil,
                             manifestRoot: String = Constants.pensieveBaseDir,
                             stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
                             platformVM: PlatformViewModel, localMachineID: String? = nil,
                             confirmedPreview: ProjectRemovalPreview? = nil,
                             context: ModelContext,
                             notifier: SyncStateNotifying = SyncStateNotifier.suppressed,
                             logFailure: @escaping (String) -> Void = logProjectRemovalFailure) -> BatchResult {
    defer { notifier() }
    let intentRows: [IntentAssignment], intents: [MachineDeployIntent]
    let plan: ProjectRemovalPlan
    do {
        intentRows = try stateFetcher.intentAssignments(context: context)
        intents = try stateFetcher.deployIntents(context: context)
        plan = try ProjectRemovalPlan.prepare(project: project, platformVM: platformVM,
                                               context: context, stateFetcher: stateFetcher)
        if let failure = projectRemovalAdmissionFailure(project: project, plan: plan,
            confirmedPreview: confirmedPreview, intents: intents, localMachineID: localMachineID) {
            var result = BatchResult()
            result.operationFailures.append(failure)
            return result
        }
        try plan.saveWaitingRemovals(project: project, platformVM: platformVM)
    } catch let error as ProjectFolderError {
        var result = BatchResult()
        result.operationFailures.append("Couldn't check the project folder: " + error.localizedDescription)
        return result
    } catch { return BatchResult.readFailure("project deploy records", error: error) }
    let publication = ProjectRemovalWithdrawal(manifestService: manifestService,
        manifestRoot: manifestRoot, logFailure: logFailure)
    let request = ProjectRemovalWithdrawalRequest(keepingSharedKey: plan.hasIdentitySibling,
        intents: intents, localMachineID: localMachineID)
    var result = BatchResult()
    do {
        result.didWithdrawProjectRequests = try publication.apply(project: project, request: request, context: context)
    } catch {
        result.didWithdrawProjectRequests = (error as? ProjectRemovalWithdrawalFailure)?.didWithdrawRequests ?? false
        result.operationFailures.append(error.localizedDescription)
        return result
    }
    result.append(reconciler.reconcileRemovingProject(project.id, preservingProjects: plan.folderSiblingIDs, context: context))
    do {
        if context.hasChanges { try context.save() }
    } catch {
        context.rollback()
        result.operationFailures.append("Couldn't save project reconciliation: " + error.localizedDescription)
    }
    logUnrelatedProjectFailures(result, removing: project, logFailure: logFailure)
    result.outcomes.removeAll { outcome in
        guard case .project(let id)? = outcome.target else { return false }
        return id != project.id
    }
    guard !result.hasFailures else { return result }
    let cleanup = plan.removeArtifacts(project: project, platformVM: platformVM)
    result.append(cleanup)
    result.append(completeProjectRemoval(project, intentRows: intentRows, cleanup: cleanup,
        priorFailed: result.hasFailures, context: context))
    return result
}

private func projectRemovalAdmissionFailure(project: Project, plan: ProjectRemovalPlan,
                                            confirmedPreview: ProjectRemovalPreview?,
                                            intents: [MachineDeployIntent], localMachineID: String?) -> String? {
    if let confirmedPreview {
        let folderChanged = confirmedPreview.folderIsMissing != plan.preview.folderIsMissing
            || confirmedPreview.folderIsUncheckable != plan.preview.folderIsUncheckable
            || confirmedPreview.folderIsShared != plan.preview.folderIsShared
        if folderChanged {
            return "The project folder changed at \(project.path) while confirmation was open. Please review removal again."
        }
        if confirmedPreview.artifactCount != plan.preview.artifactCount {
            return "The project changed while confirmation was open. Please review removal again."
        }
    }
    if !plan.hasIdentitySibling, let key = project.identityKey, localMachineID == nil,
       intents.contains(where: { $0.projectKey == key }) {
        return "Couldn't identify this Mac to withdraw its project intents. Try again."
    }
    return nil
}

@MainActor
private func completeProjectRemoval(_ project: Project, intentRows: [IntentAssignment], cleanup: BatchResult,
                                    priorFailed: Bool,
                                    context: ModelContext) -> BatchResult {
    var result = BatchResult()
    let projectID = project.id, completed = cleanup.completedPairs
    do {
        for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>()) where row.projectID == projectID {
            let pair = BatchPairKey(skillID: row.skillID, platform: row.platform, target: .project(projectID))
            if !priorFailed || completed.contains(pair) { context.delete(row) }
        }
        for row in intentRows where row.projectID == projectID {
            let completedDirect = PlatformTarget(rawValue: row.platformRaw).map {
                completed.contains(BatchPairKey(skillID: row.skillID, platform: $0, target: .project(projectID)))
            } ?? false
            if !priorFailed || completedDirect { context.delete(row) }
        }
        if !priorFailed { context.delete(project) }
        if context.hasChanges { try context.save() }
    } catch {
        context.rollback()
        result.operationFailures.append("Couldn't save project removal: " + error.localizedDescription)
    }
    return result
}

private func logProjectRemovalFailure(_ message: String) {
    Logger(subsystem: "com.jaredatch.pensieve", category: "projects")
        .warning("Project removal reconciliation failed: \(message, privacy: .public)")
}

private func logUnrelatedProjectFailures(_ result: BatchResult, removing project: Project,
                                         logFailure: @escaping (String) -> Void) {
    for failure in result.failures {
        guard case .project(let id)? = failure.target, id != project.id,
              let error = failure.error else { continue }
        logFailure("\(id.uuidString): \(error)")
    }
}
