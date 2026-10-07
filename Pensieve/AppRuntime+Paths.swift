import Foundation
import SwiftData

/// The two directories every collaborator `AppRuntime` builds on its own is pointed at: the store
/// (`~/.pensieve` in production) and the App Support directory (`sync.lock`, `daemon.log`, `machine-id`).
/// A test injects temp directories once and no default can reach the real ones (LOG 2026-09-10T00:30:33Z:
/// the suite synced the developer's live store through one harness gap). Lives beside `AppRuntime.swift`
/// for the file's and the initializer's lint budgets (PLAN-29's precedent, `AppRuntime+DeployIndex.swift`).
struct AppRuntimePaths {
    private struct NoAgentDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { false }
        func installedPlatforms() -> [PlatformTarget] { [] }
    }

    private struct NoDeploymentLinkService: LinkServiceProtocol {
        let outputRoot: String

        func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
        func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }
        func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }

        func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }
        func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            outputRoot + "/" + platform.rawValue + "/" + skill.directoryName
        }
        func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
            outputRoot + "/targets/" + skill.directoryName
        }
        func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
    }

    private struct NoDeploymentCursorCompiler: CursorCompilerProtocol {
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

    let storeRoot: String
    let appSupportDir: String

    static let production = AppRuntimePaths(
        storeRoot: Constants.pensieveBaseDir,
        appSupportDir: PathConstants.pensieveAppSupportDir
    )

    var syncLockPath: String { appSupportDir + "/sync.lock" }

    var skillsDir: String { storeRoot + "/skills" }

    var upstreamHistoryCacheDir: String { appSupportDir + "/upstream-history-cache" }

    /// The agent directories (`~/.claude/skills`, Cursor's rules, …) sit outside both roots, so only the
    /// production pair may reach them; any other pair gets none, and a Cursor rules directory of its own.
    private var isProduction: Bool {
        storeRoot == Constants.pensieveBaseDir && appSupportDir == PathConstants.pensieveAppSupportDir
    }

    private var cursorRulesDir: String {
        isProduction ? PathConstants.cursorUserRulesDir : appSupportDir + "/cursor-rules"
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

    func hasRemoteConfigured(git: GitServiceProtocol = GitService()) -> Bool {
        do { return try git.remoteURL(at: storeRoot) != nil } catch {
            return true // Unknown must defer backfill just like a configured remote.
        }
    }

    func isWorktreeClean() -> Bool {
        GitService().isWorktreeClean(at: storeRoot)
    }

    @MainActor
    func makeContainer() throws -> ModelContainer {
        if isProduction { return try AppRuntime.makeContainer() }
        return try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func makePlatformViewModel() -> PlatformViewModel {
        guard !isProduction else { return PlatformViewModel() }
        let fileService = FileService()
        return PlatformViewModel(
            fileService: fileService,
            linkService: NoDeploymentLinkService(outputRoot: appSupportDir + "/agent-links"),
            cursorCompiler: NoDeploymentCursorCompiler(outputRoot: cursorRulesDir),
            agentDetection: NoAgentDetection(),
            deployStateStore: DeployStateStore(fileService: fileService, appSupportDir: appSupportDir)
        )
    }

    /// A `@ModelActor` takes only its container; its collaborators arrive through `configure`. Every
    /// path-bearing one is set here, before any injected `coordinatorConfigure` runs.
    func configureCoordinator(_ coordinator: SyncCoordinator) async {
        await coordinator.configure(
            engine: SyncEngine(lockPath: syncLockPath),
            credentials: makeCredentialStore(),
            root: storeRoot,
            audit: SyncAudit(appSupport: appSupportDir),
            machineIdentity: MachineIdentity(appSupportDir: appSupportDir)
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
                lockPath: syncLockPath
            ).reconcileOnLaunch(
                context: context,
                alreadyMigrated: alreadyMigrated,
                externallyHeldLock: true
            )
        }
    }

    /// The launch backfill writes `deploy-state.json` in App Support and reads the store's skills; the
    /// user-wide agent roots it probes are reachable only from the production pair.
    func makeLaunchBackfill() -> AppRuntime.LaunchBackfill {
        { context in
            let fileService = FileService()
            var backfillPaths = DeployStateBackfillPaths(pensieveSkillsDir: skillsDir, cursorUserRulesDir: cursorRulesDir)
            if !isProduction { backfillPaths.userSkillsRoot = { _ in nil } }
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
            credentialStore: credentials,
            fileService: fileService,
            contentHasher: makeSkillInstallService(
                credentialStore: credentials,
                fileService: fileService
            ),
            scratchRoot: appSupportDir + "/upstream-history-scratch"
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

    func makeUpdatesViewModelOperations() -> UpdatesViewModel.DefaultOperations {
        let credentials = makeCredentialStore()
        let installer = makeSkillInstallService(
            credentialStore: credentials,
            fileService: FileService()
        )
        return UpdatesViewModel.DefaultOperations(
            updateCheckService: makeUpdateCheckService(
                credentialStore: credentials,
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

    func makeUpdateCheckService() -> UpdateCheckService {
        let credentials = makeCredentialStore()
        return makeUpdateCheckService(
            credentialStore: credentials,
            contentHasher: makeSkillInstallService(
                credentialStore: credentials,
                fileService: FileService()
            )
        )
    }

    private func makeUpdateCheckService(
        credentialStore: CredentialStoreProtocol,
        contentHasher: SkillContentHashing
    ) -> UpdateCheckService {
        return UpdateCheckService(
            credentialStore: credentialStore,
            contentHasher: contentHasher,
            scratchRoot: appSupportDir + "/update-check-scratch",
            storeRoot: storeRoot
        )
    }

    private func makeSkillInstallService(
        credentialStore: CredentialStoreProtocol,
        fileService: FileServiceProtocol
    ) -> SkillInstallService {
        SkillInstallService(
            credentialStore: credentialStore,
            fileService: fileService,
            scratchRoot: appSupportDir + "/skill-install-scratch",
            storeRoot: storeRoot,
            lockPath: syncLockPath
        )
    }

    private func makeCredentialStore() -> CredentialStoreProtocol {
        isProduction ? KeychainCredentialStore() : InMemoryCredentialStore()
    }

    @MainActor
    func makeConvergence(
        container: ModelContainer,
        platformVM: PlatformViewModel,
        intentReconciler: IntentReconciler
    ) -> PostSyncConvergence {
        PostSyncConvergence(
            root: storeRoot,
            deployReconciler: makeDeployReconciler(),
            contextFactory: { ModelContext(container) },
            categoryReconciler: CategoryReconciler(platformVM: platformVM),
            intentReconciler: intentReconciler,
            auditLog: { SyncAudit(appSupport: appSupportDir).append(category: $0, detail: $1) },
            didConverge: { platformVM.noteDeployStateChanged() }
        )
    }

    private func makeDeployReconciler() -> DeployReconciler {
        let fileService = FileService()
        return DeployReconciler(
            fileService: fileService,
            deployState: DeployStateStore(fileService: fileService, appSupportDir: appSupportDir),
            pensieveSkillsDir: skillsDir,
            agentSkillDirs: isProduction ? DeployReconciler.defaultAgentSkillDirs : [],
            cursorRulesDir: cursorRulesDir
        )
    }
}
