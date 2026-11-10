import XCTest
@testable import Pensieve

/// The retained daemon command must report metadata failures before checking for local edits.
/// Fetches stay on a local origin; only the policy-facing URL is substituted.
final class SyncDaemonMetadataTests: XCTestCase {
    private var directory: TestStoreDirectory!
    private let files = FileService()
    private let git = TestPaths.git
    private var root: String { directory.storeRoot }
    private var peer: String { directory.root + "/peer" }
    private var support: String { directory.root + "/support" }
    private var info: String { root + "/.git/info" }
    private var skillPath: String { "/skills/example/SKILL.md" }

    override func setUpWithError() throws {
        try NativeTestWork.run { [self] in
            directory = TestStoreDirectory(named: "SyncDaemonMetadata")
            try files.createDirectory(at: peer)
            let bare = directory.root + "/origin.git"
            try git.runOrThrow(["init", "--bare", "--initial-branch=main", bare], in: nil)
            try git.initRepository(at: peer)
            let remote = URL(fileURLWithPath: bare).absoluteString
            try git.setRemote(remote, at: peer)
            try files.writeFile(at: peer + skillPath,
                                content: "---\nname: Example\ndescription: Fixture\n---\nOriginal body\n")
            XCTAssertTrue(try git.stageAllAndCommit(at: peer, message: "seed store"))
            try git.push(at: peer, credential: nil)
            try git.clone(remote: remote, into: root, credential: nil)
            XCTAssertTrue(git.isWorktreeClean(at: root))
        }
    }

    override func tearDownWithError() throws {
        try NativeTestWork.run { [self] in
            if let directory { try files.deleteDirectory(at: directory.root) }
        }
    }

    func testLinkedAttributesFileFailsTheCycleByNameThenSyncsOnceMoved() throws {
        try NativeTestWork.run { [self] in
            let attributes = info + "/attributes"
            let expected = try files.readFile(at: attributes)
            let target = directory.root + "/external-attributes"
            try files.writeFile(at: target, content: expected)
            try files.deleteFile(at: attributes)
            try files.createSymlink(at: attributes, pointingTo: target)
            XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: info + "/pensieve-ignore"), .regular)

            let updated = "---\nname: Example\ndescription: Fixture\n---\nPulled body\n"
            try files.writeFile(at: peer + skillPath, content: updated)
            XCTAssertTrue(try git.stageAllAndCommit(at: peer, message: "remote update"))
            try git.push(at: peer, credential: nil)
            let before = try XCTUnwrap(git.headSHA(at: root))
            let daemon = makeDaemon()

            try assertMetadataFailure(daemon.runOnce(), naming: "attributes")
            XCTAssertEqual(try git.headSHA(at: root), before)
            XCTAssertEqual(try files.readFile(at: target), expected)

            try FileManager.default.moveItem(atPath: attributes, toPath: directory.root + "/attributes.moved")
            try files.writeFile(at: attributes, content: expected)
            XCTAssertEqual(daemon.runOnce(), .synced(changed: true))
            XCTAssertEqual(try git.headSHA(at: root), try git.headSHA(at: peer))
            XCTAssertEqual(try files.readFile(at: root + skillPath), updated)

            try files.writeFile(at: root + "/local-edit.txt", content: "uncommitted\n")
            XCTAssertEqual(daemon.runOnce(), .skipped(.dirtyTree))
        }
    }

    func testReadOnlyMetadataFolderFailsTheCycleNotAsDirty() throws {
        try NativeTestWork.run { [self] in
            XCTAssertEqual(try files.entryTypeWithoutFollowingLinks(at: info + "/attributes"), .regular)
            try files.deleteFile(at: info + "/pensieve-ignore")
            let permissions = try FileManager.default.attributesOfItem(atPath: info)[.posixPermissions]
            let original = try XCTUnwrap(permissions)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: info)
            defer { try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: info) }

            try assertMetadataFailure(makeDaemon().runOnce(), naming: "pensieve-ignore")
            XCTAssertFalse(files.fileExists(at: info + "/pensieve-ignore"))
        }
    }

    private func makeDaemon() -> SyncDaemon {
        SyncDaemon(root: root, appSupport: support,
                   git: AllowlistedFastForwardGit(wrapping: git),
                   hasLocalBranches: { try self.git.hasLocalBranches(at: $0) },
                   credentials: InMemoryCredentialStore(), reconciler: MetadataNoopDeploy(),
                   now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    private func assertMetadataFailure(_ result: DaemonCycleResult, naming name: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        if case let .failed(.preflight(message)) = result {
            XCTAssertTrue(message.contains(name), message, file: file, line: line)
        } else {
            XCTFail("Expected a preflight failure naming \(name), got \(result)", file: file, line: line)
        }
        let status = try JSONDecoder().decode(DaemonStatus.self,
                                             from: files.readData(at: support + "/daemon-status.json"))
        XCTAssertEqual(status.result, "failed", file: file, line: line)
        XCTAssertTrue(status.detail.contains(name), status.detail, file: file, line: line)
        let log = try files.readFile(at: support + "/daemon.log")
        XCTAssertTrue(log.contains(" failed "), log, file: file, line: line)
        XCTAssertTrue(log.contains(name), log, file: file, line: line)
    }
}

private struct MetadataNoopDeploy: DeployReconciling {
    func reconcile(root: String) throws -> ReconcileOutcome { ReconcileOutcome() }
}
