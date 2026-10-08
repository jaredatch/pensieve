import Foundation
import SwiftData

extension AppRuntimePaths {
    func makeGitService(fileService: FileServiceProtocol = FileService()) -> GitService {
        runtimePaths.makeGitService(fileService: fileService)
    }

    @MainActor
    func makeConvergence(
        container: ModelContainer,
        platformVM: PlatformViewModel,
        intentReconciler: IntentReconciler
    ) -> PostSyncConvergence {
        PostSyncConvergence(
            root: storeRoot,
            deployReconciler: runtimePaths.makeDeployReconciler(),
            contextFactory: { ModelContext(container) },
            categoryReconciler: CategoryReconciler(platformVM: platformVM),
            intentReconciler: intentReconciler,
            auditLog: { SyncAudit(appSupport: appSupportDir).append(category: $0, detail: $1) },
            didConverge: { platformVM.noteDeployStateChanged() }
        )
    }

    func makeAgentDetection(fileService: FileServiceProtocol = FileService()) -> AgentDetectionServiceProtocol {
        guard runtimePaths.isProduction else { return NoAgentDetection() }
        return AgentDetectionService(probe: SystemEnvironmentProbe(fileService: fileService), homeDirectory: homeDirectory)
    }

    func makeMachineStateService(defaults: UserDefaults,
                                 fileService files: FileServiceProtocol = FileService()) -> MachineStateService {
        return MachineStateService(fileService: files, agentDetection: makeAgentDetection(fileService: files),
            defaults: defaults,
            deployState: { try DeployStateStore(fileService: files, appSupportDir: appSupportDir).read() },
            homeDirectory: homeDirectory)
    }

    func makeMachineObservability(defaults: UserDefaults) -> MachineObservabilityDependencies {
        MachineObservabilityDependencies(stateService: makeMachineStateService(defaults: defaults),
            identity: MachineIdentity(appSupportDir: appSupportDir), root: storeRoot, now: Date.init)
    }

    func makeStoreRebuildService(fileService: FileServiceProtocol = FileService()) -> StoreRebuildService {
        StoreRebuildService(fileService: fileService, manifestService: ManifestService(fileService: fileService))
    }

    func makeSyncEngine(fileService: FileServiceProtocol = FileService()) -> SyncEngine {
        SyncEngine(gitService: makeGitService(fileService: fileService),
            manifestService: ManifestService(fileService: fileService),
            storeRebuildService: makeStoreRebuildService(fileService: fileService),
            fileService: fileService, lockPath: syncLockPath)
    }

    func makeImportScanner(fileService: FileServiceProtocol = FileService()) -> ImportScanner {
        ImportScanner(fileService: fileService,
            claudeSkillsDir: deployPaths.userSkillsRoot(for: .claudeCode) ?? appSupportDir + "/claude-skills",
            grokSkillsDir: deployPaths.userSkillsRoot(for: .grok) ?? appSupportDir + "/grok-skills",
            cursorRulesDir: deployPaths.cursorUserRulesDirectory,
            codexSkillsDir: deployPaths.userSkillsRoot(for: .codex) ?? appSupportDir + "/codex-skills", storeRoot: storeRoot)
    }

    func makeImportViewModel(notifier: @escaping SyncStateNotifying,
                             echoRegistrar: @escaping SyncWriteEchoRegistering) -> ImportViewModel {
        let files = FileService()
        return ImportViewModel(fileService: files, scanner: makeImportScanner(fileService: files),
            skillStore: SkillStore(fileService: files, baseDir: skillsDir), manifestService: ManifestService(),
            manifestRoot: storeRoot, notifier: notifier, echoRegistrar: echoRegistrar)
    }

    @MainActor
    func makeSyncSetupModel(context: ModelContext) -> SyncSetupModel {
        SyncSetupModel(context: context, git: makeGitService(), credentials: makeCredentialStore(),
            root: storeRoot, lockPath: syncLockPath)
    }

    @MainActor
    func makeConflictResolutionModel(
        onResolutionStarted: @escaping () throws -> (SyncCycleResult) -> Void
    ) -> ConflictResolutionModel {
        ConflictResolutionModel(engine: makeSyncEngine(), git: makeGitService(), credentials: makeCredentialStore(),
            root: storeRoot, onResolutionStarted: onResolutionStarted)
    }
}
