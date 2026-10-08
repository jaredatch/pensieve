import Foundation

enum StoreUpdateError: LocalizedError, Equatable {
    case excludedLocalFile(path: String)

    var errorDescription: String? {
        switch self {
        case let .excludedLocalFile(path):
            return "Sync paused so it won't overwrite \(path) on this Mac. Another Mac already synced a file there. "
                + "Move or rename this one, then sync again."
        }
    }
}

extension GitService {
    /// Narrow overrides retain identity, URL rewrites, credentials and unrelated configuration.
    static let storeConfigurationArgs = [
        "-c", "core.excludesFile=/dev/null", "-c", "core.attributesFile=/dev/null",
        "-c", "core.autocrlf=false", "-c", "core.eol=lf"
    ]

    func storeOperation(at root: String) throws -> StoreGitOperation {
        try StoreGitOperation(git: self, root: root)
    }

    /// Only a store with protected local additions needs the app's pre-snapshot fetch. Return the
    /// checked commit so the later pull cannot fetch a different tree after the snapshot is written.
    func preflightStoreUpdate(at path: String, credential: GitCredential?) throws -> String? {
        let store = try storeOperation(at: path)
        let excluded = try store.excludedUntrackedPaths()
        guard !excluded.isEmpty else { return nil }
        let revision = try fetchStoreRevision(at: path, credential: credential)
        try store.requireNoExcludedCollision(with: revision, localPaths: excluded)
        return revision
    }

    func fetchStoreRevision(at path: String, credential: GitCredential?) throws -> String {
        try fetch(at: path, credential: credential)
        return try runOrThrow(["-C", path, "rev-parse", "--verify", "FETCH_HEAD^{commit}"], in: nil)
            .stdout.trimmingCharacters(in: .newlines)
    }

    /// `git -C <path> fetch origin main`. Advances FETCH_HEAD and (opportunistically) the `origin/main`
    /// remote-tracking ref without touching HEAD or the worktree. Throws `.authenticationFailed` on an
    /// auth error, `.commandFailed` on any other non-zero exit.
    func fetch(at path: String, credential: GitCredential?) throws {
        let args = ["-C", path, "fetch", "origin", "main"]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        let combined = r.stdout + r.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: authenticationRemoteLabel(at: path), detail: combined)
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    static func cleanupCloneTemps(fileService: FileServiceProtocol = FileService(),
                                  storeRoot: String, lockPath: String, externallyHeldLock: Bool = false) {
        let lock = externallyHeldLock ? nil : SyncLock.tryAcquire(at: lockPath)
        guard externallyHeldLock || lock != nil else { return }
        defer { lock?.release() }
        let parent = (storeRoot as NSString).deletingLastPathComponent
        let prefix = ".pensieve-clone-"
        guard !fileService.isSymlink(at: parent), fileService.directoryExists(at: parent),
              let entries = try? fileService.listDirectory(at: parent) else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            guard UUID(uuidString: String(entry.dropFirst(prefix.count))) != nil else { continue }
            let path = parent + "/" + entry
            if fileService.directoryExists(at: path) || fileService.isSymlink(at: path) {
                try? fileService.deleteDirectory(at: path)
            } else if fileService.fileExists(at: path) {
                try? fileService.deleteFile(at: path)
            }
        }
    }

    func requireEmptyCloneDestination(at path: String) throws {
        guard let type = try fileService.entryTypeWithoutFollowingLinks(at: path) else { return }
        guard type == .directory, try fileService.listDirectory(at: path).isEmpty else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY), userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "The store destination '\(path)' already exists and is not an empty directory."
            ])
        }
    }
}

/// One context per worktree operation installs the store's attributes and resolves shared metadata
/// once. Every command through it carries the store overrides. Abort alone tolerates repair failure.
struct StoreGitOperation {
    let git: GitService
    let root: String
    private let infoDirectory: String
    let repairFailure: Error?

