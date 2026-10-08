import Foundation

extension GitService {
    /// Narrow overrides retain identity, URL rewrites, credentials and unrelated configuration.
    static let storeConfigurationArgs = [
        "-c", "core.excludesFile=/dev/null", "-c", "core.attributesFile=/dev/null",
        "-c", "core.autocrlf=false", "-c", "core.eol=lf"
    ]

    func storeOperation(at root: String) throws -> StoreGitOperation {
        try StoreGitOperation(git: self, root: root)
    }

    static func cleanupCloneTemps(fileService: FileServiceProtocol = FileService(),
                                  storeRoot: String, lockPath: String) {
        guard let lock = SyncLock.tryAcquire(at: lockPath) else { return }
        defer { lock.release() }
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
        var args = ["ls-files", "--others", "-z"]
        for path in [root + "/.gitignore", infoDirectory + "/exclude"]
            where git.fileService.fileExists(at: path) {
            args.append("--exclude-from=" + path)
        }
        args += ["--", "skills"]
        let result = try runData(args)
        guard result.exit == 0 else { throw git.dataCommandError(result, args: ["-C", root] + args) }
        return result.stdout
    }

    /// Nested repositories stay local: exclude their whole tree instead of creating orphan gitlinks.
    /// Root/info excludes still apply; other skill files are force-staged using literal NUL pathspecs.
    func stage() throws {
        let nested = try nestedRepositories(in: "skills")
        let args = ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let ordinary = try runData(args)
        guard ordinary.exit == 0 else { throw git.dataCommandError(ordinary, args: ["-C", root] + args) }
        try stage(ordinary.stdout, excluding: nested)
        if !nested.isEmpty {
            try runOrThrow(["--literal-pathspecs", "rm", "-r", "--cached", "--force", "--ignore-unmatch", "--"] + nested)
        }
        try stage(unstagedSkillPaths(), excluding: nested)
    }

    func stagePath(_ path: String) throws {
        let nested = try nestedRepositories(in: "skills")
        if let repository = nested.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            try runOrThrow(["--literal-pathspecs", "rm", "-r", "--cached", "--force", "--ignore-unmatch", "--", repository])
        } else {
            try runOrThrow(["--literal-pathspecs", "add", "--force", "--", path])
        }
    }

    private func stage(_ paths: Data, excluding nested: [String]) throws {
        let paths = paths.split(separator: 0).filter { bytes in
            guard let path = String(bytes: bytes, encoding: .utf8) else { return true }
            return !nested.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard !paths.isEmpty else { return }
        var data = Data()
        for path in paths { data.append(contentsOf: path); data.append(0) }
        let pathspec = infoDirectory + "/pensieve-stage-" + UUID().uuidString
        try git.fileService.writeData(at: pathspec, data: data)
        defer { try? git.fileService.deleteFile(at: pathspec) }
        try runOrThrow(["--literal-pathspecs", "add", "--force", "--all",
                        "--pathspec-from-file=" + pathspec, "--pathspec-file-nul"])
    }

    private func nestedRepositories(in relative: String) throws -> [String] {
        let files = git.fileService
        let directory = root + "/" + relative
        guard !files.isSymlink(at: directory), files.directoryExists(at: directory) else { return [] }
        if files.directoryExists(at: directory + "/.git") || files.fileExists(at: directory + "/.git") {
            return [relative]
        }
        return try files.listDirectory(at: directory).flatMap { entry in
            try nestedRepositories(in: relative + "/" + entry)
        }
    }
}
