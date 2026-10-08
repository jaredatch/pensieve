import Foundation
import SwiftData

/// The two directories every collaborator `AppRuntime` builds on its own is pointed at: the store
/// (`~/.pensieve` in production) and the App Support directory (`sync.lock`, `daemon.log`, `machine-id`).
/// A test injects temp directories once and no default can reach the real ones (LOG 2026-09-10T00:30:33Z:
/// the suite synced the developer's live store through one harness gap). Lives beside `AppRuntime.swift`
/// for the file's and the initializer's lint budgets (PLAN-29's precedent, `AppRuntime+DeployIndex.swift`).
struct AppRuntimePaths {
    struct NoAgentDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { false }
        func installedPlatforms() -> [PlatformTarget] { [] }
    }

    private struct NoDeploymentLinkService: LinkServiceProtocol {
        func removalOperation(skill: Skill, platform: PlatformTarget,
                              projectPath: String?) -> DeployRemovalOperation {
            DeployRemovalOperation(classify: { false }, delete: { false })
        }

        let paths: DeployPaths

        func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
        func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }
        func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }

        func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }
        func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            paths.linkPath(directoryName: skill.directoryName, platform: platform, projectPath: projectPath)
        }
        func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            paths.targetPath(directoryName: skill.directoryName, platform: platform, projectPath: projectPath)
        }
        func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
    }

    private struct NoDeploymentCursorCompiler: CursorCompilerProtocol {
        func removalOperation(skill: Skill, platform: PlatformTarget,
                              projectPath: String?) -> DeployRemovalOperation {
            DeployRemovalOperation(classify: { false }, delete: { false })
        }

        let outputRoot: String

        func compile(skill: Skill, projectPath: String?) throws {}
        func remove(skill: Skill, projectPath: String?) throws -> Bool { false }
        func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
            return false
        }
        func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { false }
        func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { false }

        func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
        func outputPath(skill: Skill, projectPath: String?) -> String {
            outputRoot + "/" + skill.directoryName + ".mdc"
        }
    }

    let runtimePaths: RuntimePaths
    var storeRoot: String { runtimePaths.storeRoot }
    var appSupportDir: String { runtimePaths.appSupportDir }
    var homeDirectory: String { runtimePaths.homeDirectory }
    var deployPaths: DeployPaths { runtimePaths.deployPaths }

    init(storeRoot: String, appSupportDir: String) {
        runtimePaths = RuntimePaths(storeRoot: storeRoot, appSupportDir: appSupportDir)
    }

    static let production = AppRuntimePaths(
        storeRoot: RuntimePaths.production.storeRoot,
        appSupportDir: RuntimePaths.production.appSupportDir
    )

    var syncLockPath: String { runtimePaths.syncLockPath }

    var gitAskpassHelperPath: String { runtimePaths.gitAskpassHelperPath }

    var skillInstallScratchRoot: String { appSupportDir + "/skill-install-scratch" }

    var updateCheckScratchRoot: String { appSupportDir + "/update-check-scratch" }

    var upstreamHistoryScratchRoot: String { appSupportDir + "/upstream-history-scratch" }

    var skillsDir: String { runtimePaths.skillsDir }

    var upstreamHistoryCacheDir: String { appSupportDir + "/upstream-history-cache" }

    /// Only the production pair reaches user-wide roots. Other pairs select sandboxed agent and Cursor roots.
    private var isProduction: Bool {
        runtimePaths.isProduction
    }

    private var cursorRulesDir: String {
        deployPaths.cursorUserRulesDirectory
    }

    struct HermeticDefaultsUnavailable: Error {}

    /// Preferences. A non-production pair gets the one hermetic suite, emptied on each construction, so
    /// the launch markers (`didRunStoreMigration`, the background-sync migration) and the scheduler's
    /// preference never touch the app's real domain; production keeps `.standard`. One shared suite, not
    /// one per runtime: a UUID suite leaves a plist behind in the real Preferences folder every time.
    func makeDefaults() throws -> UserDefaults {
        guard !isProduction else { return .standard }
        guard let defaults = UserDefaults(suiteName: Self.hermeticDefaultsSuite) else {
            throw HermeticDefaultsUnavailable()
        }
        defaults.removePersistentDomain(forName: Self.hermeticDefaultsSuite)
        return defaults
    }

    static let hermeticDefaultsSuite = "com.jaredatch.pensieve.hermetic"

    /// The scheduler reads the background-sync preference from the runtime's defaults, whichever suite
    /// they are, instead of its own `.standard` read.
    @MainActor
    static func makeScheduler(defaults: UserDefaults) -> SyncScheduler {
        SyncScheduler(backgroundSyncEnabled: {
            defaults.object(forKey: AppRuntime.backgroundSyncEnabledKey) as? Bool ?? true
        })
    }

    func hasRemoteConfigured(git suppliedGit: GitServiceProtocol? = nil) -> Bool {
        let git = suppliedGit ?? makeGitService()
        do { return try git.remoteURL(at: storeRoot) != nil } catch {
            return true // Unknown must defer backfill just like a configured remote.
        }
    }

    func isWorktreeClean() -> Bool {
        makeGitService().isWorktreeClean(at: storeRoot)
    }

    @MainActor
    func makeContainer() throws -> ModelContainer {
        if isProduction { return try AppRuntime.makeContainer() }
        return try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func makePlatformViewModel() -> PlatformViewModel {
        if isProduction {
            let files = FileService()
            return PlatformViewModel(fileService: files, linkService: LinkService(fileService: files, paths: deployPaths),
                cursorCompiler: CursorCompiler(fileService: files, skillStore: SkillStore(fileService: files, baseDir: skillsDir),
                    userRulesDirectory: cursorRulesDir), agentDetection: makeAgentDetection(),
                deployStateStore: DeployStateStore(fileService: files, appSupportDir: appSupportDir), skillsDirectory: skillsDir)
        }
        let fileService = FileService()
        return PlatformViewModel(
            fileService: fileService,
            linkService: NoDeploymentLinkService(paths: deployPaths),
            cursorCompiler: NoDeploymentCursorCompiler(outputRoot: cursorRulesDir),
            agentDetection: makeAgentDetection(fileService: fileService),
            deployStateStore: DeployStateStore(fileService: fileService, appSupportDir: appSupportDir),
            skillsDirectory: skillsDir
        )
    }

    /// A `@ModelActor` takes only its container; its collaborators arrive through `configure`. Every
    /// path-bearing one is set here, before any injected `coordinatorConfigure` runs.
    func configureCoordinator(_ coordinator: SyncCoordinator, defaults: UserDefaults,
                              fileService: FileServiceProtocol = FileService()) async {
        await coordinator.configure(
            engine: makeSyncEngine(fileService: fileService),
            git: makeGitService(fileService: fileService),
            credentials: makeCredentialStore(),
            rebuildService: makeStoreRebuildService(fileService: fileService),
            root: storeRoot,
            audit: SyncAudit(appSupport: appSupportDir, fileService: fileService),
            machine: (identity: MachineIdentity(fileService: fileService, appSupportDir: appSupportDir),
                stateService: makeMachineStateService(defaults: defaults, fileService: fileService))
        )
    }

    /// AppRuntime invokes the closure only while it holds sync.lock (initial launch and the retry loop
    /// both acquire before calling) — the reconciler must not re-acquire.
    func makeLaunchReconcile() -> AppRuntime.LaunchReconcile {
        return { context, alreadyMigrated in
            let fileService = FileService()
            let migrationService = StoreMigrationService(
                fileService: fileService,
                manifestService: ManifestService(),
                skillStore: SkillStore(fileService: fileService, baseDir: skillsDir)
            )
            return LaunchReconciler(
                migrationService: migrationService,
                fileService: fileService,
                root: storeRoot,
                lockPath: syncLockPath,
                git: makeGitService()
            ).reconcileOnLaunch(
                context: context,
                alreadyMigrated: alreadyMigrated,
                externallyHeldLock: true
            )
        }
    }

    /// Backfill probes the runtime's roots: user-wide in production, under App Support for temporary pairs.
    func makeLaunchBackfill() -> AppRuntime.LaunchBackfill {
        { context in
            let fileService = FileService()
            let backfillPaths = DeployStateBackfillPaths(pensieveSkillsDir: skillsDir, cursorUserRulesDir: cursorRulesDir,
                userSkillsRoot: deployPaths.userSkillsRoot)
            DeployStateBackfill(
                fileService: fileService,
                store: DeployStateStore(fileService: fileService, appSupportDir: appSupportDir),
                paths: backfillPaths
            ).backfill(context: context)
        }
    }

    /// The library reads and writes the store's `skills/` and regenerates `manifest/` under the store root;
    /// its watcher watches the same `skills/`. A test passes its own watcher.
    @MainActor
    func makeLibrary(
        fileWatchService: FileWatchServiceProtocol? = nil,
        notifier: @escaping SyncStateNotifying
    ) -> SkillLibraryViewModel {
        let fileService = FileService()
        return SkillLibraryViewModel(
            skillStore: SkillStore(fileService: fileService, baseDir: skillsDir),
            fileService: fileService,
            fileWatchService: fileWatchService ?? FileWatchService(rootDir: skillsDir),
            manifestService: ManifestService(),
            manifestRoot: storeRoot,
            notifier: notifier
        )
    }
}

