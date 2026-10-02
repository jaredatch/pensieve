import XCTest
@testable import Pensieve

final class SyncDaemonTests: XCTestCase {
    private var tempDir: String!
    private var root: String!
    private var appSupport: String!
    private var git: RecordingFFGit!
    private var credentials: NilCredentialStore!
    private var reconciler: RecordingReconciler!
    private let clock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "PensieveSyncDaemonTests-\(UUID().uuidString)"
        root = tempDir + "/store"
        appSupport = tempDir + "/app-support"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        git = RecordingFFGit()
        credentials = NilCredentialStore()
        reconciler = RecordingReconciler()
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testLockedSkipsWithoutWritingStatusOrReconciling() {
        let held = SyncLock.tryAcquire(at: appSupport + "/sync.lock")
        XCTAssertNotNil(held)
        defer { held?.release() }

        XCTAssertEqual(makeDaemon().runOnce(), .skipped(.locked))
        XCTAssertEqual(reconciler.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport + "/daemon-status.json"))
    }

    func testNoRemoteSkipsWithoutReconciling() {
        git.remote = nil

        XCTAssertEqual(makeDaemon().runOnce(), .skipped(.noRemote))
        XCTAssertEqual(reconciler.calls, 0)
    }

    func testRejectedRemoteSkipsWithoutReconciling() {
        git.remote = "ext::sh -c touch /tmp/x"

        XCTAssertEqual(makeDaemon().runOnce(), .skipped(.rejectedRemote))
        XCTAssertEqual(reconciler.calls, 0)
    }

    func testDirtyTreeSkipsWithoutReconciling() {
        git.clean = false

        XCTAssertEqual(makeDaemon().runOnce(), .skipped(.dirtyTree))
        XCTAssertEqual(reconciler.calls, 0)
    }

    func testDivergedSkipsWithoutReconciling() {
        git.ffResult = .diverged

        XCTAssertEqual(makeDaemon().runOnce(), .skipped(.diverged))
        XCTAssertEqual(reconciler.calls, 0)
    }

    func testUpToDateSyncsAndReconciles() {
        git.ffResult = .upToDate

        XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: false))
        XCTAssertEqual(reconciler.calls, 1)
    }

    func testFastForwardedSyncsAndReconciles() {
        git.ffResult = .fastForwarded(from: "a", to: "b")

        XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: true))
        XCTAssertEqual(reconciler.calls, 1)
    }

    func testAuthFailureFailsWithoutReconciling() {
        git.throwAuth = true

        XCTAssertEqual(makeDaemon().runOnce(), .failed(.authentication))
        XCTAssertEqual(reconciler.calls, 0)
    }

    func testAtomicStatusReplacesPartialFileWithValidJSON() throws {
        try Data("partial".utf8).write(to: URL(fileURLWithPath: appSupport + "/daemon-status.json"))
        git.ffResult = .upToDate

        XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: false))

        let data = try Data(contentsOf: URL(fileURLWithPath: appSupport + "/daemon-status.json"))
        let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
        XCTAssertEqual(status.result, "synced")
        XCTAssertEqual(status.detail, "upToDate")
    }

    func testLogRotationMovesOversizedLogAndWritesNewLine() throws {
        let old = String(repeating: "x", count: SyncDaemon.logRotateThreshold + 10)
        try old.write(toFile: appSupport + "/daemon.log", atomically: true, encoding: .utf8)
        git.ffResult = .upToDate

        XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: false))

        XCTAssertTrue(FileManager.default.fileExists(atPath: appSupport + "/daemon.log.1"))
        let rotated = try String(contentsOfFile: appSupport + "/daemon.log.1", encoding: .utf8)
        XCTAssertEqual(rotated, old)
        let newLog = try String(contentsOfFile: appSupport + "/daemon.log", encoding: .utf8)
        XCTAssertLessThan(newLog.utf8.count, SyncDaemon.logRotateThreshold)
        XCTAssertTrue(newLog.contains("synced upToDate"))
    }

    private func makeDaemon() -> SyncDaemon {
        SyncDaemon(
            root: root,
            appSupport: appSupport,
            git: git,
            credentials: credentials,
            reconciler: reconciler,
            now: clock
        )
    }
}

private final class RecordingFFGit: FastForwardGitService {
    var remote: String? = "https://github.com/acme/store.git"
    var clean = true
    var ffResult: FastForwardResult = .upToDate
    var throwAuth = false
    var throwOther = false
    func remoteURL(at path: String) -> String? { remote }
    func isWorktreeClean(at path: String) -> Bool { clean }
    func fetch(at path: String, credential: GitCredential?) throws {}
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        if throwAuth { throw GitError.authenticationFailed(remote: remote ?? "origin", detail: "auth") }
        if throwOther { throw GitError.commandFailed(args: ["merge"], exitCode: 1, stderr: "boom") }
        return ffResult
    }
}

private final class RecordingReconciler: DeployReconciling {
    private(set) var calls = 0
    func reconcile(root: String) throws -> ReconcileOutcome { calls += 1; return ReconcileOutcome() }
}

private final class NilCredentialStore: CredentialStoreProtocol {
    func store(token: String, username: String, forHost host: String) throws {}
    func credential(forHost host: String) -> GitCredential? { nil }
    func delete(forHost host: String) throws {}
}
