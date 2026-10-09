import Foundation
import SwiftData

/// Live sync state for the chrome status control. Sync execution is delegated to the runtime-owned
/// `SyncCoordinator`; this main-actor model only maps value-typed cycle results into presentation state.
@MainActor
@Observable
final class SyncModel {
    enum SyncState: Equatable {
        case idle
        case syncing
        case synced(at: Date)
        case conflicted([String])
        case error(String)
        case unconfigured
        case branchless
    }

    private(set) var state: SyncState {
        didSet { if oldValue != state { conflictedSlugs = Self.slugs(for: state) } }
    }
    private(set) var remoteURL: String?
    private var remoteReadError: String?
    var configurationError: String? {
        gitState?.usability?.message ?? remoteReadError
    }
    struct Configuration {
        let remoteURL: String?
        let hasLocalBranches: Bool
    }

    private var knownAbsent = false
    private var knownBranchless = false
    private var gitState: RuntimeGitState?
    private var configurationOrder = 0
    private var appliedConfigurationOrder = 0
    private(set) var lastSyncedAt: Date?
    private(set) var lastWarnings: [String] = []

    private let git: GitServiceProtocol
    private let root: String
    private var syncRequest: (() async -> Void)?
    private var pendingSyncRequest: ((SyncRequest) -> Void)?
    private(set) var isCycleInFlight = false
    private var queuedRequest: SyncRequest?
    private var recoveredDuringCycle = false
    private var cycleFailed = false
    private enum ManualRetry { case awaitingOutage, inOutage, ready, queued }
    private var manualRetry: ManualRetry?

    /// The skill slugs currently in conflict, for row/detail badges. Strips `skills/<slug>/SKILL.md` and
    /// `manifest/skills/<slug>.yaml` to `<slug>`; category/project manifest paths are not skills.
    private(set) var conflictedSlugs: Set<String>

    private static func slugs(for state: SyncState) -> Set<String> {
        guard case let .conflicted(paths) = state else { return [] }
        return Set(paths.compactMap { SyncEngine.conflictPath(for: $0).skillSlug })
    }

    init(git: GitServiceProtocol,
         root: String,
         initialState: SyncState = .idle) {
        self.git = git
        self.root = root
        self.state = initialState
        self.conflictedSlugs = Self.slugs(for: initialState)
        self.knownBranchless = initialState == .branchless
    }

    /// Body-safe: derives from observed configuration, never from a live git read.
    /// The runtime supplies ordered answers from its off-main refresh.
    /// Reading git here ran `git remote get-url` inside `ContentView.body`; evaluated during the connect
    /// sheet's dismiss animation, `waitUntilExit`'s nested run loop re-entered the in-flight render pass
    /// and crashed (live-gate FAIL, 2026-08-19).
    var configurationDescription: String {
        configurationError ?? remoteURL ?? (knownAbsent ? "Not connected" : "Checking repository…")
    }
    var canConnect: Bool { knownAbsent && configurationError == nil }

    var isConfigured: Bool {
        state != .unconfigured
    }

    var isConflicted: Bool {
        if case .conflicted = state { return true }
        return false
    }

    var canSyncNow: Bool { isConfigured && !isConflicted && !isCycleInFlight }
    /// Recovery catch-ups refuse known branchlessness; ordinary requests can discover an external branch.
    var canScheduleSync: Bool { isConfigured && !knownBranchless && !isConflicted }
    var canResolve: Bool { isConflicted && canStartConflictResolution }
    var canStartConflictResolution: Bool { !isCycleInFlight }

    func installSyncRequest(_ request: @escaping () async -> Void) {
        syncRequest = request
    }

    func installPendingSyncRequest(_ request: @escaping (SyncRequest) -> Void) {
        pendingSyncRequest = request
    }

    /// Captures leaf collaborators for the runtime's off-main configuration read.
    func configurationRead() -> () -> Result<Configuration, Error> {
        let git = git
        let root = root
        return { Result {
            let remote = try git.remoteURL(at: root)
            let hasBranches = remote == nil ? true : try git.hasLocalBranches(at: root)
            return Configuration(remoteURL: remote, hasLocalBranches: hasBranches)
        } }
    }

    func observeGitState(_ state: RuntimeGitState) { gitState = state }

    func gitUsabilityDidChange(wasUnavailable: Bool, recovered: Bool) {
        if gitState?.usability == .usable {
            manualRetry = recovered && manualRetry == .inOutage ? .ready : nil
        } else if manualRetry == .awaitingOutage {
            manualRetry = .inOutage
        } else if manualRetry == .ready || manualRetry == .queued {
            manualRetry = nil
        }
        updateConfigurationState(wasUnavailable: wasUnavailable)
    }

    func beginConfiguration() -> Int {
        configurationOrder += 1
        return configurationOrder
    }

    func applyConfiguration(_ remote: Result<Configuration, Error>, order: Int) {
        guard order > appliedConfigurationOrder else { return }
        appliedConfigurationOrder = order
        let wasUnavailable = configurationError != nil
        switch remote {
        case let .failure(error):
            knownAbsent = false
            knownBranchless = false
            remoteReadError = DisplayTextSanitizer.singleLine(error.localizedDescription)
        case let .success(configuration):
            knownAbsent = configuration.remoteURL == nil
            knownBranchless = !knownAbsent && !configuration.hasLocalBranches
            remoteURL = configuration.remoteURL
            remoteReadError = nil
        }
        updateConfigurationState(wasUnavailable: wasUnavailable)
        enqueueManualRetryIfPossible()
    }

