import Darwin
import SwiftData
import XCTest
@testable import Pensieve

/// Holds a real child at the git runner boundary. The script announces readiness without
/// writing to its pipes and exits only when the off-pool watchdog releases it. This exercises
/// the production Process/read/join wait, not a stubbed executor or a canned progress result.
final class GitBlockingFixture {
    enum Finished: Error { case operation }
    let root = TestTemporaryDirectory.path + "GitBlocking-" + UUID().uuidString
    let files = FileService()

    init() throws {
        try files.createDirectory(at: root)
        try files.writeExecutableFile(at: root + "/git", content: """
        #!/bin/sh
        printf '%s' "$$" > '\(root)/ready'
        while [ ! -f '\(root)/release' ]; do /bin/sleep 0.01; done
        printf 'git version fixture\\n'
        """)
    }

    func run() throws {
        let git = GitService(executablePath: root + "/git")
        _ = try git.runData(["--version"], in: nil)
    }

    func runAndFail() throws -> Never {
        try run()
        throw Finished.operation
    }

    var isBlocked: Bool {
        guard let pid = (try? files.readFile(at: root + "/ready")).flatMap({ pid_t($0) }) else { return false }
        return kill(pid, 0) == 0
    }

    func release() { try? files.writeFile(at: root + "/release", content: "release") }
    func cleanup() throws { try files.deleteDirectory(at: root) }

    /// Readiness and the heartbeat deadline are judged by a native thread. Even a completely
    /// starved cooperative priority bucket cannot make this watchdog or its release stop.
    struct Progress { let blocked: Bool; let completed: Bool }

    @MainActor
    func progress(priority: TaskPriority) async -> Progress {
        await withCheckedContinuation { continuation in
            Thread {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while !self.isBlocked && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                let heartbeat = DispatchGroup()
                let blocked = self.isBlocked
                if blocked {
                    // Include the requested bucket and both possible inherited/default buckets.
                    // Awaiting a utility task can boost it, so no different-QoS heartbeat is accepted as proof.
                    for bucket in [priority, .utility, .medium, .userInitiated] {
                        heartbeat.enter()
                        Task.detached(priority: bucket) { heartbeat.leave() }
                    }
                }
                let judged = heartbeat.wait(timeout: .now() + 3) // upper-bound: Detect strict-pool starvation, then release git.
                let progressed = blocked && judged == .success
                self.release()
                continuation.resume(returning: Progress(blocked: blocked, completed: progressed))
            }.start()
        }
    }
}

/// Uses the real git runner in the selected install operation. Preparation returns a candidate
/// only to admit the view model's install/adoption route; that route's work always runs git.
final class PoolInstallService: SkillInstallServiceProtocol {
    let block: GitBlockingFixture
    var blockFetch = false
    let candidate = SkillCandidate(path: "skills/sample", slug: "sample", name: "Sample",
        skillDescription: "Sample", treeHash: "tree", containsSymlink: false, unavailableReason: nil)
    init(_ block: GitBlockingFixture) { self.block = block }

    func fetch(repo: String, ref: String?, credential: GitCredential?) throws -> SkillFetchResult {
        if blockFetch { try block.runAndFail() }
        return SkillFetchResult(repo: repo, ref: ref ?? "main", headCommit: "head", candidates: [candidate])
    }
    func fetch(repo: String, ref: String?, path: String, credential: GitCredential?) throws -> SkillFetchResult {
        try fetch(repo: repo, ref: ref, credential: credential)
    }
    func install(candidate: SkillCandidate, from source: SkillFetchResult, credential: GitCredential?,
                 bodyWriteRegistration: SyncBodyWriteRegistration, context: ModelContext) throws -> SkillInstallResult {
        try block.runAndFail()
    }
    func install(candidate: SkillCandidate, renamedTo slug: String, from source: SkillFetchResult,
                 credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration,
                 context: ModelContext) throws -> SkillInstallResult {
        try block.runAndFail()
    }
    func adopt(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
               credential: GitCredential?, context: ModelContext) throws -> SkillAdoptResult {
        try block.runAndFail()
    }
    func update(existingSlug: String, candidate: SkillCandidate, from source: SkillFetchResult,
                credential: GitCredential?, bodyWriteRegistration: SyncBodyWriteRegistration, context: ModelContext) throws {
        try block.runAndFail()
    }
}

struct PoolSyncEngine: SyncEngineProtocol {
    let block: GitBlockingFixture
    func sync(root: String, message: String, credential: GitCredential?, context: ModelContext,
              prepare: ((ModelContext) throws -> Void)?) throws -> SyncOutcome { try block.runAndFail() }
    func inspectConflicts(root: String, credential: GitCredential?, context: ModelContext) throws -> ConflictInspection {
        try block.runAndFail()
    }
    func resolveConflicts(root: String, picks: [String: ResolutionPick], credential: GitCredential?,
                          context: ModelContext) throws -> SyncOutcome { try block.runAndFail() }
}
