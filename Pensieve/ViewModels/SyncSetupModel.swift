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

/// Connect-a-remote onboarding (PLAN-08 / 08.3). Parses + transport-classifies a remote with a strict
/// ALLOWLIST (https / ssh / scp-style only; `ext::` / `fd::` / a leading `-` / https-userinfo are all
/// REJECTED before any URL reaches `GitService` — a valid `ext::sh -c …` URL git EXECUTES), stores an
/// HTTPS PAT in the Keychain, decides init-vs-clone, and performs the first sync.
///
/// `@MainActor`: `connect` schedules the work asynchronously on the main actor so the SwiftData
/// `ModelContext` used by the clone→rebuild path stays on its actor. The network git currently runs on
/// the main actor too (it can block the UI on a slow network) — moving the network I/O to a background
/// context is a tracked refinement (Decision Log 08.3); we do NOT claim non-blocking here.
@MainActor
@Observable
final class SyncSetupModel {
    enum State: Equatable {
        case idle
        case working
        case done
        case failed(String)
    }

    private(set) var state: State = .idle

    private let git: GitServiceProtocol
    private let credentials: CredentialStoreProtocol
    private let rebuilder: StoreRebuildServiceProtocol
    private let fileService: FileServiceProtocol
    private let root: String
    private let lockPath: String
    private let context: ModelContext
    private let syncedFamiliesEmpty: () -> Bool?

    init(context: ModelContext,
         git: GitServiceProtocol = GitService(),
         credentials: CredentialStoreProtocol = KeychainCredentialStore(),
         rebuilder: StoreRebuildServiceProtocol = StoreRebuildService(),
         fileService: FileServiceProtocol = FileService(),
         root: String = Constants.pensieveBaseDir,
         lockPath: String = PathConstants.pensieveAppSupportDir + "/sync.lock",
         syncedFamiliesEmpty: (() -> Bool?)? = nil) {
        self.context = context
        self.git = git
        self.credentials = credentials
        self.rebuilder = rebuilder
        self.fileService = fileService
        self.root = root
        self.lockPath = lockPath
        self.syncedFamiliesEmpty = syncedFamiliesEmpty ?? {
            do {
                return try context.fetchCount(FetchDescriptor<Skill>()) == 0
                    && context.fetchCount(FetchDescriptor<Category>()) == 0
                    && context.fetchCount(FetchDescriptor<Scenario>()) == 0
                    && context.fetchCount(FetchDescriptor<Project>()) == 0
                    && context.fetchCount(FetchDescriptor<MachineDeployIntent>()) == 0
            } catch {
                return nil
            }
        }
    }

    // MARK: - Pure logic (unit-testable without git)

    /// Thin delegate to the single source of truth. The full admission policy (transport allowlist,
    /// remote-helper/userinfo/dash/newline rejection) lives in `RemoteURLPolicy` so the sync-time
    /// re-check in `SyncEngine` enforces the identical allowlist (C1). (PLAN-10 / 10.3)
    static func parseRemote(_ raw: String) -> RemoteSpec? { RemoteURLPolicy.parse(raw) }

    static func firstSyncPlan(hasGitDir: Bool, hasLocalSkills: Bool) -> FirstSyncPlan {
        if hasGitDir { return .alreadyConfigured }
        return hasLocalSkills ? .initAndPush : .cloneAndRebuild
    }

