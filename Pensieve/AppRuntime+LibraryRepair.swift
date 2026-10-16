import Foundation

extension AppRuntime {
    func scheduleLibrarySyncOutcome(_ result: SyncCycleResult) {
        let step = paths.syncSteps.begin()
        Task {
            defer { paths.syncSteps.finish(step) }
            await applyLibrarySyncOutcome(result)
        }
    }

    func applyLibrarySyncOutcome(_ result: SyncCycleResult) async {
        let saves = library.manifestSaves
        let repaired = saves?.didReadRepairedLibrary
        // A successful cycle owns convergence after its recovery read.
        if case .synced = result { saves?.didReadRepairedLibrary = {} }
        library.applySyncCycleOutcome(result)
        await saves?.refreshAndRetry()
        if let repaired { saves?.didReadRepairedLibrary = repaired }
        await performDeferredLaunchBackfillIfNeeded(afterSync: result)
    }

    func applyLibraryLaunchOutcome(_ rebuild: RebuildResult, repaired: @escaping () async -> Void = {}) {
        library.manifestSaves?.didReadRepairedLibrary = rebuild.manifestDamaged ? repaired : {}
        library.setStoreUnreadable(rebuild.storeUnreadable && !rebuild.manifestDamaged)
        library.manifestSaves?.libraryDamaged = rebuild.manifestDamaged
    }
}