    init(git: GitService, root: String, aborting: Bool = false) throws {
        self.git = git
        self.root = root
        var resolved = ""
        var failure: Error?
        do {
            let result = try git.runOrThrow(
                ["-C", root, "rev-parse", "--path-format=absolute", "--git-path", "info"], in: nil)
            let info = result.stdout.trimmingCharacters(in: .newlines)
            guard info.utf8.first == 0x2F else {
                throw GitError.repositoryUnreadable(path: root, detail: "git returned no metadata path.")
            }
            resolved = info
            let attributes = "* -text -eol -ident -filter -working-tree-encoding\nskills/** !merge\n"
            let path = info + "/attributes"
            if (try? git.fileService.readFile(at: path)) != attributes {
                try git.fileService.writeFile(at: path, content: attributes)
            }
        } catch {
            guard aborting else { throw error }
            failure = error
        }
        infoDirectory = resolved
        repairFailure = failure
    }

    @discardableResult
    func run(_ args: [String], credential: GitCredential? = nil) throws -> GitService.GitOutput {
        try git.run(["-C", root] + args, in: nil, credential: credential, storeRules: true)
    }

    @discardableResult
    func runOrThrow(_ args: [String]) throws -> GitService.GitOutput {
        try git.runOrThrow(["-C", root] + args, in: nil, storeRules: true)
    }

    func runData(_ args: [String]) throws -> GitService.GitDataOutput {
        try git.runData(["-C", root] + args, in: nil, storeRules: true)
    }

    func commitStagedChanges(message: String) throws -> Bool {
        let args = ["diff", "--cached", "--quiet"]
        let staged = try run(args)
        if staged.exit == 0 { return false }
        guard staged.exit == 1 else {
            throw GitError.commandFailed(args: ["-C", root] + args, exitCode: staged.exit,
                stderr: staged.stderr.isEmpty ? staged.stdout : staged.stderr, confirmingProbe: staged.confirmingProbe)
        }
        try runOrThrow(["commit", "-m", message])
        return true
    }

    func unstagedSkillPaths() throws -> Data {
        try untrackedPaths("skills")
    }

    private func untrackedPaths(_ path: String) throws -> Data {
        var args = ["--literal-pathspecs", "ls-files", "--others", "-z"]
        for path in [root + "/.gitignore", infoDirectory + "/exclude"]
            where git.fileService.fileExists(at: path) {
            args.append("--exclude-from=" + path)
        }
        args += ["--", path]
        return try untrackedFiles(args)
    }

    func ordinaryUntrackedPaths() throws -> Data {
        try untrackedFiles(["ls-files", "--others", "--exclude-standard", "-z"])
    }

    /// Git reports an untracked nested repository as a slash-terminated entry rather than its files.
    /// Already indexed directories keep their ordinary files even after gaining their own .git.
    private func untrackedFiles(_ args: [String]) throws -> Data {
        var args = args
        // Prune dependency trees during git's walk; the byte filter also protects both enumerations
        // from lower-priority ignore rules that re-include excluded names.
        args.insert("--exclude=node_modules/", at: args.firstIndex(of: "--") ?? args.endIndex)
        let result = try runData(args)
        guard result.exit == 0 else { throw git.dataCommandError(result, args: ["-C", root] + args) }
        var files = Data()
        for path in result.stdout.split(separator: 0) where path.last != 0x2F && !isExcludedUntrackedFile(path) {
            files.append(contentsOf: path)
            files.append(0)
        }
        return files
    }

    /// Only new files are excluded. Native tracked updates never remove or suppress legacy files.
    /// Compare path bytes so names that are not UTF-8 retain their usual staging behavior.
    private func isExcludedUntrackedFile(_ path: Data.SubSequence) -> Bool {
        let components = path.split(separator: 0x2F)
        guard let name = components.last else { return false }
        return name.elementsEqual(".env".utf8) || name.starts(with: ".env.".utf8)
            || name.elementsEqual(".DS_Store".utf8)
            || components.dropLast().contains { $0.elementsEqual("node_modules".utf8) }
    }