    static func isValidBranchName(_ name: String) -> Bool {
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

    static func defaultBranch(symref: String?, heads: [String]) -> String? {
        if let symref, isValidBranchName(symref) { return symref }
        if heads.contains("main") { return "main" }
        if heads.contains("master") { return "master" }
        return nil
    }

    // MARK: - Connect (the flow)

    /// Fire-and-forget entry the setup sheet calls. Schedules the work asynchronously on the main
    /// actor: `.working` renders first, then the git work runs (see the type doc for the caveat). The
    /// dispatch below is deliberately the file's ONLY such reference so the frozen 08.3-b grep-Verify
    /// self-gates (removing it makes the grep exit non-zero).
    func connect(url: String, username: String, token: String) {
        Task { await connectAndReport(url: url, username: username, token: token) }
    }

    /// Awaitable seam (tests await this; the sheet goes through `connect`).
    func connectAndReport(url: String, username: String, token: String) async {
        state = .working
        guard let spec = Self.parseRemote(url) else {
            state = .failed("That doesn't look like a git remote you can sync. Use an https:// URL or an "
                + "ssh remote (git@host:path).")
            return
        }
        do {
            let credential = try prepareCredential(spec: spec, username: username, token: token)
            try perform(spec: spec, credential: credential)
            state = .done
        } catch GitError.authenticationFailed {
            state = .failed(authMessage(for: spec.transport, host: spec.host))
        } catch let error as LocalizedError {
            state = .failed(error.errorDescription ?? "Couldn't connect to the remote.")
        } catch {
            state = .failed("Couldn't connect to the remote.")
        }
    }

    private func prepareCredential(spec: RemoteSpec, username: String, token: String) throws -> GitCredential {
        switch spec.transport {
        case .ssh:
            return .sshAgent
        case .https:
            let account = username.isEmpty ? "x-access-token" : username
            try credentials.store(token: token, username: account, forHost: spec.host)
            return credentials.credential(forHost: spec.host) ?? .httpsToken(username: account, token: token)
        }
    }

    // Internal so the disk-backed local-repository tests can exercise this exact locked orchestration
    // without weakening the production remote URL admission used by `connectAndReport`.
    func perform(spec: RemoteSpec, credential: GitCredential) throws {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        try requireReadableGit()
        let hasGitDir = fileService.directoryExists(at: root + "/.git")
        switch Self.firstSyncPlan(hasGitDir: hasGitDir, hasLocalSkills: localSkillsExist()) {
        case .alreadyConfigured:
            let hasLocalBranches = try git.hasLocalBranches(at: root)
            if hasLocalBranches {
                try git.setRemote(spec.url, at: root)
                if syncedFamiliesEmpty() == true {
                    try rebuildAndRequireReadable()
                }
                return
            }

            if isVirginScaffoldStore(toleratingGitDir: true) {
                let branch = try resolvedDefaultBranch(spec: spec, credential: credential)
                try adoptInPlace(spec: spec, credential: credential, defaultBranch: branch)
                return
            }

            guard syncedFamiliesEmpty() == true,
                  try git.remoteURL(at: root) == spec.url else {
                throw SyncSetupError.midAdoptionStoreUnrecognized
            }
            let branch = try resolvedDefaultBranch(spec: spec, credential: credential)
            guard git.hasRemoteTrackingBranch(branch, at: root) else {
                throw SyncSetupError.midAdoptionStoreUnrecognized
            }
            try adoptInPlace(spec: spec, credential: credential, defaultBranch: branch)
        case .initAndPush:
            try initAndPush(spec: spec, credential: credential)
        case .cloneAndRebuild:
            if isVirginScaffoldStore(toleratingGitDir: false) {
                let branch = try resolvedDefaultBranch(spec: spec, credential: credential)
                try adoptInPlace(spec: spec, credential: credential, defaultBranch: branch)
            } else {
                try git.clone(remote: spec.url, into: root, credential: credential)
                try rebuildAndRequireReadable()
            }
        }
    }

    private func requireReadableGit() throws {
        try git.probeUsability().requireUsable()
        if fileService.directoryExists(at: root) { _ = try git.remoteURL(at: root) }
    }

    /// Disconnect the store from its remote (Route B, 2026-09-12): forgets the HTTPS credential sync
    /// stored for the remote's literal host, then removes `origin`. Leaves the local repository, its
    /// history, every skill, the manifest, machine state, and the install token
    /// (`CredentialHost.githubInstall`, a different key) untouched. Refuses while a sync holds the
    /// lock. Idempotent: no origin, no-op. A broken repository throws rather than reading as
    /// "already disconnected". Credential first so no failure branch strands a token: a Keychain
    /// failure leaves the remote and token intact for a retry; a git failure after the credential
    /// is gone leaves a remote whose next cycle reports Sync failed; Disconnect… again finishes the
    /// job (the delete tolerates the missing item), and Connect… returns once the remote is gone.
    /// Synchronous and subprocess-backed — call it from an action, never `body`.
    func performDisconnect() throws {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        guard let literal = try git.configuredRemoteURL(at: root) else { return }
        if let spec = RemoteURLPolicy.parse(literal), spec.transport == .https {
            try credentials.delete(forHost: spec.host)   // the Keychain store treats a missing item as success
        }
        try git.removeRemote(at: root)
    }

}

private extension SyncSetupModel {
    func resolvedDefaultBranch(spec: RemoteSpec, credential: GitCredential) throws -> String {
        let symref = try git.remoteDefaultBranch(remote: spec.url, credential: credential)
        let heads = try git.remoteBranches(remote: spec.url, credential: credential)
        guard let branch = Self.defaultBranch(symref: symref, heads: heads) else {
            throw SyncSetupError.remoteDefaultBranchUndetermined
        }
        return branch
    }

