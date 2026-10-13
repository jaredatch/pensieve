import Foundation

// PLAN-24 keeps the ten tightly-coupled adoption subprocess members beside the existing git runner.
// swiftlint:disable file_length

/// HTTPS credentials carry their saved host. The helper answers only HTTPS prompts for that host.
/// Blank tokens are treated as absent.
enum GitCredential: Equatable {
    case sshAgent
    case httpsToken(username: String, token: String, host: String)
}

enum GitError: LocalizedError, Equatable {
    case commandFailed(args: [String], exitCode: Int32, stderr: String, confirmingProbe: GitUsability? = nil)
    case authenticationFailed(remote: String, detail: String)
    case unusable(GitUsability)
    case repositoryUnreadable(path: String, detail: String)
    case outputReadFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case let .unusable(usability):
            return usability.message
        case let .repositoryUnreadable(path, detail):
            return "Couldn’t read the store’s git repository at \(path): \(detail)"
        case let .outputReadFailed(detail):
            return "Pensieve couldn’t read git’s output: \(detail)"
        case let .commandFailed(args, exitCode, stderr, _):
            return "git \(args.joined(separator: " ")) failed (exit \(exitCode)): \(stderr)"
        case let .authenticationFailed(remote, detail):
            return "Authentication to \(remote) failed: \(detail)"
        }
    }
}

extension GitError {
    var isRepositoryNotFound: Bool {
        guard case let .commandFailed(_, _, stderr, _) = self else { return false }
        let detail = stderr.lowercased()
        if detail.contains("error: 404") || detail.contains("http 404") {
            return true
        }
        return detail.contains("repository")
            && (detail.contains("not found") || detail.contains("does not exist")
                || detail.contains("does not appear to be a git repository"))
    }

    /// curl's and ssh's words for a remote that cannot be reached at all — no DNS, no route, no answer.
    var isNetworkFailure: Bool {
        guard case let .commandFailed(_, _, stderr, _) = self else { return false }
        let detail = stderr.lowercased()
        let markers = [
            "could not resolve host",
            "could not resolve proxy",
            "connection reset by peer",
            "empty reply from server",
            "failed to connect to",
            "couldn't connect to server",
            "network is unreachable",
            "connection timed out",
            "operation timed out"
        ]
        return markers.contains { detail.contains($0) }
    }

    /// Best-effort reads swallow git rejections, but host and local output-read failures reach the caller.
    static func preservingUnusability<T>(_ operation: () throws -> T) throws -> T? {
        do { return try operation() } catch let error as GitError {
            switch error {
            case .unusable, .outputReadFailed: throw error
            default: break
            }
            return nil
        } catch is CancellationError { throw CancellationError() } catch { return nil }
    }
}

enum PullResult: Equatable {
    case upToDate
    case merged
    case conflicted([String])
}

enum LsRemoteFailure: Equatable {
    case auth
    case other
}

struct GitCommit: Equatable {
    let sha: String
    let author: String
    let date: Date
    let subject: String
}

struct GitRemoteReferences: Equatable {
    let defaultBranch: String?
    let heads: [String]
}

protocol GitServiceProtocol: GitUsabilityProbing, GitRemoteReading {

    @_disfavoredOverload
    func initRepository(at path: String) throws
    @_disfavoredOverload
    func setRemote(_ url: String, at path: String) throws
    /// Remove `origin`. Throws when there is none (git exits 2); callers guard with the configured URL.
    @_disfavoredOverload
    func removeRemote(at path: String) throws
    /// The literal `remote.origin.url` as configured — never rewritten by `url.<base>.insteadOf`,
    /// which `remote get-url` applies. `nil` when no origin is configured; throws on any other git
    /// failure (a broken repository is never mistaken for "no remote").
    @_disfavoredOverload
    func configuredRemoteURL(at path: String) throws -> String?

