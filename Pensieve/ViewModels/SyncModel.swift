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

    private(set) var state: SyncState
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
    private var failedManualNeedsRecovery = false

    /// The skill slugs currently in conflict, for row/detail badges. Strips `skills/<slug>/SKILL.md` and
    /// `manifest/skills/<slug>.yaml` to `<slug>`; category/project manifest paths are not skills.
    var conflictedSlugs: Set<String> {
        guard case let .conflicted(paths) = state else { return [] }
        var slugs = Set<String>()
        for path in paths {
            if path.hasPrefix("skills/"), path.hasSuffix("/SKILL.md") {
                slugs.insert(String(path.dropFirst("skills/".count).dropLast("/SKILL.md".count)))
            } else if path.hasPrefix("manifest/skills/"), path.hasSuffix(".yaml") {
                slugs.insert(String(path.dropFirst("manifest/skills/".count).dropLast(".yaml".count)))
            }
        }
        return slugs
    }

    init(git: GitServiceProtocol = GitService(),
         root: String = Constants.pensieveBaseDir,
         initialState: SyncState = .idle) {
        self.git = git
        self.root = root
        self.state = initialState
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

    var canSyncNow: Bool { isConfigured && !knownBranchless && !isConflicted && !isCycleInFlight }
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

    func gitUsabilityDidChange(wasUnavailable: Bool) {
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
            remoteReadError = DisplayTextSanitizer.singleLine(error.localizedDescription)
        case let .success(configuration):
            knownAbsent = configuration.remoteURL == nil
            knownBranchless = !knownAbsent && !configuration.hasLocalBranches
            remoteURL = configuration.remoteURL
            remoteReadError = nil
        }
        updateConfigurationState(wasUnavailable: wasUnavailable)
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
            let request: SyncRequest = failedManualNeedsRecovery ? .manualRecovery : .scheduled
            failedManualNeedsRecovery = false
            if canScheduleSync { pendingSyncRequest?(request) }
        }
    }

    func syncAndReport(_ request: SyncRequest) async {
        guard !isCycleInFlight else {
            queuedRequest = queuedRequest.map { $0.absorbing(request) } ?? request
            return
        }
        guard canSyncNow else { return }
        guard let syncRequest else { pendingSyncRequest?(request); return }
        isCycleInFlight = true
        recoveredDuringCycle = false
        cycleFailed = false
        failedManualNeedsRecovery = false
        defer { finishCycle(request) }
        state = .syncing
        await syncRequest()
    }

    private func finishCycle(_ request: SyncRequest) {
        failedManualNeedsRecovery = request == .manual && cycleFailed
        if recoveredDuringCycle {
            let catchUp: SyncRequest = request == .manual && cycleFailed ? .manualRecovery : .scheduled
            queuedRequest = queuedRequest.map { $0.absorbing(catchUp) } ?? catchUp
            failedManualNeedsRecovery = false
        }
        recoveredDuringCycle = false
        isCycleInFlight = false
        let followUp = queuedRequest
        queuedRequest = nil
        if let followUp, canSyncNow { pendingSyncRequest?(followUp) }
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
    }

}