    private func updateConfigurationState(wasUnavailable: Bool) {
        guard state != .syncing, !isConflicted else { return }
        if let configurationError {
            state = .error(configurationError)
        } else if knownAbsent {
            state = .unconfigured
        } else if knownBranchless {
            state = .branchless
        } else if wasUnavailable || state == .unconfigured || state == .branchless {
            state = lastSyncedAt.map { .synced(at: $0) } ?? .idle
        }
    }

    func syncNow(context: ModelContext) {
        Task { await syncNowAndReport(context: context) }
    }

    func syncNow() {
        Task { await syncNowAndReport() }
    }

    /// Awaitable seam (tests await this; the control goes through `syncNow`).
    func syncNowAndReport(context: ModelContext) async {
        await syncNowAndReport()
    }

    func syncNowAndReport() async { await syncAndReport(.manual) }

    func syncScheduledAndReport() async { await syncAndReport(.scheduled) }

    func resumeAfterGitRecovery() {
        if isCycleInFlight {
            recoveredDuringCycle = true
        } else {
            if manualRetry != nil {
                enqueueManualRetryIfPossible()
            } else if canScheduleSync {
                pendingSyncRequest?(.scheduled)
            }
        }
    }

    func syncAndReport(_ request: SyncRequest, onCycleStart: (() -> Void)? = nil) async {
        guard !redispatchIfRecoveryIsRefused(request) else { return }
        guard !isCycleInFlight else {
            queuedRequest = queuedRequest.map { $0.absorbing(request) } ?? request
            return
        }
        guard canSyncNow else { return }
        guard let syncRequest else { pendingSyncRequest?(request); return }
        isCycleInFlight = true
        recoveredDuringCycle = false
        cycleFailed = false
        manualRetry = nil
        defer { finishCycle(request) }
        state = .syncing
        onCycleStart?()
        await syncRequest()
    }

    private func finishCycle(_ request: SyncRequest) {
        if request.contains(.manual) && cycleFailed {
            manualRetry = recoveredDuringCycle ? .ready
                : gitState?.usability?.message != nil ? .inOutage : .awaitingOutage
        }
        if recoveredDuringCycle && canScheduleSync {
            let catchUp: SyncRequest = manualRetry == .ready ? .manualRecovery : .scheduled
            queuedRequest = queuedRequest.map { $0.absorbing(catchUp) } ?? catchUp
        }
        recoveredDuringCycle = false
        isCycleInFlight = false
        let followUp = queuedRequest
        queuedRequest = nil
        if let followUp, canSyncNow {
            if followUp.contains(.manualRecovery) { manualRetry = .queued }
            pendingSyncRequest?(followUp)
        }
    }

    func apply(_ result: SyncCycleResult) {
        if isCycleInFlight {
            if case .failed = result { cycleFailed = true }
        }
        defer {
            // Usability keeps its own clock, including when no configuration read follows.
            if let message = gitState?.usability?.message, state != .syncing, !isConflicted {
                state = .error(message)
            }
        }
        switch result {
        case let .synced(_, warnings, completedAt, _):
            knownBranchless = false
            lastSyncedAt = completedAt
            lastWarnings = warnings
            state = .synced(at: completedAt)
        case let .conflicted(paths):
            state = .conflicted(paths)
        case .noRemote:
            // Only a configuration read answers whether origin is absent.
            state = configurationError.map { .error($0) }
                ?? (knownAbsent ? .unconfigured : lastSyncedAt.map { .synced(at: $0) } ?? .idle)
        case .branchless:
            knownBranchless = true
            state = .branchless
        case .locked:
            state = configurationError.map { .error($0) } ?? lastSyncedAt.map { .synced(at: $0) } ?? .idle
        case let .failed(message):
            state = .error(DisplayTextSanitizer.singleLine(message))
        case let .storeUnreadable(message):
            state = .error(DisplayTextSanitizer.singleLine(message))
        }
    }

    /// Clear a just-resolved conflict. The resolution flow (rebase --continue + push) has already landed
    /// local == remote, so the honest post-resolve state is "synced just now"; without this the
    /// `.conflicted` badges and the "Resolve…"-only status action stick until app restart (the sheet
    /// resolves through a separate model and configuration updates preserve `.conflicted`). No-op if not
    /// conflicted, so a concurrent transition is never clobbered.
    func clearConflict() {
        guard case .conflicted = state else { return }
        let now = Date()
        lastSyncedAt = now
        state = configurationError.map { .error($0) } ?? .synced(at: now)
        enqueueManualRetryIfPossible()
    }

}

private extension SyncModel {
    func redispatchIfRecoveryIsRefused(_ request: SyncRequest) -> Bool {
        guard request.contains(.manualRecovery) else { return false }
        let retryAvailable = manualRetry == .ready || manualRetry == .queued
        guard retryAvailable && canScheduleSync else {
            if retryAvailable { manualRetry = .ready }
            let remaining = request.subtracting(.manualRecovery)
            // Redispatch applies the surviving request's own preference and priority rules.
            if !remaining.isEmpty { pendingSyncRequest?(remaining) }
            return true
        }
        return false
    }

    func enqueueManualRetryIfPossible() {
        guard manualRetry == .ready, !isCycleInFlight, canScheduleSync,
              gitState?.usability == .usable, let pendingSyncRequest else { return }
        manualRetry = .queued
        pendingSyncRequest(.manualRecovery)
    }
}
