import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppRuntime {
    typealias LaunchReconcile = (ModelContext, Bool) -> LaunchReconcileOutcome
    typealias LaunchBackfill = (ModelContext) -> Void
    typealias CoordinatorConfigure = (SyncCoordinator) async -> Void
    typealias UpdateCheckOperation = (ModelContainer) throws -> RuntimeUpdateCheckResult

    static let migrationDefaultsKey = "didRunStoreMigration"
    static let backgroundSyncEnabledKey = "backgroundSyncEnabled"

    let container: ModelContainer
    let platformVM: PlatformViewModel
    let library: SkillLibraryViewModel
    let syncModel: SyncModel
    let scheduler: SyncScheduler
    let provenanceVM: SkillProvenanceViewModel
    let updatesViewModelOperations: UpdatesViewModel.DefaultOperations
    let reconcileIntent: @MainActor (ModelContext) -> BatchResult

    private(set) var coordinator: SyncCoordinator?
    private(set) var launchWorkInvocationCount = 0
    private(set) var storeQuarantined = false
    private(set) var updateCheckInFlight = false
    private(set) var updateCheckError: String?
    private(set) var updateCheckAlertError: String?
    private var automaticUpdateRetryDeferred = false
    private let gitState: RuntimeGitState

    private let defaults: UserDefaults
    private let launchReconcile: LaunchReconcile
    private let launchBackfill: LaunchBackfill
    private let hasRemoteConfigured: () -> Bool
    private let convergence: PostSyncConverging
    private let coordinatorConfigure: CoordinatorConfigure
    private let updateCheckApply: (([UUID: SkillUpdateCheckResult]) throws -> Void)?
    private let updateCheckOperation: UpdateCheckOperation
    private let now: () -> Date
    private let launchIngestRetryNanoseconds: UInt64
    private let launchIngestLockPath: String
    /// Where the store and App Support live; every collaborator built here is pointed at them (`AppRuntime+Paths.swift`).
    private let paths: AppRuntimePaths
    private var didPerformLaunchWork = false
    private var didCompleteLaunchIngest = false
    private var didSignalLaunchIngest = false
    private var launchIngestHeadStamp: String?
    private var needsLaunchBackfillAfterCoordinator = false
    private var forceLaunchPreflight = false
    @ObservationIgnored private var launchIngestRetryTask: Task<Void, Never>?
    @ObservationIgnored private var openMainWindowAction: (() -> Void)?
    @ObservationIgnored private(set) lazy var upstreamHistory = paths.makeUpstreamHistoryViewModel()

    @ObservationIgnored
    private(set) lazy var bootstrapTask: Task<Void, Never> = {
        let container = container
        let configure = coordinatorConfigure
        let paths = paths
        return Task.detached { [weak self] in
            await self?.refreshGitUsability()
            let coordinator = SyncCoordinator(modelContainer: container)
            await paths.configureCoordinator(coordinator)
            await configure(coordinator)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.coordinator = coordinator
                self.syncModel.installSyncRequest { [weak self] in
                    guard let self else { return }
                    self.library.beginCoordinatorChanges()
                    let evidence = self.gitState.beginEvidence()
                    let result = await Task.detached { await coordinator.runCycle() }.value
                    let sampledWatcherEventSequence = self.library.coordinatorWatcherEventSequence
                    let hasUnsyncedChanges = await Task.detached {
                        !paths.isWorktreeClean()
                    }.value
                    self.library.finishCoordinatorChanges(
                        hasUnsyncedChanges: hasUnsyncedChanges,
                        sampledWatcherEventSequence: sampledWatcherEventSequence,
                        recheckHasUnsyncedChanges: {
                            !paths.isWorktreeClean()
                        }
                    )
                    if result.provesGitUsable {
                        self.handleGitChange(self.gitState.accept(.usable, order: evidence, model: self.syncModel))
                    }
                    let publishesAfterRead = switch result {
                    case .failed, .storeUnreadable, .conflicted: true
                    default: false
                    }
                    if !publishesAfterRead { self.syncModel.apply(result) }
                    await self.refreshGitConfiguration(probingGit: !result.provesGitUsable)
                    if publishesAfterRead { self.syncModel.apply(result) }
                    self.library.applySyncCycleOutcome(result)
                    if case .synced = result { self.performDeferredLaunchBackfillIfNeeded() }
                    self.convergence.run(after: result)
                }
                self.scheduler.coordinatorBecameReady()
                self.signalLaunchIngestIfPossible()
            }
        }
    }()

    init(
        container: ModelContainer? = nil,
        platformVM: PlatformViewModel? = nil,
        library: SkillLibraryViewModel? = nil,
        syncModel: SyncModel? = nil,
        scheduler: SyncScheduler? = nil,
        defaults: UserDefaults? = nil,
        hostName: () -> String? = MachineDisplayName.currentHostName,
        launchReconcile: LaunchReconcile? = nil,
        launchBackfill: LaunchBackfill? = nil,
        hasRemoteConfigured: (() -> Bool)? = nil,
        postSyncConvergence: PostSyncConverging? = nil,
        launchIngestRetryNanoseconds: UInt64 = 1_000_000_000,
        launchIngestLockPath: String? = nil,
        paths: AppRuntimePaths = .production,
        provenanceVM: SkillProvenanceViewModel? = nil,
        updateCheckOperation: UpdateCheckOperation? = nil,
        updateCheckApply: (([UUID: SkillUpdateCheckResult]) throws -> Void)? = nil,
        now: @escaping () -> Date = Date.init,
        gitUsabilityProbe: @escaping () -> GitUsability = { GitService().probeUsability() },
        // The paths configure the coordinator first (`bootstrapTask`); this hook runs after, so a test
        // can swap in stubs. A bare `configure()` here would reset the paths to production.
        coordinatorConfigure: @escaping CoordinatorConfigure = { _ in }
    ) throws {
        let resolvedDefaults = try defaults ?? paths.makeDefaults()
        let resolvedScheduler = scheduler ?? AppRuntimePaths.makeScheduler(defaults: resolvedDefaults)
        let notifier: SyncStateNotifying = { [weak resolvedScheduler] in
            resolvedScheduler?.nudge()
        }
        let resolvedSyncModel = syncModel ?? SyncModel(root: paths.storeRoot)
        let resolvedContainer = try container ?? paths.makeContainer()
        let resolvedPlatformVM = platformVM ?? paths.makePlatformViewModel()
        let resolvedProvenanceVM = provenanceVM ?? paths.makeSkillProvenanceViewModel()
        let resolvedIntentReconciler = IntentReconciler(
            platformVM: resolvedPlatformVM,
            machineIdentity: MachineIdentity(appSupportDir: paths.appSupportDir),
            handoverIsComplete: { resolvedDefaults.bool(forKey: ScenarioHandover.doneKey) }
        )
        let resolvedConvergence = postSyncConvergence ?? paths.makeConvergence(
            container: resolvedContainer,
            platformVM: resolvedPlatformVM,
            intentReconciler: resolvedIntentReconciler
        )
        self.container = resolvedContainer
        self.platformVM = resolvedPlatformVM
        self.library = library ?? paths.makeLibrary(notifier: notifier)
        self.syncModel = resolvedSyncModel
        self.scheduler = resolvedScheduler
        self.provenanceVM = resolvedProvenanceVM
        self.updatesViewModelOperations = paths.makeUpdatesViewModelOperations()
        self.reconcileIntent = { context in
            resolvedIntentReconciler.reconcile(context: context)
        }
        MachineDisplayName.seedIfNeeded(defaults: resolvedDefaults, hostName: hostName)
        self.defaults = resolvedDefaults
        self.paths = paths
        self.launchReconcile = launchReconcile ?? paths.makeLaunchReconcile(
            defaults: resolvedDefaults, platformVM: resolvedPlatformVM, notifier: notifier)
        self.launchBackfill = Self.backfillRefreshingIndex(
            launchBackfill ?? paths.makeLaunchBackfill(), platformVM: resolvedPlatformVM
        )
        self.hasRemoteConfigured = hasRemoteConfigured ?? { paths.hasRemoteConfigured() }
        self.convergence = resolvedConvergence
        self.launchIngestRetryNanoseconds = launchIngestRetryNanoseconds
        self.launchIngestLockPath = launchIngestLockPath ?? paths.syncLockPath
        self.coordinatorConfigure = coordinatorConfigure
        self.updateCheckOperation = updateCheckOperation ?? paths.makeUpdateCheckOperation()
        self.updateCheckApply = updateCheckApply
        self.now = now
        self.gitState = RuntimeGitState(probe: gitUsabilityProbe)
        resolvedSyncModel.observeGitState(gitState)

        installRuntimeCallbacks()

        _ = bootstrapTask
    }

    var gitUsability: GitUsability? { gitState.usability }
    func refreshGitUsability() async { await refreshGitConfiguration(probingGit: true) }

    var syncLockPath: String { paths.syncLockPath }

    var backgroundSyncEnabled: Bool {
        get { defaults.object(forKey: Self.backgroundSyncEnabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.backgroundSyncEnabledKey)
            scheduler.backgroundPreferenceChanged()
        }
    }

    func registerOpenMainWindowAction(_ action: @escaping () -> Void) { openMainWindowAction = action }

    func openMainWindow() { openMainWindowAction?() }

    var lastUpdateCheckStartedAt: Date? {
        let timestamp = defaults.double(forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    func checkForSkillUpdatesNow() { startUpdateCheck(showsFailureAlert: true) }

    func checkForSkillUpdatesFromSettings() { startUpdateCheck(showsFailureAlert: false) }

    func checkForSkillUpdatesIfDue() {
        guard !automaticUpdateRetryDeferred else { return }
        let rawFrequency = defaults.string(forKey: UpdateCheckSchedule.frequencyKey)
            ?? UpdateCheckFrequency.weekly.rawValue
        let frequency = UpdateCheckFrequency(rawValue: rawFrequency) ?? .weekly
        let checkedAt = now()
        guard UpdateCheckSchedule.isDue(
            frequency: frequency,
            lastAutoCheckAt: lastUpdateCheckStartedAt,
            now: checkedAt
        ) else { return }
        startUpdateCheck(at: checkedAt, showsFailureAlert: true, automatic: true)
    }

    func clearUpdateCheckAlert() { updateCheckAlertError = nil }

    /// Runs process-lifetime launch work at most once. The callback keeps the existing auto-update check
    /// between deploy-state backfill and watcher startup while the view retains its presentation state.
    @discardableResult
    func performLaunchWorkIfNeeded(
        context: ModelContext,
        beforeStartingWatcher: () -> Void = {}
    ) -> Bool {
        guard !didPerformLaunchWork else { return false }
        didPerformLaunchWork = true
        launchWorkInvocationCount += 1

        let alreadyMigrated = defaults.bool(forKey: Self.migrationDefaultsKey)
        guard let lock = SyncLock.tryAcquire(at: launchIngestLockPath) else {
            let pendingOutcome = LaunchReconcileOutcome(
                rebuild: RebuildResult(),
                migrationRan: false,
                ingestionNeedsRetry: true,
                quarantined: true
            )
            acceptLaunchIngest(pendingOutcome, context: context)
            beforeStartingWatcher()
            library.startWatching()
            scheduleLaunchIngestRetry(context: context)
            return true
        }
        let launchOutcome = launchReconcile(context, alreadyMigrated)
        if launchOutcome.migrationRan {
            defaults.set(true, forKey: Self.migrationDefaultsKey)
        }
        acceptLaunchIngest(launchOutcome, context: context)
        lock.release()
        beforeStartingWatcher()
        library.startWatching()
        if launchOutcome.ingestionNeedsRetry {
            scheduleLaunchIngestRetry(context: context)
        }
        return true
    }
}

private extension AppRuntime {
    private func acceptLaunchIngest(_ outcome: LaunchReconcileOutcome, context: ModelContext) {
        storeQuarantined = outcome.quarantined
        library.setStoreUnreadable(outcome.rebuild.storeUnreadable)
        if !outcome.rebuild.storeUnreadable, !outcome.ingestionNeedsRetry {
            // Quarantine and an unknown remote both defer backfill until a successful sync ingests the store.
            if outcome.quarantined {
                needsLaunchBackfillAfterCoordinator = true
                forceLaunchPreflight = true
            } else if outcome.ingestedHeadStamp != nil || !hasRemoteConfigured() {
                launchBackfill(context)
                convergence.runAfterLaunchIngest()
            } else {
                needsLaunchBackfillAfterCoordinator = true
                forceLaunchPreflight = true
            }
        }
        launchIngestHeadStamp = outcome.ingestedHeadStamp
        didCompleteLaunchIngest = outcome.rebuild.storeUnreadable
            || !outcome.ingestionNeedsRetry
        signalLaunchIngestIfPossible()
        library.refreshQuarantine(context: context)
    }

    private func scheduleLaunchIngestRetry(context: ModelContext) {
        guard launchIngestRetryTask == nil else { return }
        launchIngestRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.launchIngestRetryNanoseconds ?? 0)
                guard let self else { return }
                guard let lock = SyncLock.tryAcquire(at: self.launchIngestLockPath) else { continue }
                let alreadyMigrated = self.defaults.bool(forKey: Self.migrationDefaultsKey)
                let outcome = self.launchReconcile(context, alreadyMigrated)
                if outcome.migrationRan {
                    self.defaults.set(true, forKey: Self.migrationDefaultsKey)
                }
                if outcome.rebuild.storeUnreadable || !outcome.ingestionNeedsRetry {
                    self.launchIngestRetryTask = nil
                    self.acceptLaunchIngest(outcome, context: context)
                    lock.release()
                    return
                }
                lock.release()
            }
        }
    }

    private func signalLaunchIngestIfPossible() {
        guard didCompleteLaunchIngest,
              !didSignalLaunchIngest,
              let coordinator else { return }
        didSignalLaunchIngest = true
        let stamp = launchIngestHeadStamp
        Task { [weak self] in
            await coordinator.seedLastIngestedHeadStamp(stamp)
            guard let self else { return }
            if self.forceLaunchPreflight {
                self.forceLaunchPreflight = false
                self.scheduler.enqueueManualTrigger()
            }
            self.scheduler.launchIngestCompleted()
        }
    }
}

