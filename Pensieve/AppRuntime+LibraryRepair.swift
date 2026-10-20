import Foundation
import SwiftData

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

    func performDeferredLaunchBackfillIfNeeded(afterRepair: Bool = false, afterSync: SyncCycleResult? = nil) async {
        if afterRepair, successfulLibraryReads > 0 { return }
        let mayBackfill = switch afterSync {
        case nil, .synced?: true
        default: false
        }
        let performed = mayBackfill ? await runDeferredLaunchBackfill() : false
        if performed { finishLaunchBackfill() } else if let afterSync { convergence.run(after: afterSync) }
    }

    private func runDeferredLaunchBackfill() async -> Bool {
        guard needsLaunchBackfillAfterCoordinator, library.manifestSaves?.libraryDamaged != true,
              library.manifestSaves?.requiresNewerVersion != true else { return false }
        needsLaunchBackfillAfterCoordinator = false
        await BlockingWork.run { [container, launchBackfill] in launchBackfill(ModelContext(container)) }
        return true
    }

    func finishLaunchBackfill() {
        platformVM.refreshDeployIndex()
        convergence.runAfterLaunchIngest()
    }

    func applyLibraryLaunchOutcome(_ rebuild: RebuildResult, repaired: @escaping () async -> Void = {}) {
        library.manifestSaves?.didReadRepairedLibrary = rebuild.manifestDamaged ? repaired : {}
        library.setStoreUnreadable(rebuild.storeUnreadable && !rebuild.manifestDamaged)
        library.manifestSaves?.libraryDamaged = rebuild.manifestDamaged
        Task { @MainActor in await library.manifestSaves?.refreshAndRetry() }
    }
}
