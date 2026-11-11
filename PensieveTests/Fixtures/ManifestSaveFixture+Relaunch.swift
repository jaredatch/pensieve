import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension ManifestSaveFixture {
    func quit() {
        runtime?.commandServer?.stop()
        currentLibrary?.stopWatching()
        // A stopped process cannot let its queued worker publish after relaunch.
        currentSaves?.worker?.cancel()
        for item in currentSaves?.items ?? [] {
            StoreIngestState.shared(for: item.presentation.context.container).finish(item.id)
        }
        currentSaves?.items.removeAll()
        runtime = nil
        currentAlpha = nil; currentBeta = nil; currentLocal = nil; currentDoomed = nil; currentProject = nil
        currentCategories = nil; currentLibrary = nil; currentSaves = nil; currentContext = nil
    }

    func relaunchThroughRuntime() async throws {
        precondition(persistent)
        quit()
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: storeURL))
        let paths = AppRuntimePaths(storeRoot: root, appSupportDir: root + "/support")
        let defaults = try paths.makeDefaults()
        defaults.set(false, forKey: AppRuntime.backgroundSyncEnabledKey)
        defaults.set(true, forKey: AppRuntime.migrationDefaultsKey)
        let runtime = try AppRuntime(container: container,
            scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
            defaults: defaults, launchBackfill: { _ in }, paths: paths,
            updateCheckOperation: { _ in RuntimeUpdateCheckResult(report: UpdateCheckReport(), skills: [:]) },
            gitUsabilityProbe: { .usable }, coordinatorConfigure: { coordinator in
                await coordinator.configure(engine: RecoveredPresentationEngine(), git: paths.makeGitService(),
                    credentials: InMemoryCredentialStore(), root: paths.storeRoot,
                    audit: SyncAudit(appSupport: paths.appSupportDir),
                    machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
            })
        self.runtime = runtime
        currentContext = container.mainContext
        currentLibrary = runtime.library
        currentSaves = try XCTUnwrap(library.manifestSaves)
        currentCategories = CategoryStore(manifestSaves: saves)
        await runtime.performLaunchWorkIfNeeded(context: context)
        library.stopWatching()
        let skills = try context.fetch(FetchDescriptor<Skill>())
        currentAlpha = skills.first { $0.directoryName == "alpha" }
        currentBeta = skills.first { $0.directoryName == "beta" }
        let rows = try context.fetch(FetchDescriptor<Pensieve.Category>())
        currentLocal = rows.first { $0.name == "Local" }
        currentDoomed = rows.first { $0.name == "ZDelete" }
        currentProject = try context.fetch(FetchDescriptor<Project>()).first
    }

}