    @_disfavoredOverload
    func clone(remote: String, into path: String, credential: GitCredential?) throws
    @_disfavoredOverload
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool
    @_disfavoredOverload
    func remoteReferences(remote: String, credential: GitCredential?) throws -> GitRemoteReferences
    @_disfavoredOverload
    func checkoutUnbornBranch(_ branch: String, at path: String) throws
    @_disfavoredOverload
    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws
    @_disfavoredOverload
    func materializeFromFetchHead(at path: String) throws
    @_disfavoredOverload
    func bornBranch(_ branch: String, at path: String) throws
    @_disfavoredOverload
    func setUpstream(branch: String, at path: String) throws
    @_disfavoredOverload
    func hasLocalBranches(at path: String) throws -> Bool
    @_disfavoredOverload
    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool
    @_disfavoredOverload
    func hasRemoteOriginConfigured(at path: String) throws -> Bool
    @discardableResult
    @_disfavoredOverload
    func stageAllAndCommit(at path: String, message: String) throws -> Bool
    @_disfavoredOverload
    func preflightStoreUpdate(at path: String, credential: GitCredential?) throws -> FetchedStoreRevision?
    @_disfavoredOverload
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult
    @_disfavoredOverload
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult
    @_disfavoredOverload
    func push(at path: String, credential: GitCredential?) throws
    @_disfavoredOverload
    func abortRebase(at path: String) throws
    @_disfavoredOverload
    func conflictedFiles(at path: String) throws -> [String]
    @_disfavoredOverload
    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> Data?
    @_disfavoredOverload
    func conflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry?
    @_disfavoredOverload
    func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws
    @_disfavoredOverload
    func retireConflictPath(_ path: String, at root: String) throws
    @_disfavoredOverload
    func removeConflictEntryFromIndex(_ path: String, at root: String) throws
    @_disfavoredOverload
    func continueRebase(at path: String) throws -> PullResult
    @_disfavoredOverload
    func skipRebase(at path: String) throws -> PullResult
    @_disfavoredOverload
    func stagePath(_ path: String, at root: String) throws
    @_disfavoredOverload
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                fetchedRevision: FetchedStoreRevision?) throws -> Bool
    @_disfavoredOverload
    func hasCommitsToPush(at path: String) throws -> Bool
    @_disfavoredOverload
    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit]
    @_disfavoredOverload
    func show(sha: String, path: String, at workingDir: String) -> String?
}

/// The app's first subprocess. A synchronous, throwing wrapper over `/usr/bin/git`.
/// Args are ALWAYS an array (never a shell string) → no SHELL-injection surface even with an
/// attacker-influenced remote URL/path. Two injection classes are distinct: array-passing kills shell
/// injection, but git still parses a leading-dash positional as an OPTION — so any op taking a
/// user-supplied remote/path positional puts a `--` end-of-options terminator before it, or git could
/// treat `--upload-pack=<cmd>` as an option and EXECUTE it. The Process boundary is the one sanctioned
/// exception to "all filesystem I/O goes through FileService": git owns `.git` and its writes.
struct GitService: GitServiceProtocol {
    #if GIT_PROCESS_PROBE
    var probeHooks: GitProcessProbeHooks?
    #endif
    private let gitPath: String
    let fileService: FileServiceProtocol
    let askpassHelperPath: String
    typealias UpstreamHistoryNetworkRunner = ([String], GitCredential?) throws -> GitOutput
    private let upstreamHistoryNetworkRunner: UpstreamHistoryNetworkRunner?

    /// The caller can place the secret-free helper beside its own application state.
    init(
        fileService: FileServiceProtocol = FileService(),
        askpassHelperPath: String,
        upstreamHistoryNetworkRunner: UpstreamHistoryNetworkRunner? = nil,
        executablePath: String = "/usr/bin/git"
    ) {
        self.gitPath = executablePath
        self.fileService = fileService
        self.askpassHelperPath = askpassHelperPath
        self.upstreamHistoryNetworkRunner = upstreamHistoryNetworkRunner
    }

    /// The captured result of one `git` invocation. A named struct (not a 3-tuple) keeps SwiftLint's
    /// `large_tuple` rule satisfied and reads clearly at call sites (`r.stdout` / `r.stderr` / `r.exit`).
    struct GitOutput {
        let stdout: String
        let stderr: String
        let exit: Int32
        var confirmingProbe: GitUsability?
    }

    /// Binary-preserving result for history blobs and NUL-delimited records. Most git callers use
    /// `GitOutput`; upstream History is the narrow exception because filenames and file contents are
    /// untrusted bytes and must not be split or silently collapsed during UTF-8 decoding.
    struct GitDataOutput {
        let stdout: Data
        let stderr: Data
        let exit: Int32
        var confirmingProbe: GitUsability?
    }

