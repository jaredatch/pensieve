import AppKit
import Foundation
import Observation
import SwiftUI

typealias SyncStateNotifying = () -> Void
typealias SyncWriteEchoRegistering = ([String]) -> Void

struct SyncBodyWriteRegistration {
    let begin: (_ directoryName: String, _ expectedBody: String) -> Void
    // succeeded=false means the bracketed replacement threw: the finalizer must not
    // adopt any fingerprint (the disk was not changed by the app; an old fingerprint
    // stays valid and a racing external edit stays classifiable).
    let end: (_ directoryName: String, _ succeeded: Bool) -> Void

    static let suppressed = SyncBodyWriteRegistration(begin: { _, _ in }, end: { _, _ in })
}

enum SyncStateNotifier {
    static let suppressed: SyncStateNotifying = {}
}

enum SyncWriteEchoRegistrar {
    static let suppressed: SyncWriteEchoRegistering = { _ in }
}

/// Preserves a later failure while reporting that a canonical synced-state write already completed.
struct SyncedStateMutationError: LocalizedError {
    let underlyingError: Error

    var errorDescription: String? {
        if let localized = underlyingError as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return underlyingError.localizedDescription
    }
}

/// Coalescing retains each request kind so refusing a recovery retry cannot discard ordinary work.
/// A recovery retry bypasses background-off like Sync Now, but cannot re-arm the user's spent retry.
struct SyncRequest: OptionSet {
    let rawValue: Int
    static let scheduled = SyncRequest(rawValue: 1 << 0)
    static let launchPreflight = SyncRequest(rawValue: 1 << 1)
    static let manualRecovery = SyncRequest(rawValue: 1 << 2)
    static let manual = SyncRequest(rawValue: 1 << 3)

    var isManual: Bool { contains(.manual) || contains(.manualRecovery) }
    var isPrivileged: Bool { isManual || contains(.launchPreflight) }
    func absorbing(_ other: SyncRequest) -> SyncRequest { union(other) }
}

/// Main-actor trigger coordinator. Triggers coalesce into one follow-up cycle; the pending request
/// retains its priority and preference bypass when that work is admitted.
@MainActor
@Observable
final class SyncScheduler {
    private(set) var hasPendingTrigger = true
    private(set) var isCoordinatorReady = false
    private(set) var isLaunchIngestReady = false
    private(set) var isSyncing = false
    private var pendingRequest: SyncRequest = .scheduled

    @ObservationIgnored @AppStorage("backgroundSyncEnabled")
    private var storedBackgroundSyncEnabled = true
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private let interval: TimeInterval
    private let debounceNanoseconds: UInt64
    private let backgroundSyncOverride: (() -> Bool)?
    private var syncAction: ((SyncRequest) async -> Void)?
    private var isConfigured: () -> Bool = { true }
    private var isGitUsable: () -> Bool = { true }
    private var isConflicted: () -> Bool = { false }

    init(
        interval: TimeInterval = 900,
        debounceSeconds: TimeInterval = 30,
        startAutomatically: Bool = true,
        backgroundSyncEnabled: (() -> Bool)? = nil
    ) {
        self.interval = interval
        self.debounceNanoseconds = UInt64(max(0, debounceSeconds) * 1_000_000_000)
        self.backgroundSyncOverride = backgroundSyncEnabled
        if startAutomatically {
            startScheduling()
        }
    }

    deinit {
        timer?.invalidate()
        debounceTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func installDrain(
        isConfigured: @escaping () -> Bool = { true },
        isGitUsable: @escaping () -> Bool = { true },
        isConflicted: @escaping () -> Bool = { false },
        action: @escaping (SyncRequest) async -> Void
    ) {
        self.isConfigured = isConfigured
        self.isGitUsable = isGitUsable
        self.isConflicted = isConflicted
        syncAction = action
        drainIfPossible()
    }

    func coordinatorBecameReady() {
        isCoordinatorReady = true
        drainIfPossible()
    }

    func launchIngestCompleted() {
        isLaunchIngestReady = true
        drainIfPossible()
    }

    func tick() {
        enqueueTrigger()
    }

    func wake() {
        enqueueTrigger()
    }

    func nudge() {
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        debounceTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            self?.fireDebouncedNudge()
        }
    }

    func drainPendingRequests() { drainIfPossible() }

    /// Cancel a nudge only after this scheduler's request starts a model cycle.
    func cycleDidStart() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    func enqueueTrigger() { enqueue(.scheduled) }
    func enqueueManualTrigger() { enqueue(.manual) }
    func enqueueLaunchPreflight() { enqueue(.launchPreflight) }

    func enqueue(_ request: SyncRequest) {
        pendingRequest = hasPendingTrigger ? pendingRequest.absorbing(request) : request
        hasPendingTrigger = true
        drainIfPossible()
    }

    private var backgroundSyncEnabled: Bool {
        backgroundSyncOverride?() ?? storedBackgroundSyncEnabled
    }

    private func startScheduling() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        }
    }

    private func drainIfPossible() {
        guard hasPendingTrigger,
              isCoordinatorReady,
              isLaunchIngestReady,
              !isSyncing,
              let syncAction else { return }
        guard backgroundSyncEnabled || pendingRequest.isPrivileged else { return }
        guard isConfigured(), !isConflicted() else {
            hasPendingTrigger = false
            pendingRequest = .scheduled
            return
        }
        // Host unavailability holds privileged requests; scheduled-only work is still dropped.
        guard isGitUsable() else {
            if !pendingRequest.isPrivileged { hasPendingTrigger = false }
            return
        }

        // Main-actor callbacks inherit UI priority. Background cycles retain the previous default QoS;
        // a queued Sync Now keeps its manual priority even when background triggers coalesce with it.
        let request = pendingRequest
        let priority: TaskPriority = request.isManual ? .userInitiated : .medium
        hasPendingTrigger = false
        pendingRequest = .scheduled
        isSyncing = true
        Task(priority: priority) { [weak self] in
            await syncAction(request)
            guard let self else { return }
            self.isSyncing = false
            self.drainIfPossible()
        }
    }

    private func fireDebouncedNudge() {
        debounceTask = nil
        enqueueTrigger()
    }
}
