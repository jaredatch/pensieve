import Foundation

// PLAN-24 keeps the ten tightly-coupled adoption subprocess members beside the existing git runner.
// swiftlint:disable file_length

/// How a network-touching git op authenticates. Introduced in 08.1 as an opaque, nil-defaulted seam;
/// the `.httpsToken` injection body lands in 08.2 (§E). In 08.1 only `.sshAgent`/`nil` is exercised.
enum GitCredential: Equatable {
    case sshAgent
    case httpsToken(username: String, token: String)
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
    /// Best-effort reads swallow git rejections, but host and local output-read failures reach the caller.
    static func preservingUnusability<T>(_ operation: () throws -> T) throws -> T? {
        do { return try operation() } catch let error as GitError {
            switch error {
            case .unusable, .outputReadFailed: throw error
            default: break
            }
            return nil
        } catch { return nil }
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

protocol GitServiceProtocol {
    func probeUsability() throws -> GitUsability
    func initRepository(at path: String) throws
    func setRemote(_ url: String, at path: String) throws
    /// Remove `origin`. Throws when there is none (git exits 2); callers guard with the configured URL.
    func removeRemote(at path: String) throws
    /// The literal `remote.origin.url` as configured — never rewritten by `url.<base>.insteadOf`,
    /// which `remote get-url` applies. `nil` when no origin is configured; throws on any other git
    /// failure (a broken repository is never mistaken for "no remote").
    func configuredRemoteURL(at path: String) throws -> String?
    func remoteURL(at path: String) throws -> String?
    func clone(remote: String, into path: String, credential: GitCredential?) throws
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool
    func remoteDefaultBranch(remote: String, credential: GitCredential?) throws -> String?
    func remoteBranches(remote: String, credential: GitCredential?) throws -> [String]
    func checkoutUnbornBranch(_ branch: String, at path: String) throws
    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws
    func materializeFromFetchHead(at path: String) throws
    func bornBranch(_ branch: String, at path: String) throws
    func setUpstream(branch: String, at path: String) throws
    func hasLocalBranches(at path: String) throws -> Bool
    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool
    func hasRemoteOriginConfigured(at path: String) throws -> Bool
    @discardableResult
    func stageAllAndCommit(at path: String, message: String) throws -> Bool
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult
    func push(at path: String, credential: GitCredential?) throws
    func abortRebase(at path: String) throws
    func conflictedFiles(at path: String) throws -> [String]
    func blob(atStage stage: Int, path: String, in workingDir: String) throws -> String?
    func continueRebase(at path: String) throws -> PullResult
    func skipRebase(at path: String) throws -> PullResult
    func stagePath(_ path: String, at root: String) throws
    func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?) throws -> Bool
    func hasCommitsToPush(at path: String) throws -> Bool
    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit]
    func show(sha: String, path: String, at workingDir: String) -> String?
}