    // Exact-match strips. GIT_SSH_COMMAND/GIT_PROXY_COMMAND/GIT_EXTERNAL_DIFF are arbitrary-command sinks;
    // GIT_CONFIG/GIT_CONFIG_GLOBAL/SYSTEM/COUNT/PARAMETERS redirect or inject config. NOTE:
    // GIT_CONFIG_NOSYSTEM is DELIBERATELY absent — it HARDENS (ignore /etc/gitconfig), and a bare
    // `hasPrefix("GIT_CONFIG")` would wrongly strip it (re-enabling system config in hermetic tests).
    private static let strippedGitEnvExact: Set<String> = [
        "GIT_ASKPASS", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT", "GIT_PROXY_COMMAND",
        "GIT_EXTERNAL_DIFF", "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
        "GIT_ALLOW_PROTOCOL", "GIT_PROTOCOL_FROM_USER", "PENSIEVE_GIT_USERNAME", "PENSIEVE_GIT_PASSWORD", "PENSIEVE_GIT_HOST"
    ]
    // Prefix strips for indexed/family vars only: GIT_CONFIG_KEY_<n>/VALUE_<n> injection + all GIT_TRACE*
    // sinks. Scoped to these families so GIT_CONFIG_NOSYSTEM survives.
    private static let strippedGitEnvPrefixes = ["GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_", "GIT_TRACE"]

    // MARK: Environment (§B — verbatim)