extension AppRuntime {
    private func performDeferredLaunchBackfillIfNeeded() {
        guard needsLaunchBackfillAfterCoordinator else { return }
        launchBackfill(ModelContext(container))
        needsLaunchBackfillAfterCoordinator = false
    }

    /// The model excludes cycles until conflict resolution finishes. Git evidence remains ordered.
    func beginConflictResolution() throws -> (SyncCycleResult) -> Void {
        guard syncModel.canStartConflictResolution else { throw SyncError.syncInProgress }
        let evidence = gitState.beginEvidence()
        return { [weak self] result in
            guard let self else { return }
            let change = result.provesGitUsable ? gitState.accept(.usable, order: evidence, model: syncModel) : nil
            syncModel.apply(result)
            handleGitChange(change)
            library.applySyncCycleOutcome(result)
            performDeferredLaunchBackfillIfNeeded()
            convergence.run(after: result)
        }
    }

    func refreshGitConfiguration(probingGit: Bool) async {
        handleGitChange(await gitState.refresh(probingGit: probingGit, model: syncModel))
    }

    private func handleGitChange(_ change: RuntimeGitState.Change?) {
        guard let change, change.recovered else { return }
        let retry = automaticUpdateRetryDeferred
        automaticUpdateRetryDeferred = false
        if retry { checkForSkillUpdatesIfDue() }
        syncModel.resumeAfterGitRecovery()
    }

