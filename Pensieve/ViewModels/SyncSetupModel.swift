import Foundation
import SwiftData

/// Which first-sync path a connect must take, decided purely from local state (§C) — unit-testable
/// without touching git.
enum FirstSyncPlan: Equatable {
    case alreadyConfigured
    case initAndPush
    case cloneAndRebuild
}

/// A setup-time condition that is not a git command failure — surfaced as a `.failed` message.
enum SyncSetupError: LocalizedError, Equatable {
    case remoteDiverged(Int)
    case remoteDefaultBranchUndetermined
    case midAdoptionStoreUnrecognized

    var errorDescription: String? {
        switch self {
        case let .remoteDiverged(count):
            return "The remote already has \(count) diverging change(s). Open Sync to resolve them "
                + "before connecting."
        case .remoteDefaultBranchUndetermined:
            return "Couldn't determine a safe default branch for this remote."
        case .midAdoptionStoreUnrecognized:
            return "This store is in an unrecognized partial sync state. Nothing was changed. Back up "
                + "anything you added, remove ~/.pensieve, relaunch Pensieve, and reconnect."
        }
    }
}

/// Process-owned orchestration. Native jobs own their contexts and the whole-cycle sync lock.
@MainActor
@Observable
final class SyncSetupModel {
    enum State: Equatable {
        case idle
        case working
        case done
        case cancelled
        case failed(String)
    }
    enum Phase { case checking, writing }
    private(set) var state: State = .idle
    private(set) var connectionNotice: String?
    private(set) var phase: Phase = .checking
    private(set) var isDisconnecting = false
    var canCancel: Bool { state != .working || phase == .checking }
    private let container: ModelContainer
    private let git: GitServiceProtocol
    private let credentials: CredentialStoreProtocol
    private let rebuilder: StoreRebuildServiceProtocol
    private let fileService: FileServiceProtocol
    private let root: String
    private let lockPath: String
    private let syncedFamiliesEmpty: (() -> Bool?)?
    private let steps: SyncStepModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(context: ModelContext, git: GitServiceProtocol, credentials: CredentialStoreProtocol,
         rebuilder: StoreRebuildServiceProtocol = StoreRebuildService(),
         fileService: FileServiceProtocol = FileService(), root: String, lockPath: String,
         syncedFamiliesEmpty: (() -> Bool?)? = nil, steps: SyncStepModel) {
        container = context.container
        self.git = git
        self.credentials = credentials
        self.rebuilder = rebuilder
        self.fileService = fileService
        self.root = root
        self.lockPath = lockPath
        self.syncedFamiliesEmpty = syncedFamiliesEmpty
        self.steps = steps
    }

    // MARK: - Pure logic (unit-testable without git)

    /// Thin delegate to the single source of truth. The full admission policy (transport allowlist,
    /// remote-helper/userinfo/dash/newline rejection) lives in `RemoteURLPolicy` so the sync-time
    /// re-check in `SyncEngine` enforces the identical allowlist (C1). (PLAN-10 / 10.3)
    nonisolated static func parseRemote(_ raw: String) -> RemoteSpec? { RemoteURLPolicy.parse(raw) }

    nonisolated static func firstSyncPlan(hasGitDir: Bool, hasLocalSkills: Bool) -> FirstSyncPlan {
        if hasGitDir { return .alreadyConfigured }
        return hasLocalSkills ? .initAndPush : .cloneAndRebuild
    }

    nonisolated static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name.utf8.count <= 250,
              name != "@",
              let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              !name.contains(".."),
              !name.contains("@{"),
              !name.hasSuffix("."),
              !name.hasSuffix("/") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && !component.hasPrefix(".") && !component.hasSuffix(".lock")
        }
    }

    nonisolated static func defaultBranch(symref: String?, heads: [String]) -> String? {
        if let symref, isValidBranchName(symref) { return symref }
        if heads.contains("main") { return "main" }
        if heads.contains("master") { return "master" }
        return nil
    }

    func prepareForPresentation() {
        guard state != .working, !isDisconnecting else { return }
        state = .idle
        connectionNotice = nil
        phase = .checking
    }

    func connect(url: String, username: String, token: String) {
        guard state != .working, !isDisconnecting else { return }
        state = .working
        connectionNotice = nil
        phase = .checking
        task = Task { await runConnect(url: url, username: username, token: token) }
    }

    func connectAndReport(url: String, username: String, token: String) async {
        connect(url: url, username: username, token: token)
        await withTaskCancellationHandler { await task?.value } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        guard state == .working, phase == .checking else { return }
        task?.cancel()
    }

    private func runConnect(url: String, username: String, token: String) async {
        guard let spec = Self.parseRemote(url) else {
            state = .failed("That doesn't look like a git remote you can sync. Use an https:// URL or an "
                + "ssh remote (git@host:path).")
            return
        }
        guard spec.transport != .https || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("Sync over HTTPS needs an access token.")
            return
        }
        do {
            try await perform(spec: spec, credential: spec.transport == .ssh ? .sshAgent
                : .httpsToken(username: username.isEmpty ? "x-access-token" : username, token: token))
            state = .done
        } catch is CancellationError {
            state = .cancelled
        } catch GitError.authenticationFailed {
            state = .failed(authMessage(for: spec.transport, host: spec.host))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // The local-remote integration owner uses the same job without relaxing URL admission in the UI.
    func perform(spec: RemoteSpec, credential: GitCredential) async throws {
        let container = container, git = git, credentials = credentials, rebuilder = rebuilder
        let files = fileService, root = root, lockPath = lockPath, families = syncedFamiliesEmpty
        var step: UUID?
        defer { if let step { steps.finish(step) } }
        connectionNotice = try await BlockingWork.run {
            let job = SyncSetupJob(context: ModelContext(container), git: git, credentials: credentials,
                rebuilder: rebuilder, fileService: files, root: root, lockPath: lockPath,
                syncedFamiliesEmpty: families)
            return try job.perform(spec: spec, credential: credential) {
                // Acknowledge on the main actor before the first write. Cancel and Quit see the
                // same boundary; the native job keeps its context and lock throughout the handoff.
                try DispatchQueue.main.sync {
                    try MainActor.assumeIsolated {
                        if self.task?.isCancelled == true { throw CancellationError() }
                        self.phase = .writing
                        step = self.steps.begin()
                    }
                }
            }
        }
    }

    func performDisconnect() async throws {
        guard !isDisconnecting, state != .working else { return }
        isDisconnecting = true
        let step = steps.begin()
        defer { isDisconnecting = false; steps.finish(step) }
        let container = container, git = git, credentials = credentials, rebuilder = rebuilder
        let files = fileService, root = root, lockPath = lockPath
        try await BlockingWork.run {
            // Disconnect can write from its credential deletion onward. It always finishes.
            try GitCancellation.$isReadOnly.withValue(false) {
                try SyncSetupJob(context: ModelContext(container), git: git, credentials: credentials,
                    rebuilder: rebuilder, fileService: files, root: root, lockPath: lockPath)
                    .performDisconnect()
            }
        }
    }

    private func authMessage(for transport: GitTransport, host: String) -> String {
        switch transport {
        case .ssh:
            return "Couldn't authenticate to \(host) over SSH. Add your key to the agent "
                + "(run ssh-add in Terminal) and confirm it can reach the repo."
        case .https:
            return "Couldn't authenticate to \(host). Check the access token has repo access "
                + "and hasn't expired."
        }
    }
}