    /// Git lists even skill-ignored protected files, without treating the skill's other ignores as
    /// exclusions. Tracked legacy files never enter this inventory. Keep paths as bytes for matching.
    func excludedUntrackedPaths() throws -> [Data] {
        let args = ["ls-files", "--others", "--ignored", "-z", "--exclude=.env", "--exclude=.env.*",
                    "--exclude=.DS_Store", "--exclude=node_modules/"]
        let result = try runData(args)
        guard result.exit == 0 else { throw git.dataCommandError(result, args: ["-C", root] + args) }
        return result.stdout.split(separator: 0).filter {
            isExcludedUntrackedFile($0) && ($0.last != 0x2F || $0.split(separator: 0x2F).contains {
                $0.elementsEqual("node_modules".utf8)
            })
        }.map { Data($0.last == 0x2F ? $0.dropLast() : $0) }
    }

    /// Refuse both exact paths and file/directory replacements that would remove protected children.
    /// Native inventories avoid following links or opening secret bytes; no extra filesystem walk.
    func requireNoExcludedCollision(with revision: String, localPaths: [Data]? = nil) throws {
        let local = try localPaths ?? excludedUntrackedPaths()
        guard !local.isEmpty else { return }
        let args = ["ls-tree", "-r", "--name-only", "-z", revision]
        let incoming = try runData(args)
        guard incoming.exit == 0 else { throw git.dataCommandError(incoming, args: ["-C", root] + args) }
        let localSet = Set(local)
        var containingPaths: [Data: Data] = [:]
        for path in local {
            for prefix in pathPrefixes(path) where containingPaths[prefix] == nil {
                containingPaths[prefix] = path
            }
        }
        for path in incoming.stdout.split(separator: UInt8(0)).map({ Data($0) }) {
            let collision = containingPaths[path] ?? pathPrefixes(path).first { localSet.contains($0) }
            if let collision {
                let path = String(bytes: collision, encoding: .utf8)
                    ?? collision.map { String(format: "%%%02X", $0) }.joined()
                throw StoreUpdateError.excludedLocalFile(path: path)
            }
        }
    }

    private func pathPrefixes(_ path: Data) -> [Data] {
        var prefix = Data()
        return path.split(separator: 0x2F).map { component in
            if !prefix.isEmpty { prefix.append(0x2F) }
            prefix.append(contentsOf: component)
            return prefix
        }
    }

    /// Update tracked paths natively before enumerating new files, so stale children beneath a
    /// replacement symlink are removed. Git's enumeration omits new nested repositories; no extra
    /// filesystem walk or index removal is needed. Force-stage skill files hidden by skill ignores.
    func stage() throws {
        try runOrThrow(["--literal-pathspecs", "add", "--update"])
        try stage(ordinaryUntrackedPaths())
        try stage(unstagedSkillPaths())
    }

    func stagePath(_ path: String) throws {
        let args = ["--literal-pathspecs", "ls-files", "--cached", "-z", "--", path]
        let cached = try runData(args)
        guard cached.exit == 0 else { throw git.dataCommandError(cached, args: ["-C", root] + args) }
        if !cached.stdout.isEmpty {
            try runOrThrow(["--literal-pathspecs", "add", "--update", "--", path])
        }
        try stage(untrackedPaths(path))
    }

    private func stage(_ paths: Data) throws {
        guard !paths.isEmpty else { return }
        let pathspec = infoDirectory + "/pensieve-stage-" + UUID().uuidString
        try git.fileService.writeData(at: pathspec, data: paths)
        defer { try? git.fileService.deleteFile(at: pathspec) }
        try runOrThrow(["--literal-pathspecs", "add", "--force", "--all",
                        "--pathspec-from-file=" + pathspec, "--pathspec-file-nul"])
    }
}