    private func startUpdateCheck(at checkedAt: Date? = nil, showsFailureAlert: Bool, automatic: Bool = false) {
        guard !updateCheckInFlight else { return }
        if !automatic { automaticUpdateRetryDeferred = false }
        let evidence = gitState.beginEvidence()
        let startedAt = checkedAt ?? now()
        updateCheckInFlight = true
        updateCheckError = nil
        if showsFailureAlert { updateCheckAlertError = nil }

        let container = container
        let operation = updateCheckOperation
        Task { [weak self] in
            guard let self else { return }
            let completed = await executeUpdateCheck(operation, container: container,
                classifyFailure: gitState.failureClassifier(), apply: updateCheckApply)
            if let usability = completed.report?.gitUsability,
               let change = gitState.accept(usability, order: evidence, model: syncModel) {
                handleGitChange(change)
                if usability == .usable { await refreshGitConfiguration(probingGit: false) }
            }
            if completed.countsAsRun {
                defaults.set(startedAt.timeIntervalSince1970, forKey: UpdateCheckSchedule.lastAutoCheckAtKey)
            }
            if automatic || completed.defersAutomaticRetry { automaticUpdateRetryDeferred = completed.defersAutomaticRetry }
            if let error = completed.error {
                recordUpdateCheckFailure(error, showsAlert: showsFailureAlert)
            }
            updateCheckInFlight = false
        }
    }

    private func recordUpdateCheckFailure(_ error: Error, showsAlert: Bool) {
        let message = DisplayTextSanitizer.singleLine(SkillProvenanceViewModel.readable(error))
        updateCheckError = message
        if showsAlert { updateCheckAlertError = message }
    }
}
