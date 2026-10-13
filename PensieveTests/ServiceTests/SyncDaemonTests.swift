import XCTest
@testable import Pensieve

final class SyncDaemonTests: XCTestCase {
    private var tempDir: String!
    private var root: String!
    private var appSupport: String!
    private var git: RecordingFFGit!
    private var credentials: InMemoryCredentialStore!
    private var reconciler: RecordingReconciler!
    private let clock: () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

    override func setUpWithError() throws {
        try NativeTestWork.run { [self] in
            tempDir = TestTemporaryDirectory.path + "PensieveSyncDaemonTests-\(UUID().uuidString)"
            root = tempDir + "/store"
            appSupport = tempDir + "/app-support"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
            git = RecordingFFGit()
            credentials = InMemoryCredentialStore()
            reconciler = RecordingReconciler()
        }
    }

    override func tearDownWithError() throws {
        try NativeTestWork.run { [self] in
            if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
                try FileManager.default.removeItem(atPath: tempDir)
            }
        }
    }

    func testLockedSkipsWithoutWritingStatusOrReconciling() throws {
        try NativeTestWork.run { [self] in
            let held = SyncLock.tryAcquire(at: appSupport + "/sync.lock")
            XCTAssertNotNil(held)
            defer { held?.release() }

            XCTAssertEqual(makeDaemon().runOnce(), .skipped(.locked))
            XCTAssertEqual(reconciler.calls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport + "/daemon-status.json"))
        }
    }

    func testNoRemoteSkipsWithoutReconciling() throws {
        try NativeTestWork.run { [self] in
            git.remote = nil

            XCTAssertEqual(makeDaemon().runOnce(), .skipped(.noRemote))
            XCTAssertEqual(reconciler.calls, 0)
        }
    }

    func testRejectedRemoteSkipsWithoutReconciling() throws {
        try NativeTestWork.run { [self] in
            git.remote = "ext::sh -c touch /tmp/x"

            XCTAssertEqual(makeDaemon().runOnce(), .skipped(.rejectedRemote))
            XCTAssertEqual(reconciler.calls, 0)
        }
    }

    func testDirtyTreeSkipsWithoutReconciling() throws {
        try NativeTestWork.run { [self] in
            git.clean = false

            XCTAssertEqual(makeDaemon().runOnce(), .skipped(.dirtyTree))
            XCTAssertEqual(reconciler.calls, 0)
        }
    }

    func testDivergedSkipsWithoutReconciling() throws {
        try NativeTestWork.run { [self] in
            git.ffResult = .diverged

            XCTAssertEqual(makeDaemon().runOnce(), .skipped(.diverged))
            XCTAssertEqual(reconciler.calls, 0)
        }
    }

    func testUpToDateSyncsAndReconciles() throws {
        try NativeTestWork.run { [self] in
            git.ffResult = .upToDate

            XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: false))
            XCTAssertEqual(reconciler.calls, 1)
        }
    }

    func testFastForwardedSyncsAndReconciles() throws {
        try NativeTestWork.run { [self] in
            git.ffResult = .fastForwarded(from: "a", to: "b")

            XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: true))
            XCTAssertEqual(reconciler.calls, 1)
        }
    }

    func testAuthFailureFailsWithoutReconciling() throws {
        try NativeTestWork.run { [self] in
            git.throwAuth = true
            for entry in [
                ("https://github.com/acme/store.git", "Sync over HTTPS needs an access token. Add one in Settings › Sync."),
                ("git@github.com:acme/store.git", "Couldn’t authenticate to github.com over SSH. Add your key to the agent "
                    + "(run ssh-add in Terminal), then sync again.")
            ] {
                git.remote = entry.0
                XCTAssertEqual(makeDaemon().runOnce(), .failed(.authentication(entry.1)))
                XCTAssertEqual(reconciler.calls, 0)
                let status = try JSONDecoder().decode(DaemonStatus.self,
                    from: FileService().readData(at: appSupport + "/daemon-status.json"))
                XCTAssertEqual(status.detail, entry.1)
                XCTAssertTrue(try FileService().readFile(at: appSupport + "/daemon.log").contains(entry.1))
            }
            git.remote = "https://github.com/acme/store.git"
            try credentials.store(token: "expired", username: "kept", forHost: "github.com")
            XCTAssertEqual(makeDaemon().runOnce(), .failed(.authentication(
                "github.com didn’t accept the access token. Replace it in Settings › Sync.")))
            git.remote = "git@example.com:store.git"
            git.authDetail = "Host key verification failed."
            let hostKeyAdvice = "Connect to example.com once with ssh in Terminal to check and accept its key, then sync again."
            XCTAssertEqual(makeDaemon().runOnce(), .failed(.authentication(hostKeyAdvice)))
            let status = try JSONDecoder().decode(DaemonStatus.self,
                from: FileService().readData(at: appSupport + "/daemon-status.json"))
            XCTAssertEqual(status.detail, hostKeyAdvice)
        }
    }

    func testAtomicStatusReplacesPartialFileWithValidJSON() throws {
        try NativeTestWork.run { [self] in
            try Data("partial".utf8).write(to: URL(fileURLWithPath: appSupport + "/daemon-status.json"))
            git.ffResult = .upToDate

            XCTAssertEqual(makeDaemon().runOnce(), .synced(changed: false))

            let data = try Data(contentsOf: URL(fileURLWithPath: appSupport + "/daemon-status.json"))
            let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
            XCTAssertEqual(status.result, "synced")
            XCTAssertEqual(status.detail, "upToDate")
        }
    }

    func testLogRotationMovesOversizedLogAndWritesNewLine() throws {
        try NativeTestWork.run { [self] in
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
    }

    private func makeDaemon() -> SyncDaemon {
        SyncDaemon(
            root: root,
            appSupport: appSupport,
            git: git,
            hasLocalBranches: { _ in true },
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
    var authDetail = "auth"
    var throwOther = false
    func remoteURL(at path: String) -> String? { remote }
    func isWorktreeClean(at path: String) -> Bool { clean }
    func fetch(at path: String, credential: GitCredential?) throws {}
    func fastForwardOnly(at path: String, credential: GitCredential?) throws -> FastForwardResult {
        if throwAuth { throw GitError.authenticationFailed(remote: remote ?? "origin", detail: authDetail) }
        if throwOther { throw GitError.commandFailed(args: ["merge"], exitCode: 1, stderr: "boom") }
        return ffResult
    }

    func probeUsability() -> GitUsability { .usable }
}

private final class RecordingReconciler: DeployReconciling {
    private(set) var calls = 0
    func reconcile(root: String) throws -> ReconcileOutcome { calls += 1; return ReconcileOutcome() }
}
