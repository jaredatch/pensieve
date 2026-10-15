import Foundation

extension AppRuntime {
    func applyLibrarySyncOutcome(_ result: SyncCycleResult) async {
        library.applySyncCycleOutcome(result)
        await library.manifestSaves?.refreshAndRetry()
    }

    func applyLibraryLaunchOutcome(unreadable: Bool) {
        library.setStoreUnreadable(unreadable)
        Task { @MainActor in await library.manifestSaves?.refreshAndRetry() }
    }
}
