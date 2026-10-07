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

/// Main-actor trigger coordinator. Triggers coalesce into one follow-up cycle; pending manual and
/// launch-preflight flags retain the priority and preference bypass needed when that work is admitted.
@MainActor
@Observable
final class SyncScheduler {
    private(set) var hasPendingTrigger = true
    private(set) var isCoordinatorReady = false
    private(set) var isLaunchIngestReady = false
    private(set) var isSyncing = false
    private var hasPendingManualTrigger = false
    private var hasPendingLaunchPreflight = false

    @ObservationIgnored @AppStorage("backgroundSyncEnabled")
    private var storedBackgroundSyncEnabled = true
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private let interval: TimeInterval
    private let debounceNanoseconds: UInt64
    private let backgroundSyncOverride: (() -> Bool)?
    private var syncAction: (() async -> Void)?
    private var hasRemote: () -> Bool = { true }
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
        hasRemote: @escaping () -> Bool = { true },
        isConflicted: @escaping () -> Bool = { false },
        action: @escaping () async -> Void
    ) {
        self.hasRemote = hasRemote
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

    func backgroundPreferenceChanged() {
        drainIfPossible()
    }

    func enqueueTrigger() {
        hasPendingTrigger = true
        drainIfPossible()
    }

    func enqueueManualTrigger() {
        hasPendingTrigger = true
        hasPendingManualTrigger = true
        drainIfPossible()
    }

    func enqueueLaunchPreflight() {
        hasPendingTrigger = true
        hasPendingLaunchPreflight = true
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
        guard backgroundSyncEnabled || hasPendingManualTrigger || hasPendingLaunchPreflight else { return }
        guard hasRemote(), !isConflicted() else {
            hasPendingTrigger = false
            hasPendingManualTrigger = false
            hasPendingLaunchPreflight = false
            return
        }

        // A cycle that starts after a nudge was received already covers that mutation. This matters when
        // a tick/wake queued the follow-up while the 30-second debounce was still sleeping: without the
        // cancellation, the delayed nudge would launch a redundant third cycle.
        debounceTask?.cancel()
        debounceTask = nil
        // Main-actor callbacks inherit UI priority. Background cycles retain the previous default QoS;
        // a queued Sync Now keeps its manual priority even when background triggers coalesce with it.
        let priority: TaskPriority = hasPendingManualTrigger ? .userInitiated : .medium
        hasPendingTrigger = false
        hasPendingManualTrigger = false
        hasPendingLaunchPreflight = false
        isSyncing = true
        Task(priority: priority) { [weak self] in
            await syncAction()
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
