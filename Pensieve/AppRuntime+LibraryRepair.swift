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
        await performDeferredLaunchBackfillIfNeeded(trigger: .sync(result))
    }

    enum LaunchBackfillTrigger { case repair, sync(SyncCycleResult) }

    func performDeferredLaunchBackfillIfNeeded(trigger: LaunchBackfillTrigger) async {
        if case .repair = trigger, successfulLibraryReads > 0 { return }
        let mayBackfill = switch trigger {
        case .repair, .sync(.synced): true
        default: false
        }
        let performed = mayBackfill ? await runDeferredLaunchBackfill() : false
        if performed { finishLaunchBackfill() } else if case .sync(let result) = trigger {
            convergence.run(after: result)
        }
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
