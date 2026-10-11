import Foundation
import SwiftData

/// Synchronous setup transaction. Construct and use on one native job; its context never escapes.
struct SyncSetupJob {
    let context: ModelContext
    let git: GitServiceProtocol
    let credentials: CredentialStoreProtocol
    let rebuilder: StoreRebuildServiceProtocol
    let fileService: FileServiceProtocol
    let root: String
    let lockPath: String
    var syncedFamiliesEmptyOverride: (() -> Bool?)?

    init(context: ModelContext, git: GitServiceProtocol, credentials: CredentialStoreProtocol,
         rebuilder: StoreRebuildServiceProtocol, fileService: FileServiceProtocol, root: String,
         lockPath: String, syncedFamiliesEmpty: (() -> Bool?)? = nil) {
        self.context = context
        self.git = git
        self.credentials = credentials
        self.rebuilder = rebuilder
        self.fileService = fileService
        self.root = root
        self.lockPath = lockPath
        syncedFamiliesEmptyOverride = syncedFamiliesEmpty
    }

    private func syncedFamiliesEmpty() -> Bool? {
        if let syncedFamiliesEmptyOverride { return syncedFamiliesEmptyOverride() }
        do {
            return try context.fetchCount(FetchDescriptor<Skill>()) == 0
                && context.fetchCount(FetchDescriptor<Category>()) == 0
                && context.fetchCount(FetchDescriptor<Project>()) == 0
                && context.fetchCount(FetchDescriptor<MachineDeployIntent>()) == 0
        } catch { return nil }
    }

    func perform(spec: RemoteSpec, credential: GitCredential, beginWriting: () throws -> Void) throws -> String? {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        // Checking never writes to the store, remote or Keychain. Only these git calls opt in.
        let action = try GitCancellation.$isReadOnly.withValue(true) {
            try Task.checkCancellation()
            try requireReadableGit()
            return try checkedAction(spec: spec, credential: credential)
        }
        try Task.checkCancellation()
        try beginWriting()
        // From the first Keychain/store write onward, task cancellation cannot interrupt git.
        try GitCancellation.$isReadOnly.withValue(false) {
            if case let .httpsToken(username, token) = credential {
                try credentials.store(token: token, username: username, forHost: spec.host)
            }
            try action.run()
        }
        return action.notice
    }

    private struct CheckedAction {
        let notice: String?
        let run: () throws -> Void
    }

    private func checkedAction(spec: RemoteSpec, credential: GitCredential) throws -> CheckedAction {
        let hasGitDir = fileService.directoryExists(at: root + "/.git")
        switch SyncSetupModel.firstSyncPlan(hasGitDir: hasGitDir, hasLocalSkills: localSkillsExist()) {
        case .alreadyConfigured:
            let hasLocalBranches = try git.hasLocalBranches(at: root)
            if hasLocalBranches {
                let rebuild = syncedFamiliesEmpty() == true
                return CheckedAction(notice: nil) {
                    try self.git.setRemote(spec.url, at: self.root)
                    if rebuild { try self.rebuildAndRequireReadable() }
                }
            }

            if isVirginScaffoldStore(toleratingGitDir: true) {
                let branch = try resolvedDefaultBranch(spec: spec, credential: credential)
                return CheckedAction(notice: branch.notice) {
                    try self.adoptInPlace(spec: spec, credential: credential, defaultBranch: branch.name)
                }
            }

            guard syncedFamiliesEmpty() == true,
                  try git.remoteURL(at: root) == spec.url else {
                throw SyncSetupError.midAdoptionStoreUnrecognized
            }
            let branch = try resolvedDefaultBranch(spec: spec, credential: credential)
            let hasTrackingBranch = git.hasRemoteTrackingBranch(branch.name, at: root)
            // This legacy Boolean query maps git failures to false. Preserve cancellation first.
            try Task.checkCancellation()
            guard hasTrackingBranch else {
                throw SyncSetupError.midAdoptionStoreUnrecognized
            }
            return CheckedAction(notice: branch.notice) {
                try self.adoptInPlace(spec: spec, credential: credential, defaultBranch: branch.name)
            }
        case .initAndPush:
            _ = try git.remoteReferences(remote: spec.url, credential: credential)
            return CheckedAction(notice: nil) { try self.initAndPush(spec: spec, credential: credential) }
        case .cloneAndRebuild:
            if isVirginScaffoldStore(toleratingGitDir: false) {
                let branch = try resolvedDefaultBranch(spec: spec, credential: credential)
                return CheckedAction(notice: branch.notice) {
                    try self.adoptInPlace(spec: spec, credential: credential, defaultBranch: branch.name)
                }
            } else {
                _ = try git.remoteReferences(remote: spec.url, credential: credential)
                return CheckedAction(notice: nil) {
                    try self.git.clone(remote: spec.url, into: self.root, credential: credential)
                    try self.rebuildAndRequireReadable()
                }
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
    /// Runs inside the native Disconnect job.
    func performDisconnect() throws {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else { throw SyncError.syncInProgress }
        defer { lock.release() }
        guard let literal = try git.configuredRemoteURL(at: root) else { return }
        if let spec = RemoteURLPolicy.parse(literal), spec.transport == .https {
            try credentials.delete(forHost: spec.host)   // the Keychain store treats a missing item as success
        }
        try git.removeRemote(at: root)
    }

    private struct ResolvedBranch {
        let name: String
        let notice: String?
    }

    private func resolvedDefaultBranch(spec: RemoteSpec, credential: GitCredential) throws -> ResolvedBranch {
        let refs = try git.remoteReferences(remote: spec.url, credential: credential)
        guard let branch = SyncSetupModel.defaultBranch(symref: refs.defaultBranch, heads: refs.heads) else {
            throw SyncSetupError.remoteDefaultBranchUndetermined
        }
        let notice: String?
        if refs.defaultBranch != branch {
            notice = "Connected using branch “\(branch)” because Pensieve couldn't use the remote's default branch."
        } else {
            notice = nil
        }
        return ResolvedBranch(name: branch, notice: notice)
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
                  manifestEntries.filter { $0 != "scenarios" },
                  required: ["manifest.yaml", "projects.yaml", "categories", "skills", "deploys"],
                  base: manifest,
                  toleratedGitDir: false
              ) else { return false }

        let fileNames = ["manifest.yaml", "projects.yaml"]
        guard fileNames.allSatisfy({ name in
            let path = manifest + "/" + name
            return fileService.isRegularFile(at: path) && !fileService.isSymlink(at: path)
        }) else { return false }

        // Older builds scaffolded an empty legacy folder. Admit it only under the same empty-directory checks.
        for name in ["categories", "skills", "deploys"] + manifestEntries.filter({ $0 == "scenarios" }) {
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

}