extension GitServiceProtocol {
    /// Inert default for doubles that do not model the host environment.
    func probeUsability() -> GitUsability { .usable }
    func remoteDefaultBranch(remote: String, credential: GitCredential?) throws -> String? { nil }
    func remoteBranches(remote: String, credential: GitCredential?) throws -> [String] { [] }
    func checkoutUnbornBranch(_ branch: String, at path: String) throws {}
    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws {}
    func materializeFromFetchHead(at path: String) throws {}
    func bornBranch(_ branch: String, at path: String) throws {}
    func setUpstream(branch: String, at path: String) throws {}
    func hasLocalBranches(at path: String) throws -> Bool { true }
    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool { false }
    func hasRemoteOriginConfigured(at path: String) throws -> Bool { true }
    func log(forPath path: String, at workingDir: String, limit: Int) -> [GitCommit] { [] }
    func show(sha: String, path: String, at workingDir: String) -> String? { nil }
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
        askpassHelperPath: String = PathConstants.gitAskpassHelperPath,
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
        "GIT_ALLOW_PROTOCOL", "GIT_PROTOCOL_FROM_USER", "PENSIEVE_GIT_USERNAME", "PENSIEVE_GIT_PASSWORD"
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
    /// variables it owns, so a `.sshAgent`/`nil` op can never ride a stale parent askpass or secret, and
    /// `applyCredential` is the ONLY thing that (re)sets them — for `.httpsToken` alone (§E).
    /// Internal (not private) so 08.2's GitServiceTests can assert the credential rides the child ENV
    /// (GIT_ASKPASS + PENSIEVE_GIT_PASSWORD) and never argv, and that a non-token op is sanitized.
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
        guard case let .httpsToken(username, token) = credential else { return }
        let helper = try ensureAskpassHelper()      // propagate a write failure (was try?-swallowed)
        env["GIT_ASKPASS"] = helper
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
          Username*) printf '%s' "$PENSIEVE_GIT_USERNAME" ;;
          *)         printf '%s' "$PENSIEVE_GIT_PASSWORD" ;;
        esac
        """
        try fileService.writeExecutableFile(at: path, content: body + "\n")
        return path
    }

    // MARK: Process runner (§B — verbatim)

    @discardableResult
    func run(_ args: [String], in workingDir: String?, credential: GitCredential? = nil) throws
        -> GitOutput {
        let result = try runData(args, in: workingDir, credential: credential)
        return GitOutput(
            stdout: String(bytes: result.stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: result.stderr, encoding: .utf8) ?? "",
            exit: result.exit, confirmingProbe: result.confirmingProbe
        )
    }

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
        _ args: [String], in workingDir: String?, credential: GitCredential? = nil
    ) throws
        -> GitDataOutput {
        let child = try GitProcess(executable: gitPath, arguments: args, workingDirectory: workingDir,
                                   environment: childEnvironment(credential: credential))
        #if GIT_PROCESS_PROBE
        child.probeHooks = probeHooks
        probeHooks?.started(child.pid)
        #endif
        var output = try child.readOutput()
        // Command output is only a hint: repository-controlled text can resemble a broken shim.
        // Confirm at the shared runner so clone, fetch, conflict and install callers agree.
        // The diagnostic command bypasses this branch, preventing recursive probes.
        let stderr = String(bytes: output.stderr, encoding: .utf8) ?? ""
        let detail = stderr.isEmpty ? (String(bytes: output.stdout, encoding: .utf8) ?? "") : stderr
        if args != ["--version"], GitUsability.environmentFailure(exit: output.exit, output: detail) != nil {
            let answer = try probeUsability()
            try answer.requireUsable()
            output.confirmingProbe = answer
        }
        return output
    }

    /// Optional reads retain their fallback for git rejections; host and local output-read failures propagate.
    func runBestEffort(_ args: [String], in workingDir: String?) throws -> GitOutput? {
        try GitError.preservingUnusability { try run(args, in: workingDir) }
    }

    /// Run and throw `.commandFailed` on a non-zero exit. For fixture-style ops with no auth surface.
    @discardableResult
    func runOrThrow(_ args: [String], in workingDir: String?, credential: GitCredential? = nil) throws
        -> GitOutput {
        let r = try run(args, in: workingDir, credential: credential)
        guard r.exit == 0 else {
            throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
                confirmingProbe: r.confirmingProbe)
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
        "could not read Username",
        "Host key verification failed",
        "Invalid username or password",
        "terminal prompts disabled"
    ]

    func isAuthFailure(_ text: String) -> Bool {
        Self.authSignatures.contains { text.contains($0) }
    }

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

    // MARK: GitServiceProtocol

    /// `git init` + force the default branch to `main` deterministically (regardless of the host's
    /// `init.defaultBranch`), + a local identity fallback. `path` must already exist.
    func initRepository(at path: String) throws {
        try runOrThrow(["-C", path, "init"], in: nil)
        try runOrThrow(["-C", path, "symbolic-ref", "HEAD", "refs/heads/main"], in: nil)
        try ensureCommitIdentity(at: path)
    }

    func setRemote(_ url: String, at path: String) throws {
        if try remoteURL(at: path) == nil {
            try runOrThrow(["-C", path, "remote", "add", "origin", url], in: nil)
        } else {
            try runOrThrow(["-C", path, "remote", "set-url", "origin", url], in: nil)
        }
    }

    func removeRemote(at path: String) throws {
        try runOrThrow(["-C", path, "remote", "remove", "origin"], in: nil)
    }

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
            throw GitError.commandFailed(
                args: ["config", "--local", "--get", "remote.origin.url"],
                exitCode: r.exit,
                stderr: r.stderr, confirmingProbe: r.confirmingProbe)
        }
    }

    func clone(remote: String, into path: String, credential: GitCredential?) throws {
        // `--` terminates options: without it git parses a `--upload-pack=<cmd>`-style remote as an
        // OPTION and executes it (git-option injection — distinct from shell injection). See type doc.
        let args = ["clone", "--quiet", "--", remote, path]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        let combined = r.stdout + r.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: remote, detail: combined)
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    /// The empty credential.helper value resets Git's configured helper list. EVERY install-path
    /// network invocation (cloneShallow today; remoteHead/ls-remote when 19.7 adds them) must prefix
    /// its args with this — a helper like osxkeychain would otherwise silently authenticate with a
    /// machine-level credential the install namespace never granted.
    static let installCredentialIsolationArgs = ["-c", "credential.helper="]

    func cloneShallow(remote: String, branch: String?, into path: String,
                      credential: GitCredential?) throws {
        var args = Self.installCredentialIsolationArgs + ["clone", "--quiet", "--depth", "1"]
        if let branch {
            args += ["--branch", branch]
        }
        // Keep the remote and destination behind the option terminator just like the full clone path.
        args += ["--", remote, path]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        let combined = r.stdout + r.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: remote, detail: combined)
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    func commitSHA(at path: String) throws -> String {
        try revision("HEAD", at: path)
    }

    func currentBranch(at path: String) throws -> String {
        try revision("--abbrev-ref", "HEAD", at: path)
    }

    func treeHash(at repositoryPath: String, path: String) throws -> String {
        let revision = path.isEmpty ? "HEAD^{tree}" : "HEAD:\(path)"
        return try self.revision(revision, at: repositoryPath)
    }

    /// True if the remote already has at least one branch (a fresh `init --bare` remote has none).
    /// Best-effort probe: any error (including auth) yields false.
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
    func remoteDefaultBranch(remote: String, credential: GitCredential?) throws -> String? {
        let args = ["ls-remote", "--symref", "--", remote, "HEAD"]
        let result = try run(args, in: nil, credential: credential)
        guard result.exit == 0 else {
            let combined = result.stdout + result.stderr
            if Self.classifyLsRemoteFailure(exitCode: result.exit, combinedOutput: combined) == .auth {
                throw GitError.authenticationFailed(remote: remote, detail: combined)
            }
            return nil
        }
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] == "HEAD" else { continue }
            let prefix = "ref: refs/heads/"
            guard fields[0].hasPrefix(prefix) else { continue }
            return String(fields[0].dropFirst(prefix.count))
        }
        return nil
    }

    func remoteBranches(remote: String, credential: GitCredential?) throws -> [String] {
        let args = ["ls-remote", "--heads", "--", remote]
        let result = try run(args, in: nil, credential: credential)
        guard result.exit == 0 else {
            let combined = result.stdout + result.stderr
            if Self.classifyLsRemoteFailure(exitCode: result.exit, combinedOutput: combined) == .auth {
                throw GitError.authenticationFailed(remote: remote, detail: combined)
            }
            throw GitError.commandFailed(
                args: args,
                exitCode: result.exit,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr, confirmingProbe: result.confirmingProbe)
        }
        let prefix = "refs/heads/"
        return result.stdout.split(separator: "\n").compactMap { line in
            guard let ref = line.split(separator: "\t", omittingEmptySubsequences: false).last,
                  ref.hasPrefix(prefix) else { return nil }
            return String(ref.dropFirst(prefix.count))
        }
    }

    func checkoutUnbornBranch(_ branch: String, at path: String) throws {
        try runOrThrow(["-C", path, "checkout", "-B", branch], in: nil)
    }

    func fetchBranch(_ branch: String, at path: String, credential: GitCredential?) throws {
        try runOrThrow(["-C", path, "fetch", "--quiet", "origin", branch], in: nil, credential: credential)
    }

    func materializeFromFetchHead(at path: String) throws {
        try runOrThrow(
            ["-C", path, "restore", "--source=FETCH_HEAD", "--staged", "--worktree", "--", ":/"],
            in: nil
        )
    }

    func bornBranch(_ branch: String, at path: String) throws {
        try runOrThrow(["-C", path, "update-ref", "refs/heads/\(branch)", "FETCH_HEAD", ""], in: nil)
    }

    func setUpstream(branch: String, at path: String) throws {
        try runOrThrow(
            ["-C", path, "branch", "--set-upstream-to=origin/\(branch)", branch],
            in: nil
        )
    }

    func hasLocalBranches(at path: String) throws -> Bool {
        let result = try runOrThrow(
            ["-C", path, "for-each-ref", "--format=%(refname)", "refs/heads"],
            in: nil
        )
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasRemoteTrackingBranch(_ branch: String, at path: String) -> Bool {
        guard let result = try? run(
            ["-C", path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"],
            in: nil
        ) else { return false }
        return result.exit == 0
    }

    func hasRemoteOriginConfigured(at path: String) throws -> Bool {
        let args = ["-C", path, "config", "--get", "remote.origin.url"]
        let result = try run(args, in: nil)
        switch result.exit {
        case 0:
            return true
        case 1:
            return false
        default:
            throw GitError.commandFailed(
                args: args,
                exitCode: result.exit,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr, confirmingProbe: result.confirmingProbe)
        }
    }
}

extension GitService {
    private func revision(_ args: String..., at path: String) throws -> String {
        let output = try runOrThrow(["-C", path, "rev-parse"] + args, in: nil)
        let value = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw GitError.commandFailed(
                args: ["-C", path, "rev-parse"] + args,
                exitCode: output.exit,
                stderr: "git returned an empty revision", confirmingProbe: output.confirmingProbe)
        }
        return value
    }

    /// Stage everything and commit. Returns false when there is nothing to commit.
    @discardableResult
    func stageAllAndCommit(at path: String, message: String) throws -> Bool {
        try ensureCommitIdentity(at: path)
        try runOrThrow(["-C", path, "add", "-A"], in: nil)
        let status = try runOrThrow(["-C", path, "status", "--porcelain"], in: nil)
        if status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false   // nothing to commit
        }
        try runOrThrow(["-C", path, "commit", "-m", message], in: nil)
        return true
    }

    /// `git pull --rebase origin main`. Distinguishes up-to-date / merged / conflicted STRUCTURALLY
    /// (no locale-sensitive string matching): conflict = non-zero exit AND `--diff-filter=U` non-empty;
    /// up-to-date vs merged = HEAD unchanged vs changed.
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
        let before = try headSHA(at: path)
        let args = ["-C", path, "pull", "--rebase", "origin", "main"]
        let r = try run(args, in: nil, credential: credential)
        if r.exit == 0 {
            let after = try headSHA(at: path)
            return before == after ? .upToDate : .merged
        }
        let conflicts = try conflictedFiles(at: path)
        if !conflicts.isEmpty {
            return .conflicted(conflicts)
        }
        let combined = r.stdout + r.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: authenticationRemoteLabel(at: path), detail: combined)
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    func push(at path: String, credential: GitCredential?) throws {
        let args = ["-C", path, "push", "-u", "origin", "main"]
        let r = try run(args, in: nil, credential: credential)
        guard r.exit != 0 else { return }
        let combined = r.stdout + r.stderr
        if isAuthFailure(combined) {
            throw GitError.authenticationFailed(remote: authenticationRemoteLabel(at: path), detail: combined)
        }
        throw GitError.commandFailed(args: args, exitCode: r.exit, stderr: r.stderr.isEmpty ? r.stdout : r.stderr,
            confirmingProbe: r.confirmingProbe)
    }

    func abortRebase(at path: String) throws {
        try runOrThrow(["-C", path, "rebase", "--abort"], in: nil)
    }

    func conflictedFiles(at path: String) throws -> [String] {
        guard let r = try runBestEffort(["-C", path, "diff", "--name-only", "--diff-filter=U", "-z"], in: nil),
              r.exit == 0 else {
            return []
        }
        return r.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}
