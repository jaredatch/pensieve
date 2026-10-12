import Foundation

/// Process-owned token checking survives a Settings rebuild. Git runs only on the native worker.
@MainActor
@Observable
final class SyncTokenModel {
    enum State: Equatable { case idle, checking, saved, cancelled, failed(String) }
    var token = ""
    private(set) var remote: RemoteSpec?
    private(set) var hasSavedToken = false
    private(set) var state: State = .idle
    private(set) var isSaving = false
    var canSave: Bool {
        remote != nil && state != .checking && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canCancel: Bool { !isSaving }

    private let git: GitServiceProtocol
    private let credentials: CredentialStoreProtocol
    private let root: String
    private let lockPath: String
    private let steps: SyncStepModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var latestRemoteURL: String?

    init(git: GitServiceProtocol, credentials: CredentialStoreProtocol,
         root: String, lockPath: String, steps: SyncStepModel) {
        self.git = git
        self.credentials = credentials
        self.root = root
        self.lockPath = lockPath
        self.steps = steps
    }

    func refresh(remoteURL: String?) {
        latestRemoteURL = remoteURL
        guard state != .checking else { return }
        let next = remoteURL.flatMap(RemoteURLPolicy.parse).flatMap { $0.transport == .https ? $0 : nil }
        if remote != next { token = "" }
        remote = next
        hasSavedToken = remote.map { SyncAuthentication.hasToken(credentials.credential(forHost: $0.host)) } ?? false
    }

    func prepareForPresentation() {
        guard state != .checking else { return }
        token = ""
        state = .idle
    }

    func save() {
        guard canSave, let remote else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .checking
        task = Task { await checkAndSave(remote: remote, token: token) }
    }

    func cancel() {
        guard canCancel else { return }
        task?.cancel()
        token = ""
    }

    private func checkAndSave(remote: RemoteSpec, token: String) async {
        let git = git, credentials = credentials, root = root, lockPath = lockPath
        var step: UUID?
        defer {
            if let step { steps.finish(step) }
            isSaving = false
            task = nil
            refresh(remoteURL: latestRemoteURL)
        }
        do {
            try await BlockingWork.run {
                // Wait off-main for an active cycle, then keep Disconnect from changing the target.
                let lock = try SyncLock.waitForSave(at: lockPath)
                defer { lock.release() }
                try GitCancellation.$isReadOnly.withValue(true) {
                    try Task.checkCancellation()
                    guard try git.remoteURL(at: root) == remote.url else {
                        throw TargetChanged()
                    }
                    let username: String
                    if case let .httpsToken(savedUsername, _) = credentials.credential(forHost: remote.host) {
                        username = savedUsername
                    } else { username = "x-access-token" }
                    _ = try git.remoteReferences(remote: remote.url, credential: .httpsToken(username: username, token: token))
                    try Task.checkCancellation()
                    try DispatchQueue.main.sync {
                        try MainActor.assumeIsolated {
                            guard self.task?.isCancelled != true else { throw CancellationError() }
                            self.isSaving = true
                            step = self.steps.begin()
                        }
                    }
                    try credentials.store(token: token, username: username, forHost: remote.host)
                }
            }
            self.token = ""
            hasSavedToken = true
            state = .saved
        } catch is CancellationError {
            state = .cancelled
        } catch GitError.authenticationFailed {
            state = .failed("\(remote.host) didn’t accept this token. Your saved token hasn’t changed.")
        } catch is TargetChanged {
            state = .failed("The sync repository changed. Close this sheet and try again.")
        } catch let error as CredentialError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed("Couldn’t reach \(remote.host). Your saved token hasn’t changed.")
        }
    }

    private struct TargetChanged: Error {}
}
