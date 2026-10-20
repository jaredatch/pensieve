import SwiftData
import XCTest
@testable import Pensieve
private typealias PensieveCategory = Pensieve.Category

// MARK: - Shared helpers
extension SyncConflictResolutionTests {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, PensieveCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    func rawGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(bytes: outData, encoding: .utf8) ?? ""
        let stderr = String(bytes: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TestFailure("git \(args.joined(separator: " ")) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteHead(_ remotePath: String) throws -> String {
        try rawGit(["--git-dir", remotePath, "rev-parse", "refs/heads/main"])
    }

    @discardableResult
    func writeSkillFile(root: String, body: String) throws -> String {
        let dir = root + "/skills/" + Self.slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(Self.slug)
        description: Conflict description
        ---

        \(body)
        """
        try (markdown + "\n").write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
        return markdown + "\n"
    }

    func readSkill(root: String) throws -> String {
        try String(contentsOfFile: root + "/" + Self.skillPath, encoding: .utf8)
    }
}

// MARK: - Path-safety stubs
extension SyncConflictResolutionTests {
    final class StubGit: GitServiceProtocol {
        func isWorktreeClean(at path: String) -> Bool { false }
        func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult { .diverged }
        func manifestMatchesHead(at path: String) throws -> Bool { false }
        let conflictPath: String
        let pullError: Error?
        private(set) var stagedPaths: [String] = []
        private(set) var pullAttempted = false
        private(set) var abortsAfterPull = 0

        init(conflictPath: String, pullError: Error? = nil) {
            self.conflictPath = conflictPath
            self.pullError = pullError
        }

        func remoteURL(at path: String) -> String? { "https://fixture.test/x.git" }
        func prepareStoreRules(at root: String, files: FileServiceProtocol) throws {
            // This stub reports an initialized store; supply metadata for the real publisher.
            try files.createDirectory(at: root + "/.git")
            try StoreIgnoreRules.prepare(at: root, files: files)
        }
        func initRepository(at path: String) throws {}
        func setRemote(_ url: String, at path: String) throws {}
        func removeRemote(at path: String) throws {}
        func configuredRemoteURL(at path: String) throws -> String? { nil }
        func clone(remote: String, into path: String, credential: GitCredential?) throws {}
        func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { true }
        @discardableResult
        func stageAllAndCommit(at path: String, message: String) throws -> Bool { true }
        func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
        func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
            try pullRebase(at: path, credential: nil)
        }
        func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
            pullAttempted = true
            if let pullError { throw pullError }
            return .conflicted([conflictPath])
        }
        func push(at path: String, credential: GitCredential?) throws {}
        func abortRebase(at path: String) throws { if pullAttempted { abortsAfterPull += 1 } }
        func conflictedFiles(at path: String) -> [String] { [conflictPath] }
        func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? {
            Data((stage == 3 ? "this" : "other").utf8)
        }
        func continueRebase(at path: String) throws -> PullResult { .merged }
        func skipRebase(at path: String) throws -> PullResult { .merged }
        func stagePath(_ path: String, at root: String) throws { stagedPaths.append(path) }
        func collapseToSingleCommit(at root: String, message: String, credential: GitCredential?,
                                    fetchedRevision: FetchedStoreRevision?) throws -> Bool {
            true
        }
        func hasCommitsToPush(at path: String) -> Bool { false }
        func conflictEntry(atStage stage: Int, path: String, in workingDir: String) throws -> ConflictEntry? {
            try blob(atStage: stage, path: path, in: workingDir).map {
                ConflictEntry(mode: "100644", objectID: "", bytes: $0)
            }
        }

        func restoreConflictEntry(_ entry: ConflictEntry, stage: Int, path: String, at root: String) throws {
            throw GitError.repositoryUnreadable(path: root, detail: "Conflict entry restoration is unavailable.")
        }

        func removeConflictEntryFromIndex(_ path: String, at root: String) throws {
            throw GitError.repositoryUnreadable(path: root, detail: "Conflict index removal is unavailable.")
        }

        func retireConflictPath(_ path: String, at root: String) throws {
            throw GitError.repositoryUnreadable(path: root, detail: "Legacy gitlink resolution is unavailable.")
        }

        func probeUsability() -> GitUsability { .usable }
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
        func remoteReferences(remote: String, credential: GitCredential?) throws -> GitRemoteReferences {
            GitRemoteReferences(defaultBranch: nil, heads: [])
        }
    }
}