extension AppRuntimePaths {
    /// Launch sweeps the same paths the services use, before the runtime starts its work.
    func cleanupGitHubSkillTemps(fileService: FileServiceProtocol = FileService()) {
        SkillInstallService.cleanupScratchRoot(fileService: fileService, scratchRoot: skillInstallScratchRoot)
        SkillInstallService.cleanupVendorTemps(fileService: fileService, storeRoot: storeRoot, lockPath: syncLockPath)
        UpdateCheckService.cleanupScratchRoot(fileService: fileService, scratchRoot: updateCheckScratchRoot)
        UpstreamHistoryService.cleanupScratchRoot(fileService: fileService, scratchRoot: upstreamHistoryScratchRoot)
    }

    @MainActor
    func makeUpstreamHistoryViewModel() -> UpstreamHistoryViewModel {
        let fileService = FileService()
        return UpstreamHistoryViewModel(
            service: makeUpstreamHistoryService(fileService: fileService),
            skillsRoot: skillsDir,
            fileService: fileService,
            cacheDirectory: upstreamHistoryCacheDir
        )
    }

    func makeUpstreamHistoryService(
        fileService: FileServiceProtocol = FileService()
    ) -> UpstreamHistoryService {
        let credentials = makeCredentialStore()
        return UpstreamHistoryService(
            gitService: makeGitService(fileService: fileService),
            credentialStore: credentials,
            fileService: fileService,
            contentHasher: makeSkillInstallService(
                credentialStore: credentials,
                fileService: fileService
            ),
            scratchRoot: upstreamHistoryScratchRoot
        )
    }

