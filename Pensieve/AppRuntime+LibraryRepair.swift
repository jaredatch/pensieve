import Foundation

extension AppRuntime {
    func applyLibrarySyncOutcome(_ result: SyncCycleResult) async {
        library.applySyncCycleOutcome(result)
        await library.manifestSaves?.refreshAndRetry()
    }

    func applyLibraryLaunchOutcome(_ rebuild: RebuildResult, repaired: @escaping () -> Void = {}) {
        library.manifestSaves?.didReadRepairedLibrary = repaired
        library.setStoreUnreadable(rebuild.storeUnreadable && !rebuild.manifestDamaged)
        library.manifestSaves?.libraryDamaged = rebuild.manifestDamaged
        Task { @MainActor in await library.manifestSaves?.refreshAndRetry() }
    }
}
