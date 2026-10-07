import Foundation

extension AppRuntime {
    /// Constructs launch collaborators from explicit inputs without owning runtime launch state.
    static func makeLaunchIntentReconciler(platformVM: PlatformViewModel, paths: AppRuntimePaths) -> IntentReconciler {
        IntentReconciler(platformVM: platformVM,
            machineIdentity: MachineIdentity(appSupportDir: paths.appSupportDir))
    }

    static func deferredLaunchOutcome() -> LaunchReconcileOutcome {
        LaunchReconcileOutcome(rebuild: RebuildResult(), migrationRan: false,
                               ingestionNeedsRetry: true, quarantined: true)
    }

    /// Samples and applies one cycle's watcher state; the caller owns git evidence and launch signaling.
    static func runCoordinatorCycle(_ coordinator: SyncCoordinator, library: SkillLibraryViewModel,
                                    paths: AppRuntimePaths) async -> SyncCycleResult {
        let result = await coordinator.runCycle()
        let sampledWatcherEventSequence = library.coordinatorWatcherEventSequence
        let hasUnsyncedChanges = await BlockingWork.run { !paths.isWorktreeClean() }
        library.finishCoordinatorChanges(
            hasUnsyncedChanges: hasUnsyncedChanges,
            sampledWatcherEventSequence: sampledWatcherEventSequence,
            recheckHasUnsyncedChanges: { !paths.isWorktreeClean() }
        )
        return result
    }
}
