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
    @ObservationIgnored private var checkID: UUID?
    @ObservationIgnored var onSaved: (() -> Void)?

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
        let id = UUID()
        checkID = id
        task = Task { await checkAndSave(remote: remote, token: token, id: id) }
    }

    func cancel() {
        guard canCancel else { return }
        task?.cancel()
        token = ""
        if state == .checking {
            checkID = nil
            task = nil
            state = .cancelled
            refresh(remoteURL: latestRemoteURL)
        }
    }

    private func checkAndSave(remote: RemoteSpec, token: String, id: UUID) async {
        let git = git, credentials = credentials, root = root, lockPath = lockPath
        var step: UUID?
        defer {
            if let step { steps.finish(step) }
            if checkID == id {
                isSaving = false
                task = nil
                checkID = nil
                refresh(remoteURL: latestRemoteURL)
            }
        }
        do {
            try await BlockingWork.run {
                // Wait off-main for an active cycle, then keep Disconnect from changing the target.
                let lock = try SyncLock.waitForSave(at: lockPath, cancellable: true)
                defer { lock.release() }
                try GitCancellation.$isReadOnly.withValue(true) {
                    try Task.checkCancellation()
                    guard try git.remoteURL(at: root) == remote.url else {
                        throw TargetChanged()
                    }
                    let username: String
                    if case let .httpsToken(savedUsername, _, _) = credentials.credential(forHost: remote.host) {
                        username = savedUsername
                    } else { username = "x-access-token" }
                    _ = try git.remoteReferences(remote: remote.url,
                        credential: .httpsToken(username: username, token: token, host: remote.host))
                    try Task.checkCancellation()
                    try DispatchQueue.main.sync {
                        try MainActor.assumeIsolated {
                            guard self.checkID == id, self.task?.isCancelled != true else { throw CancellationError() }
                            self.isSaving = true
                            step = self.steps.begin()
                        }
                    }
                    try credentials.store(token: token, username: username, forHost: remote.host)
                }
            }
            guard checkID == id else { return }
            self.token = ""
            hasSavedToken = true
            state = .saved
            onSaved?()
        } catch {
            guard checkID == id else { return }
            state = failureState(error, remote: remote)
        }
    }

    private func failureState(_ error: Error, remote: RemoteSpec) -> State {
        switch error {
        case is CancellationError:
            return .cancelled
        case GitError.authenticationFailed:
            return .failed("\(remote.host) didn’t accept this token. Your saved token hasn’t changed.")
        case is TargetChanged:
            return .failed("The sync repository changed. Close this sheet and try again.")
        case let error as GitError where error.isRepositoryNotFound:
            return .failed("This token can’t open the sync repository on \(remote.host). Your saved token hasn’t changed.")
        case let error as GitError where error.isNetworkFailure:
            return .failed("Couldn’t reach \(remote.host). Your saved token hasn’t changed.")
        default:
            return .failed(error.localizedDescription)
        }
    }

    private struct TargetChanged: Error {}
}