    func makeUpdateCheckOperation(service suppliedService: UpdateCheckService? = nil) -> AppRuntime.UpdateCheckOperation {
        let service = suppliedService ?? makeUpdateCheckService()
        return { container in
            let report = try service.checkAll(context: ModelContext(container))
            return try UpdateCheckExecutionFailure.preservingReport(report) {
                let context = ModelContext(container)
                let skills = try context.fetch(FetchDescriptor<Skill>())
                let results = Dictionary(uniqueKeysWithValues: skills.map {
                    ($0.id, SkillUpdateCheckResult(
                        updateAvailable: $0.updateAvailable,
                        checkError: $0.checkError
                    ))
                })
                return RuntimeUpdateCheckResult(report: report, skills: results)
            }
        }
    }

    func makeUpdatesViewModelOperations(
        fileService: FileServiceProtocol = FileService()
    ) -> UpdatesViewModel.DefaultOperations {
        let credentials = makeCredentialStore()
        let installer = makeSkillInstallService(
            credentialStore: credentials,
            fileService: fileService
        )
        return UpdatesViewModel.DefaultOperations(
            updateCheckService: makeUpdateCheckService(
                credentialStore: credentials,
                fileService: fileService,
                contentHasher: installer
            ),
            skillInstallService: installer
        )
    }

    @MainActor
    func makeSkillProvenanceViewModel() -> SkillProvenanceViewModel {
        let serviceFactory = makeSkillProvenanceServiceFactory()
        return SkillProvenanceViewModel(
            driftOperation: SkillProvenanceViewModel.makeDriftOperation(
                serviceFactory: serviceFactory
            ),
            checkOperation: SkillProvenanceViewModel.makeCheckOperation(
                serviceFactory: serviceFactory
            )
        )
    }

    func makeSkillProvenanceServiceFactory() -> SkillProvenanceViewModel.UpdateCheckServiceFactory {
        { makeUpdateCheckService() }
    }

    func makeUpdateCheckService(fileService: FileServiceProtocol = FileService()) -> UpdateCheckService {
        let credentials = makeCredentialStore()
        return makeUpdateCheckService(
            credentialStore: credentials,
            fileService: fileService,
            contentHasher: makeSkillInstallService(
                credentialStore: credentials,
                fileService: fileService
            )
        )
    }

    private func makeUpdateCheckService(
        credentialStore: CredentialStoreProtocol,
        fileService: FileServiceProtocol,
        contentHasher: SkillContentHashing
    ) -> UpdateCheckService {
        return UpdateCheckService(
            gitService: makeGitService(fileService: fileService),
            credentialStore: credentialStore,
            fileService: fileService,
            contentHasher: contentHasher,
            scratchRoot: updateCheckScratchRoot,
            storeRoot: storeRoot
        )
    }

    private func makeSkillInstallService(
        credentialStore: CredentialStoreProtocol,
        fileService: FileServiceProtocol
    ) -> SkillInstallService {
        SkillInstallService(
            gitService: makeGitService(fileService: fileService),
            credentialStore: credentialStore,
            fileService: fileService,
            scratchRoot: skillInstallScratchRoot,
            storeRoot: storeRoot,
            lockPath: syncLockPath
        )
    }

    func makeCredentialStore() -> CredentialStoreProtocol {
        runtimePaths.credentialStore
    }

}
