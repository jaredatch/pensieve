import Foundation
import SwiftData

struct LaunchJobResult {
    let outcome: LaunchReconcileOutcome
    let backfilled: Bool
}

extension AppRuntime {
    nonisolated static func reconcileLaunch(
        container: ModelContainer, reconcile: LaunchReconcile, backfill: LaunchBackfill,
        hasRemote: () -> Bool, lockPath: String, alreadyMigrated: Bool
    ) -> LaunchJobResult {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else {
            return LaunchJobResult(outcome: deferredLaunchOutcome(), backfilled: false)
        }
        defer { lock.release() }
        let context = ModelContext(container)
        let outcome = reconcile(context, alreadyMigrated)
        let backfilled = !outcome.rebuild.storeUnreadable && !outcome.ingestionNeedsRetry
            && !outcome.quarantined && (outcome.ingestedHeadStamp != nil || !hasRemote())
        if backfilled { backfill(context) }
        return LaunchJobResult(outcome: outcome, backfilled: backfilled)
    }

    /// Constructs launch collaborators from explicit inputs without owning runtime launch state.
    static func makeLaunchIntentReconciler(platformVM: PlatformViewModel, paths: AppRuntimePaths) -> IntentReconciler {
        IntentReconciler(platformVM: platformVM,
            machineIdentity: MachineIdentity(appSupportDir: paths.appSupportDir))
    }

    nonisolated static func deferredLaunchOutcome() -> LaunchReconcileOutcome {
        LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false,
                               ingestionNeedsRetry: true, quarantined: true)
    }

    /// Samples and applies one cycle's watcher state; the caller owns git evidence and launch signaling.
    static func runCoordinatorCycle(_ coordinator: SyncCoordinator, library: SkillLibraryViewModel,
                                    paths: AppRuntimePaths) async -> SyncCycleResult {
        let result = await coordinator.runCycle()
        let sampledWatcherEventSequence = library.coordinatorWatcherEventSequence
        let hasUnsyncedChanges = await BlockingWork.run { !paths.isWorktreeClean() }
        await library.finishCoordinatorChanges(
            hasUnsyncedChanges: hasUnsyncedChanges,
            sampledWatcherEventSequence: sampledWatcherEventSequence,
            recheckHasUnsyncedChanges: { !paths.isWorktreeClean() }
        )
        return result
    }
}
