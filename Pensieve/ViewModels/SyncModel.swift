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
    }

    private(set) var state: SyncState
    private(set) var remoteURL: String?
    private var remoteReadError: String?
    var configurationError: String? {
        gitState?.usability?.message ?? remoteReadError
    }
    private var knownAbsent = false
    private var gitState: RuntimeGitState?
    private var configurationOrder = 0
    private var appliedConfigurationOrder = 0
    private(set) var lastSyncedAt: Date?
    private(set) var lastWarnings: [String] = []

    private let git: GitServiceProtocol
    private let root: String
    private var syncRequest: (() async -> Void)?
    private var pendingManualSyncRequest: (() -> Void)?
    private var pendingScheduledSyncRequest: (() -> Void)?
    private(set) var isCycleInFlight = false
    private var hasQueuedManualFollowUp = false
    private var hasQueuedScheduledFollowUp = false
    private var recoveredDuringCycle = false
    private var cycleProvedGitUsable = false

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
    var canResolve: Bool { isConflicted && canStartConflictResolution }
    var canStartConflictResolution: Bool { !isCycleInFlight }

    func installSyncRequest(_ request: @escaping () async -> Void) {
        syncRequest = request
    }

    func installPendingSyncRequest(_ request: @escaping () -> Void) {
        pendingManualSyncRequest = request
    }

    func installPendingScheduledSyncRequest(_ request: @escaping () -> Void) {
        pendingScheduledSyncRequest = request
    }

    /// Captures leaf collaborators for the runtime's off-main configuration read.
    func configurationRead() -> () -> Result<String?, Error> {
        let git = git
        let root = root
        return { Result { try git.remoteURL(at: root) } }
    }

    func observeGitState(_ state: RuntimeGitState) { gitState = state }

    func gitUsabilityDidChange(wasUnavailable: Bool) {
        updateConfigurationState(wasUnavailable: wasUnavailable)
    }

    func beginConfiguration() -> Int {
        configurationOrder += 1
        return configurationOrder
    }

    func applyConfiguration(_ remote: Result<String?, Error>, order: Int) {
        guard order > appliedConfigurationOrder else { return }
        appliedConfigurationOrder = order
        let wasUnavailable = configurationError != nil
        switch remote {
        case let .failure(error):
            knownAbsent = false
            remoteReadError = DisplayTextSanitizer.singleLine(error.localizedDescription)
        case let .success(url):
            knownAbsent = url == nil
            remoteURL = url
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
        } else if wasUnavailable || state == .unconfigured {
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

    func syncNowAndReport() async {
        await requestSync(isScheduled: false)
    }

    func syncScheduledAndReport() async {
        await requestSync(isScheduled: true)
    }

    func resumeAfterGitRecovery() {
        if isCycleInFlight {
            recoveredDuringCycle = true
        } else {
            pendingScheduledSyncRequest?()
        }
    }

    private func requestSync(isScheduled: Bool) async {
        guard !isCycleInFlight else {
            if isScheduled {
                hasQueuedScheduledFollowUp = true
            } else {
                hasQueuedManualFollowUp = true
            }
            return
        }
        guard canSyncNow else { return }
        guard let syncRequest else {
            (isScheduled ? pendingScheduledSyncRequest : pendingManualSyncRequest)?()
            return
        }
        isCycleInFlight = true
        recoveredDuringCycle = false
        cycleProvedGitUsable = false
        defer {
            if recoveredDuringCycle && !cycleProvedGitUsable { hasQueuedScheduledFollowUp = true }
            recoveredDuringCycle = false
            isCycleInFlight = false
            if hasQueuedManualFollowUp {
                hasQueuedManualFollowUp = false
                hasQueuedScheduledFollowUp = false
                if canSyncNow { pendingManualSyncRequest?() }
            } else if hasQueuedScheduledFollowUp {
                hasQueuedScheduledFollowUp = false
                if canSyncNow { pendingScheduledSyncRequest?() }
            }
        }
        state = .syncing
        await syncRequest()
    }

    func apply(_ result: SyncCycleResult) {
        if isCycleInFlight { cycleProvedGitUsable = result.provesGitUsable }
        defer {
            // Usability keeps its own clock, including when no configuration read follows.
            if let message = gitState?.usability?.message, state != .syncing, !isConflicted {
                state = .error(message)
            }
        }
        switch result {
        case let .synced(_, warnings, completedAt, _):
            lastSyncedAt = completedAt
            lastWarnings = warnings
            state = .synced(at: completedAt)
        case let .conflicted(paths):
            state = .conflicted(paths)
        case .noRemote:
            // Branchless stores also return noRemote. Only a configuration read answers whether origin is absent.
            state = configurationError.map { .error($0) }
                ?? (knownAbsent ? .unconfigured : lastSyncedAt.map { .synced(at: $0) } ?? .idle)
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
