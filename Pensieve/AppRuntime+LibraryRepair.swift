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
        // Successful cycles own convergence after the read. Count overlapping owners without
        // replacing the permanent repair callback while either one is suspended.
        let successful: Bool = if case .synced = result { true } else { false }
        if successful { successfulLibraryReads += 1 }
        defer { if successful { successfulLibraryReads -= 1 } }
        library.applySyncCycleOutcome(result)
        await saves?.refreshAndRetry()
        await performDeferredLaunchBackfillIfNeeded(afterSync: result)
    }

    func applyLibraryLaunchOutcome(_ rebuild: RebuildResult, repaired: @escaping () async -> Void = {}) {
        library.manifestSaves?.didReadRepairedLibrary = rebuild.manifestDamaged ? repaired : {}
        library.setStoreUnreadable(rebuild.storeUnreadable && !rebuild.manifestDamaged)
        library.manifestSaves?.libraryDamaged = rebuild.manifestDamaged
        Task { @MainActor in await library.manifestSaves?.refreshAndRetry() }
    }
}
