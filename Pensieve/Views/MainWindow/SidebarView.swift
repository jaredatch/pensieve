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

/// Remove a registered project the category-aware way: read its intent ownership before mutation,
/// prune it from every category, reconcile its category-managed deploys OFF while it is still a live record,
/// then delete the Project RECORD —
/// but ONLY on a clean reconcile (a failed unlink keeps the project registered + its ledger row, so
/// the next attempt can retry; no silent orphan). The project's own non-category files are
/// left in place (PLAN-05 registration-only delete, extended with category cleanup). Returns the result.
@discardableResult
@MainActor
func removeRegisteredProject(_ project: Project, categoryStore: CategoryStoreProtocol,
                             reconciler: CategoryReconcilerProtocol,
                             manifestService: ManifestSnapshotting? = nil,
                             manifestRoot: String = Constants.pensieveBaseDir,
                             stateFetcher: ReconcilerStateFetching = ReconcilerStateFetcher(),
                             context: ModelContext,
                             notifier: SyncStateNotifying = SyncStateNotifier.suppressed,
                             logFailure: (String) -> Void = logProjectRemovalFailure) -> BatchResult {
    defer { notifier() }
    let intentRows: [IntentAssignment]
    do {
        intentRows = try stateFetcher.intentAssignments(context: context)
    } catch {
        return BatchResult.readFailure("project intent ownership", error: error)
    }
    var result = categoryStore.reconcileAfterRemovingProject(
        project,
        reconciler: reconciler,
        context: context,
        notifier: SyncStateNotifier.suppressed
    )
    logUnrelatedProjectFailures(result, removing: project, logFailure: logFailure)
    result.outcomes.removeAll { outcome in
        guard case .project(let id)? = outcome.target else { return false }
        return id != project.id
    }
    guard !result.hasFailures else { return result }
    do {
        for row in try context.fetch(FetchDescriptor<SkillProjectAssignment>()) where row.projectID == project.id {
            context.delete(row)
        }
    } catch {
        result.append(BatchResult.readFailure("project category ownership", error: error))
        return result
    }
    for row in intentRows where row.projectID == project.id {
        context.delete(row)
    }
    context.delete(project)
    try? context.save()
    regenerateProjectManifest(manifestService: manifestService, manifestRoot: manifestRoot, context: context)
    return result
}

private func logProjectRemovalFailure(_ message: String) {
    Logger(subsystem: "com.jaredatch.pensieve", category: "projects")
        .warning("Project removal reconciliation failed: \(message, privacy: .public)")
}

private func logUnrelatedProjectFailures(_ result: BatchResult, removing project: Project,
                                         logFailure: (String) -> Void) {
    let failures = result.failures.filter { outcome in
        guard case .project(let id)? = outcome.target else { return false }
        return id != project.id
    }
    for failure in failures {
        guard case .project(let id)? = failure.target, let error = failure.error else { continue }
        logFailure("\(id.uuidString): \(error)")
    }
}
