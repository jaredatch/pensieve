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

/// Reconcile category removal while the project is live, remove this Mac's remaining recorded
/// artifacts, then publish intent withdrawal before saving entity deletion. Failures retain registration.
@discardableResult
@MainActor
func removeRegisteredProject(_ project: Project, categoryStore: CategoryStoreProtocol,
                             reconciler: CategoryReconcilerProtocol,
                             manifestService: ManifestSnapshotting? = nil,
                             manifestRoot: String = Constants.pensieveBaseDir,
                             stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
                             platformVM: PlatformViewModel, localMachineID: String? = nil,
                             context: ModelContext,
                             notifier: SyncStateNotifying = SyncStateNotifier.suppressed,
                             logFailure: (String) -> Void = logProjectRemovalFailure) -> BatchResult {
    defer { notifier() }
    let intentRows: [IntentAssignment]
    let intents: [MachineDeployIntent]
    let hasSibling: Bool
    let plan: ProjectRemovalPlan
    do {
        intentRows = try stateFetcher.intentAssignments(context: context)
        intents = try stateFetcher.deployIntents(context: context)
        hasSibling = try stateFetcher.projects(context: context).contains {
            $0.id != project.id && project.identityKey != nil && $0.identityKey == project.identityKey
        }
        if !hasSibling, let key = project.identityKey, localMachineID == nil,
           intents.contains(where: { $0.projectKey == key }) {
            var result = BatchResult()
            result.operationFailures.append("Couldn't identify this Mac to withdraw its project intents. Try again.")
            return result
        }
        plan = try ProjectRemovalPlan.prepare(project: project, platformVM: platformVM,
                                             context: context, stateFetcher: stateFetcher)
    } catch {
        return BatchResult.readFailure("project deploy records", error: error)
    }
    var result = categoryStore.reconcileAfterRemovingProject(
        project, reconciler: reconciler, context: context, notifier: SyncStateNotifier.suppressed)
    logUnrelatedProjectFailures(result, removing: project, logFailure: logFailure)
    result.outcomes.removeAll { outcome in
        guard case .project(let id)? = outcome.target else { return false }
        return id != project.id
    }
    guard !result.hasFailures else { return result }
    if !plan.preview.folderIsMissing { result.append(plan.removeArtifacts(project: project, platformVM: platformVM)) }
    guard !result.hasFailures else { return result }
    let records = ProjectRemovalRecords(intentRows: intentRows, intents: intents,
        hasSibling: hasSibling, localMachineID: localMachineID)
    do {
        try finishProjectRemoval(project, records: records, manifestService: manifestService,
                                 manifestRoot: manifestRoot, context: context)
    } catch {
        context.rollback()
        result.operationFailures.append(error.localizedDescription)
    }
    return result
}

private struct ProjectRemovalRecords {
    let intentRows: [IntentAssignment]
    let intents: [MachineDeployIntent]
    let hasSibling: Bool
    let localMachineID: String?
}

@MainActor
private func finishProjectRemoval(_ project: Project, records: ProjectRemovalRecords,
                                  manifestService: ManifestSnapshotting?, manifestRoot: String,
                                  context: ModelContext) throws {
    let projectID = project.id, key = project.identityKey
    for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>()) where row.projectID == projectID {
        context.delete(row)
    }
    for row in records.intentRows where row.projectID == projectID { context.delete(row) }
    if !records.hasSibling, let key, let localMachineID = records.localMachineID {
        for row in records.intents where row.machineID == localMachineID && row.projectKey == key { context.delete(row) }
    }
    context.delete(project)
    var operation = "write the project manifest"
    do {
        if let manifestService {
            try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
        }
        operation = "save project removal"
        try context.save()
    } catch {
        throw ProjectRemovalPersistenceFailure(operation: operation, underlying: error)
    }
}

private struct ProjectRemovalPersistenceFailure: LocalizedError {
    let operation: String
    let underlying: Error
    var errorDescription: String? { "Couldn't " + operation + ": " + underlying.localizedDescription }
}

private func logProjectRemovalFailure(_ message: String) {
    Logger(subsystem: "com.jaredatch.pensieve", category: "projects")
        .warning("Project removal reconciliation failed: \(message, privacy: .public)")
}

private func logUnrelatedProjectFailures(_ result: BatchResult, removing project: Project,
                                         logFailure: (String) -> Void) {
    for failure in result.failures {
        guard case .project(let id)? = failure.target, id != project.id,
              let error = failure.error else { continue }
        logFailure("\(id.uuidString): \(error)")
    }
}