    func adoptInPlace(spec: RemoteSpec, credential: GitCredential, defaultBranch: String) throws {
        try git.initRepository(at: root)
        try git.setRemote(spec.url, at: root)
        if defaultBranch != "main" {
            try git.checkoutUnbornBranch(defaultBranch, at: root)
        }
        try git.fetchBranch(defaultBranch, at: root, credential: credential)
        try git.materializeFromFetchHead(at: root)
        try git.bornBranch(defaultBranch, at: root)
        try rebuildAndRequireReadable()
        try git.setUpstream(branch: defaultBranch, at: root)
    }

    func rebuildAndRequireReadable() throws {
        let result = rebuilder.rebuild(fromRoot: root, context: context)
        if result.storeUnreadable { throw SyncError.storeUnreadable(result.warnings) }
    }

    func isVirginScaffoldStore(toleratingGitDir: Bool) -> Bool {
        let manifest = root + "/manifest"
        guard fileService.directoryExists(at: root),
              !fileService.isSymlink(at: root),
              fileService.directoryExists(at: manifest),
              !fileService.isSymlink(at: manifest),
              let rootEntries = try? fileService.listDirectory(at: root),
              entriesMatch(
                  rootEntries,
                  required: ["manifest"],
                  base: root,
                  toleratedGitDir: toleratingGitDir
              ),
              let manifestEntries = try? fileService.listDirectory(at: manifest),
              entriesMatch(
                  manifestEntries,
                  required: ["manifest.yaml", "projects.yaml", "categories", "scenarios", "skills", "deploys"],
                  base: manifest,
                  toleratedGitDir: false
              ) else { return false }

        let fileNames = ["manifest.yaml", "projects.yaml"]
        guard fileNames.allSatisfy({ name in
            let path = manifest + "/" + name
            return fileService.isRegularFile(at: path) && !fileService.isSymlink(at: path)
        }) else { return false }

        for name in ["categories", "scenarios", "skills", "deploys"] {
            let path = manifest + "/" + name
            guard fileService.directoryExists(at: path),
                  !fileService.isSymlink(at: path),
                  let entries = try? fileService.listDirectory(at: path),
                  entriesMatch(entries, required: [], base: path, toleratedGitDir: false) else {
                return false
            }
        }

        guard let schemaText = try? fileService.readFile(at: manifest + "/manifest.yaml"),
              schemaVersion(from: schemaText) == ManifestService.currentSchemaVersion,
              let projectsText = try? fileService.readFile(at: manifest + "/projects.yaml"),
              projectsText == ManifestService.serializeProjects([]),
              syncedFamiliesEmpty() == true else { return false }
        return true
    }

    func schemaVersion(from text: String) -> Int? {
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let prefix = "schema_version: "
        guard !line.contains("\n"), line.hasPrefix(prefix) else { return nil }
        let raw = line.dropFirst(prefix.count)
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return nil }
        return Int(raw)
    }

    func entriesMatch(
        _ entries: [String],
        required: Set<String>,
        base: String,
        toleratedGitDir: Bool
    ) -> Bool {
        var remaining = Set(entries)
        for name in required { remaining.remove(name) }
        guard required.isSubset(of: Set(entries)) else { return false }
        if remaining.remove(".DS_Store") != nil {
            let path = base + "/.DS_Store"
            guard fileService.isRegularFile(at: path), !fileService.isSymlink(at: path) else { return false }
        }
        if toleratedGitDir, remaining.remove(".git") != nil {
            let path = base + "/.git"
            guard fileService.directoryExists(at: path), !fileService.isSymlink(at: path) else { return false }
        }
        return remaining.isEmpty
    }

    func initAndPush(spec: RemoteSpec, credential: GitCredential) throws {
        try git.initRepository(at: root)
        try git.setRemote(spec.url, at: root)
        _ = try git.stageAllAndCommit(at: root, message: "Set up Pensieve sync")
        if git.remoteHasCommits(remote: spec.url, credential: credential) {
            if case let .conflicted(paths) = try git.pullRebase(at: root, credential: credential) {
                try git.abortRebase(at: root)   // if the abort itself fails, surface THAT, not a clean stop
                throw SyncSetupError.remoteDiverged(paths.count)
            }
        }
        try git.push(at: root, credential: credential)
    }

    func localSkillsExist() -> Bool {
        let skillsDir = root + "/skills"
        guard fileService.directoryExists(at: skillsDir),
              let entries = try? fileService.listDirectory(at: skillsDir) else { return false }
        return !entries.isEmpty
    }

    func authMessage(for transport: GitTransport, host: String) -> String {
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