    /// Built for a Finder-launched GUI app, which does NOT inherit the shell PATH or ssh-agent socket.
    /// We start from the inherited environment (for SSH_AUTH_SOCK passthrough — launchd provides it — so
    /// ssh-agent keys authenticate), augment PATH with the standard git/ssh locations, and set
    /// GIT_TERMINAL_PROMPT=0 so git FAILS FAST instead of hanging on a credential prompt in a process
    /// with no TTY. Pensieve strips inherited git-behavior overrides first, including the HTTPS-auth
    /// variables it owns, so a `.sshAgent`/`nil` op can never ride a stale parent askpass or secret.
    /// Git's empty askpass default disables core.askPass and SSH_ASKPASS for HTTP
    /// credentials. SSH itself still receives SSH_ASKPASS and SSH_AUTH_SOCK for key authentication.
    func childEnvironment(credential: GitCredential?) throws -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // C5: drop inherited git-behavior overrides a hostile/misconfigured parent could carry BEFORE we
        // set our own. Also drops the HTTPS-auth vars we own, so a `.sshAgent`/`nil` op can never ride a
        // stale secret. applyCredential re-sets them for `.httpsToken` only.
        for key in env.keys where Self.strippedGitEnvExact.contains(key)
            || Self.strippedGitEnvPrefixes.contains(where: { key.hasPrefix($0) }) {
            env.removeValue(forKey: key)
        }
        let extra = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = ""
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        try applyCredential(credential, to: &env)   // sets the auth vars for `.httpsToken`; no-op otherwise
        return env   // SSH_AUTH_SOCK passes through untouched if present
    }

    /// For `.httpsToken`, feed the secret to git via a GIT_ASKPASS helper that reads it from the CHILD
    /// ENVIRONMENT — never argv (invisible to `ps`), never `.git/config` (no cleartext at rest). For
    /// `.sshAgent`/`nil` this is a no-op (the passed-through SSH_AUTH_SOCK authenticates). (§E)
    /// The token rides ONLY the child env (`PENSIEVE_GIT_PASSWORD`/`USERNAME`), never argv and never the
    /// on-disk askpass helper file; the helper body references only `$PENSIEVE_GIT_*`.
    private func applyCredential(_ credential: GitCredential?, to env: inout [String: String]) throws {
        guard case let .httpsToken(username, token, host) = credential,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let helper = try ensureAskpassHelper()      // propagate a write failure (was try?-swallowed)
        env["GIT_ASKPASS"] = helper
        env["PENSIEVE_GIT_HOST"] = host.lowercased()
        env["PENSIEVE_GIT_USERNAME"] = username
        env["PENSIEVE_GIT_PASSWORD"] = token   // CHILD ENV only — not argv, not disk
    }

    /// Ensure the secret-free askpass helper exists at 0700, written THROUGH FileService so even this
    /// write stays inside the single filesystem chokepoint. The helper body contains NO secret — it
    /// echoes `PENSIEVE_GIT_USERNAME` / `PENSIEVE_GIT_PASSWORD` read from the environment. We ALWAYS
    /// (re)write it rather than trust a pre-existing file, so a helper left with stale content or
    /// broader permissions can never be reused; the write is idempotent and cheap next to the network
    /// op it precedes.
    private func ensureAskpassHelper() throws -> String {
        let path = askpassHelperPath
        let body = """
        #!/bin/sh
        case "$1" in
          "Username for 'https://"*"': "|"Password for 'https://"*"': ") ;;
          *) exit 1 ;;
        esac
        address=${1#*\\'}
        address=${address%\\'*}
        authority=${address#https://}
        authority=${authority%%/*}
        authority=${authority##*@}
        case "$authority" in
          \\[*\\]*) host=${authority#\\[}; host=${host%%\\]*} ;;
          *) host=${authority%%:*} ;;
        esac
        host=$(printf '%s' "$host" | LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]')
        [ "$host" = "$PENSIEVE_GIT_HOST" ] || exit 1
        case "$1" in
          Username*) printf '%s' "$PENSIEVE_GIT_USERNAME" ;;
          Password*) printf '%s' "$PENSIEVE_GIT_PASSWORD" ;;
        esac
        """
        try fileService.writeExecutableFile(at: path, content: body + "\n")
        return path
    }

    // MARK: Process runner (§B — verbatim)

    func runUpstreamHistoryNetwork(
        _ args: [String],
        credential: GitCredential?
    ) throws -> GitOutput {
        if let upstreamHistoryNetworkRunner {
            return try upstreamHistoryNetworkRunner(args, credential)
        }
        return try run(args, in: nil, credential: credential)
    }

    @discardableResult
    func runData(
        _ args: [String], in workingDir: String?, credential: GitCredential? = nil, storeRules: Bool = false,
        file: StaticString = #fileID, line: UInt = #line
    ) throws
        -> GitDataOutput {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRunData(args, in: workingDir, credential: credential, storeRules: storeRules, file: file, line: line)
        }
    }

    private func performRunData(
        _ args: [String], in workingDir: String?, credential: GitCredential?, storeRules: Bool,
        file: StaticString, line: UInt
    ) throws -> GitDataOutput {
        GitThreadGuard.check(file: file, line: line)
        try GitCancellation.check()
        var environment = try childEnvironment(credential: credential)
        if storeRules { environment["GIT_ATTR_NOSYSTEM"] = "1" }
        let configuredArguments = storeRules ? Self.storeConfigurationArgs + args : args
        // Reset the configured helper chain for reads and writes: no get, store or erase.
        // childEnvironment also disables foreign HTTP askpass programs. Credentials the user
        // configures elsewhere in git or curl can still apply, even with a Pensieve token.
        let arguments = ["-c", "credential.helper="] + configuredArguments
        let child = try GitProcess(executable: gitPath, arguments: arguments, workingDirectory: workingDir,
                                   environment: environment)
        #if GIT_PROCESS_PROBE
        child.probeHooks = probeHooks
        probeHooks?.started(child.pid)
        #endif
        var output = try child.readOutput()
        // Command output is only a hint: repository-controlled text can resemble a broken shim.
        // Confirm at the shared runner so clone, fetch, conflict and install callers agree.
        // The diagnostic command bypasses this branch, preventing recursive probes.
        if output.exit != 0, args != ["--version"],
           GitUsability.environmentFailure(exit: output.exit,
               output: output.textOutput.stdout + output.textOutput.stderr) != nil {
            let answer = try probeUsability()
            try answer.requireUsable()
            output.confirmingProbe = answer
        }
        return output
    }

    /// Optional reads retain their fallback for git rejections; host and local output-read failures propagate.
    func performRunBestEffort(_ args: [String], in workingDir: String?) throws -> GitOutput? {
        try GitError.preservingUnusability { try run(args, in: workingDir) }
    }

    /// Run and throw `.commandFailed` on a non-zero exit. For fixture-style ops with no auth surface.
    @discardableResult
    func performRunOrThrow(_ args: [String], in workingDir: String?, credential: GitCredential?,
                           storeRules: Bool) throws
        -> GitOutput {
        let r = try run(args, in: workingDir, credential: credential, storeRules: storeRules)
        guard r.exit == 0 else {
            throw commandError(r, args: args)
        }
        return r
    }

    // MARK: Classification helpers

    /// stderr/stdout signatures from ssh/https that mean "auth failed" (frozen plan §B / 08.1 Work).
    static func classifyLsRemoteFailure(exitCode: Int32, combinedOutput: String) -> LsRemoteFailure {
        guard exitCode != 0 else { return .other }
        return authSignatures.contains(where: { combinedOutput.contains($0) }) ? .auth : .other
    }

    private static let authSignatures = [
        "Permission denied (publickey)",
        "Authentication failed",
        "The requested URL returned error: 403",
        "HTTP 403",
        "could not read Username",
        "Host key verification failed",
        "Invalid username or password",
        "terminal prompts disabled"
    ]

    func headSHA(at path: String) throws -> String? {
        guard let r = try runBestEffort(["-C", path, "rev-parse", "HEAD"], in: nil), r.exit == 0 else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Set a LOCAL commit identity fallback when none is configured, so `commit` never fails on a
    /// machine (or a hermetic test HOME) with no global git identity. Only writes when unset.
    func ensureCommitIdentity(at path: String) throws {
        if (try runBestEffort(["-C", path, "config", "user.email"], in: nil))?.exit != 0 {
            _ = try runBestEffort(["-C", path, "config", "user.email", "sync@pensieve.local"], in: nil)
        }
        if (try runBestEffort(["-C", path, "config", "user.name"], in: nil))?.exit != 0 {
            _ = try runBestEffort(["-C", path, "config", "user.name", "Pensieve Sync"], in: nil)
        }
    }

}

