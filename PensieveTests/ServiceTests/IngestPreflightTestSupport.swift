import Foundation
import SwiftData
import XCTest
@testable import Pensieve

enum IngestPreflightBoom: Error {
    case expected
}

final class IngestRecordingGit: GitServiceProtocol {
    var remote: String? = "https://fixture.test/repo.git"
    var remoteRead: (() throws -> String?)?
    var calls: [String] = []

    func remoteURL(at path: String) throws -> String? {
        if let remoteRead { return try remoteRead() }
        return remote
    }
    func initRepository(at path: String) throws {}
    func setRemote(_ url: String, at path: String) throws {}
    func removeRemote(at path: String) throws {}
    func configuredRemoteURL(at path: String) throws -> String? { nil }
    func clone(remote: String, into path: String, credential: GitCredential?) throws {}
    func remoteHasCommits(remote: String, credential: GitCredential?) -> Bool { true }
    func stageAllAndCommit(at path: String, message: String) throws -> Bool {
        calls.append("commit")
        return false
    }
    func preflightStoreUpdate(at path: String, credential: GitCredential?) -> FetchedStoreRevision? { nil }
    func pullRebase(at path: String, fetchedRevision: FetchedStoreRevision) throws -> PullResult {
        try pullRebase(at: path, credential: nil)
    }
    func pullRebase(at path: String, credential: GitCredential?) throws -> PullResult {
        calls.append("pull")
        return .upToDate
    }
    func push(at path: String, credential: GitCredential?) throws { calls.append("push") }
    func abortRebase(at path: String) throws { calls.append("abort") }
    func conflictedFiles(at path: String) -> [String] { [] }
    func blob(atStage stage: Int, path: String, in workingDir: String) -> Data? { nil }
    func continueRebase(at path: String) throws -> PullResult { .upToDate }
    func skipRebase(at path: String) throws -> PullResult { .upToDate }
    func stagePath(_ path: String, at root: String) throws {}
    func collapseToSingleCommit(at root: String, message: String,
                                credential: GitCredential?, fetchedRevision: FetchedStoreRevision?) throws -> Bool { false }
    func hasCommitsToPush(at path: String) -> Bool { false }
}

final class IngestRecordingManifest: ManifestSnapshotting {
    var events: [String] = []
    var readError: Error?

    func write(_ snapshot: ManifestSnapshot, toRoot root: String) throws {
        events.append("write")
    }

    func read(fromRoot root: String) throws -> ManifestSnapshot {
        events.append("read")
        if let readError { throw readError }
        return ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: [], projects: [], skills: []
        )
    }

    func snapshot(from context: ModelContext) throws -> ManifestSnapshot {
        events.append("snapshot")
        return ManifestSnapshot(
            schemaVersion: ManifestService.currentSchemaVersion,
            categories: [], projects: [], skills: []
        )
    }
}

struct IngestNoopRebuild: StoreRebuildServiceProtocol {
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult { RebuildResult() }
}

final class IngestRecordingRebuild: StoreRebuildServiceProtocol {
    private(set) var calls = 0

    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        calls += 1
        return RebuildResult()
    }
}

struct IngestEmptyCredentials: CredentialStoreProtocol {
    func credential(forHost host: String) -> GitCredential? { nil }
    func store(token: String, username: String, forHost host: String) throws {}
    func delete(forHost host: String) throws {}
}

struct IngestNullAudit: SyncAuditWriting {
    func record(category: String, detail: String) {}
}

struct IngestNoopDeploy: DeployReconciling {
    func reconcile(root: String) throws -> ReconcileOutcome { ReconcileOutcome() }
}

final class IngestAllowlistedFastForwardGit: FastForwardGitService {
    private let git: GitService

    init(git: GitService) {
        self.git = git
    }

    func remoteURL(at path: String) throws -> String? {
        try git.remoteURL(at: path) == nil ? nil : "https://fixture.test/repo.git"
    }
    func isWorktreeClean(at path: String) -> Bool { git.isWorktreeClean(at: path) }
    func fetch(at path: String, credential: GitCredential?) throws {
        try git.fetch(at: path, credential: credential)
    }
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        try git.fastForwardOnly(at: path, credential: credential)
    }
}

func ingestRawGit(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        XCTFail("git failed: \(arguments.joined(separator: " "))\n\(output)")
        throw IngestPreflightBoom.expected
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}