extension GitService {
    // MARK: GitServiceProtocol

    /// `git init` + force the default branch to `main` deterministically (regardless of the host's
    /// `init.defaultBranch`), + a local identity fallback. `path` must already exist.
    @_disfavoredOverload
    func initRepository(at path: String) throws {
        try runOrThrow(["-C", path, "init"], in: nil, storeRules: true)
        try runOrThrow(["-C", path, "symbolic-ref", "HEAD", "refs/heads/main"], in: nil)
        try ensureCommitIdentity(at: path)
        _ = try storeOperation(at: path)
    }

    @_disfavoredOverload
    func setRemote(_ url: String, at path: String) throws {
        if try remoteURL(at: path) == nil {
            try runOrThrow(["-C", path, "remote", "add", "origin", url], in: nil)
        } else {
            try runOrThrow(["-C", path, "remote", "set-url", "origin", url], in: nil)
        }
    }

    @_disfavoredOverload
    func removeRemote(at path: String) throws {
        try runOrThrow(["-C", path, "remote", "remove", "origin"], in: nil)
    }

    @_disfavoredOverload
    func configuredRemoteURL(at path: String) throws -> String? {
        // `--local` refuses to run outside a discoverable repository (exit 128) — without it a corrupt or
        // missing `.git/HEAD` makes `git config --get` read the global config and report the key absent
        // (exit 1), and a disconnect would report success while `.git/config` still held origin.
        let r = try run(["-C", path, "config", "--local", "--get", "remote.origin.url"], in: nil)
        switch r.exit {
        case 0:
            let url = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : url
        case 1:
            return nil   // `git config --get`: exit 1 = key absent
        default:
            throw commandError(r, args: ["config", "--local", "--get", "remote.origin.url"])
        }
    }

    @_disfavoredOverload
    func clone(remote: String, into path: String, credential: GitCredential?) throws {
        // `--` terminates options: without it git parses a `--upload-pack=<cmd>`-style remote as an
        // OPTION and executes it (git-option injection — distinct from shell injection). See type doc.
        // Keep an incomplete repository away from the live store, including across process death.
        // Publish only after attributes and checkout succeed; retry can use another sibling.
        try requireEmptyCloneDestination(at: path)
        let parent = (path as NSString).deletingLastPathComponent
        let staging = parent + "/.pensieve-clone-" + UUID().uuidString
        defer {
            if fileService.directoryExists(at: staging) { try? fileService.deleteDirectory(at: staging) }
        }
        let args = ["clone", "--quiet", "--no-checkout", "--", remote, staging]
        let r = try run(args, in: nil, credential: credential, storeRules: true)
        if r.exit == 0 {
            let store = try storeOperation(at: staging)
            // A throwing branch observation distinguishes an empty remote from a failed HEAD read.
            if try hasLocalBranches(at: staging) {
                try store.runOrThrow(["checkout", "--force"])
            }
            try fileService.publishDirectory(at: staging, to: path)
            return
        }
        throw commandError(r, args: args, authenticationRemote: remote)
    }

    @_disfavoredOverload
    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws {
        var args = ["clone", "--quiet", "--depth", "1"]
        if let branch {
            args += ["--branch", branch]
        }
        // Keep the remote and destination behind the option terminator just like the full clone path.
        args += ["--", remote, path]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        throw commandError(r, args: args, authenticationRemote: remote)
    }

    @_disfavoredOverload
    func commitSHA(at path: String) throws -> String {
        try revision("HEAD", at: path)
    }

    @_disfavoredOverload
    func currentBranch(at path: String) throws -> String {
        try revision("--abbrev-ref", "HEAD", at: path)
    }

    @_disfavoredOverload
    func treeHash(at repositoryPath: String, path: String) throws -> String {
        let revision = path.isEmpty ? "HEAD^{tree}" : "HEAD:\(path)"
        return try self.revision(revision, at: repositoryPath)
    }

    /// True if the remote already has at least one branch (a fresh `init --bare` remote has none).
    /// Best-effort probe: any error (including auth) yields false.
    @_disfavoredOverload
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool {
        // `--` terminates options — see clone(): `git ls-remote` also honors `--upload-pack`, so a
        // leading-dash remote must never be parsed as an option.
        guard let r = try? run(["ls-remote", "--heads", "--", remote], in: nil, credential: credential),
              r.exit == 0 else {
            return false
        }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension GitService {
    @_disfavoredOverload
    func remoteReferences(remote: String, credential: GitCredential?) throws -> GitRemoteReferences {
        let args = ["ls-remote", "--symref", "--", remote, "HEAD", "refs/heads/*"]
        let result = try runData(args, in: nil, credential: credential)
        guard result.exit == 0 else {
            throw dataCommandError(result, args: args, authenticationRemote: remote)
        }
        let defaultPrefix = Array("ref: refs/heads/".utf8)
        let headPrefix = Array("refs/heads/".utf8)
        var defaultBranch: String?
        var heads: [String] = []
        for line in result.stdout.split(separator: 0x0A) {
            let fields = line.split(separator: 0x09, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            if fields[1].elementsEqual("HEAD".utf8), fields[0].starts(with: defaultPrefix) {
                defaultBranch = Self.exactRefName(fields[0].dropFirst(defaultPrefix.count))
            } else if fields[1].starts(with: headPrefix),
                      let name = Self.exactRefName(fields[1].dropFirst(headPrefix.count)) {
                heads.append(name)
            }
        }
        return GitRemoteReferences(defaultBranch: defaultBranch, heads: heads)
    }

    private static func exactRefName(_ bytes: Data.SubSequence) -> String? {
        guard !bytes.isEmpty else { return nil }
        // String(bytes:encoding:) consumes an initial BOM. The validating initializer
        // retains it and rejects malformed UTF-8 without consuming any name bytes.
        guard let name = String(validating: bytes, as: UTF8.self), name.utf8.elementsEqual(bytes) else { return nil }
        return name
    }

    @_disfavoredOverload
    func checkoutUnbornBranch(_ branch: String, at path: String) throws {
        try storeOperation(at: path).runOrThrow(["checkout", "-B", branch])
    }

    @_disfavoredOverload
    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws {
        try runOrThrow(["-C", path, "fetch", "--quiet", "origin", branch], in: nil, credential: credential)
    }

    @_disfavoredOverload
    func materializeFromFetchHead(at path: String) throws {
        try storeOperation(at: path).runOrThrow(
            ["restore", "--source=FETCH_HEAD", "--staged", "--worktree", "--", ":/"])
    }

    @_disfavoredOverload
    func bornBranch(_ branch: String, at path: String) throws {
        try runOrThrow(["-C", path, "update-ref", "refs/heads/\(branch)", "FETCH_HEAD", ""], in: nil)
    }

    @_disfavoredOverload
    func setUpstream(branch: String, at path: String) throws {
        try runOrThrow(
            ["-C", path, "branch", "--set-upstream-to=origin/\(branch)", branch],
            in: nil
        )
    }

    @_disfavoredOverload
    func hasLocalBranches(at path: String) throws -> Bool {
        let result = try runOrThrow(
            ["-C", path, "for-each-ref", "--format=%(refname)", "refs/heads"],
            in: nil
        )
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @_disfavoredOverload
    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool {
        guard let result = try? run(
            ["-C", path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"],
            in: nil
        ) else { return false }
        return result.exit == 0
    }

    @_disfavoredOverload
    func hasRemoteOriginConfigured(at path: String) throws -> Bool {
        let args = ["-C", path, "config", "--get", "remote.origin.url"]
        let result = try run(args, in: nil)
        switch result.exit {
        case 0:
            return true
        case 1:
            return false
        default:
            throw commandError(result, args: args)
        }
    }
}

extension GitService {
    private func revision(_ args: String..., at path: String) throws -> String {
        let output = try runOrThrow(["-C", path, "rev-parse"] + args, in: nil)
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw commandError(args: ["-C", path, "rev-parse"] + args, exitCode: output.exit,
                               detail: "git returned an empty revision", confirmingProbe: output.confirmingProbe)
        }
        return value
    }

    /// Stage everything and commit. Returns false when there is nothing to commit.
    @discardableResult
    @_disfavoredOverload
    func stageAllAndCommit(at path: String, message: String) throws -> Bool {
        try ensureCommitIdentity(at: path)
        let store = try storeOperation(at: path)
        try store.stage()
        return try store.commitStagedChanges(message: message)
    }

    /// Fetch origin/main, guard protected local files, then pull the pinned commit with rebase.
    /// Distinguishes up-to-date / merged / conflicted STRUCTURALLY
    /// (no locale-sensitive string matching): conflict = non-zero exit AND `--diff-filter=U` non-empty;
    /// up-to-date vs merged = HEAD unchanged vs changed.
    @_disfavoredOverload
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
        let revision = try fetchStoreRevision(at: path, credential: credential)
        return try pullRebase(at: path, fetchedRevision: revision)
    }

    /// Pull the already fetched and checked commit from this repository. A second remote fetch could
    /// introduce a colliding path after the app's pre-write guard, so it must not happen here.
    @_disfavoredOverload
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        let store = try storeOperation(at: path)
        try store.requireNoExcludedCollision(with: fetchedRevision.commit)
        let before = try headSHA(at: path)
        let args = ["-C", path] + (try store.pullArguments(for: fetchedRevision))
        let r = try store.run(Array(args.dropFirst(2)))
        if r.exit == 0 {
            let after = try headSHA(at: path)
            return before == after ? .upToDate : .merged
        }
        let conflicts = try conflictedFiles(at: path)
        if !conflicts.isEmpty {
            return .conflicted(conflicts)
        }
        throw commandError(r, args: args)
    }

    @_disfavoredOverload
    func push(at path: String, credential: GitCredential?) throws {
        let args = ["-C", path, "push", "-u", "origin", "main"]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        throw commandError(r, args: args, authenticationRemote: authenticationRemoteLabel(at: path))
    }

    @_disfavoredOverload
    func abortRebase(at path: String) throws {
        let store = try StoreGitOperation(git: self, root: path, aborting: true)
        try store.runOrThrow(["rebase", "--abort"])
        if let repairFailure = store.repairFailure { throw repairFailure }
    }

    @_disfavoredOverload
    func conflictedFiles(at path: String) throws -> [String] {
        guard let r = try runBestEffort(["-C", path, "diff", "--name-only", "--diff-filter=U", "-z"], in: nil),
              r.exit == 0 else {
            return []
        }
        return r.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}

// Capture the source before entering implementation helpers or closures.
extension GitService {

    func runBestEffort(_ args: [String], in workingDir: String?,
                       file: StaticString = #fileID, line: UInt = #line) throws -> GitOutput? {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRunBestEffort(args, in: workingDir)
        }
    }

    @discardableResult
    func runOrThrow(_ args: [String], in workingDir: String?, credential: GitCredential? = nil,
                    storeRules: Bool = false,
                    file: StaticString = #fileID, line: UInt = #line) throws
        -> GitOutput {
        try GitThreadGuard.withCallSite(file: file, line: line) {
            try performRunOrThrow(args, in: workingDir, credential: credential, storeRules: storeRules)
        }
    }

}
