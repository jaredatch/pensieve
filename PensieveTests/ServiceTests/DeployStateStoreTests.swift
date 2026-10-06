import XCTest
@testable import Pensieve

private final class LockAssertingFileService: FileServiceProtocol {
    struct MissingLock: Error {}

    private let wrapped = FileService()
    private let lockPath: String
    private let statePath: String

    init(lockPath: String, statePath: String) {
        self.lockPath = lockPath
        self.statePath = statePath
    }

    func writeFile(at path: String, content: String) throws {
        if path == statePath {
            let probe = SyncLock.tryAcquire(at: lockPath)
            defer { probe?.release() }
            if probe != nil { throw MissingLock() }
        }
        try wrapped.writeFile(at: path, content: content)
    }

    func readFile(at path: String) throws -> String { try wrapped.readFile(at: path) }
    func deleteFile(at path: String) throws { try wrapped.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { wrapped.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { wrapped.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { wrapped.directoryExists(at: path) }
    func createDirectory(at path: String) throws { try wrapped.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try wrapped.deleteDirectory(at: path) }
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        try wrapped.createSymlink(at: linkPath, pointingTo: targetPath)
    }
    func symlinkTarget(at path: String) throws -> String { try wrapped.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { wrapped.isSymlink(at: path) }
    func listDirectory(at path: String) throws -> [String] { try wrapped.listDirectory(at: path) }
    func contentsHash(at path: String) throws -> String { try wrapped.contentsHash(at: path) }
}

final class DeployStateStoreTests: XCTestCase {
    private var tempDir: String!
    private var fileService: FileService!
    private var store: DeployStateStore!

    private var statePath: String { tempDir + "/deploy-state.json" }
    private var lockPath: String { tempDir + "/deploy-state.lock" }

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveDeployStateStoreTests-\(UUID().uuidString)"
        fileService = FileService()
        store = DeployStateStore(fileService: fileService, appSupportDir: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testReadMissingReturnsEmptyCurrentSchemaState() throws {
        let state = try store.read()
        XCTAssertEqual(state, DeployState(schemaVersion: DeployStateStore.currentSchemaVersion, records: []))
    }

    func testUpsertNewCreatesFileAndRoundTrips() throws {
        let record = sampleRecord(slug: "alpha", artifactPath: "/tmp/alpha")
        try store.upsert(record)

        XCTAssertTrue(fileService.fileExists(at: statePath))
        XCTAssertEqual(try store.read(), DeployState(schemaVersion: 1, records: [record]))
    }

    func testUpsertExistingArtifactPathReplacesWithoutDuplicate() throws {
        let first = sampleRecord(slug: "alpha", artifactPath: "/tmp/shared", recordedAt: "2026-07-17T00:00:00Z")
        let second = sampleRecord(slug: "beta", artifactPath: "/tmp/shared", recordedAt: "2026-07-17T00:00:01Z")

        try store.upsert(first)
        try store.upsert(second)

        XCTAssertEqual(try store.read().records, [second])
    }

    func testRemoveDeletesMatchingArtifactPathAndAbsentKeyIsNoOp() throws {
        let keep = sampleRecord(slug: "keep", artifactPath: "/tmp/keep")
        let drop = sampleRecord(slug: "drop", artifactPath: "/tmp/drop")
        try store.replaceAll([drop, keep])

        try store.remove(artifactPath: "/tmp/drop")
        try store.remove(artifactPath: "/tmp/missing")

        XCTAssertEqual(try store.read().records, [keep])
    }

    func testRemoveAgainstMissingFileDoesNotCreateState() throws {
        try store.remove(artifactPath: "/tmp/missing")

        XCTAssertFalse(fileService.fileExists(at: statePath))
        XCTAssertEqual(try store.read().records, [])
    }

    func testReadCorruptThrowsUnreadable() throws {
        try fileService.writeFile(at: statePath, content: "not json")

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DeployStateError, .unreadable(statePath))
        }
    }

    func testReadNonUTF8ThrowsUnreadable() throws {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: statePath))

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DeployStateError, .unreadable(statePath))
        }
    }

    func testReadNewerSchemaThrowsUnsupportedSchema() throws {
        try fileService.writeFile(at: statePath, content: #"{"records":[],"schema_version":2}"#)

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DeployStateError, .unsupportedSchema(2))
        }
    }

    func testUpsertAgainstNewerSchemaThrowsAndLeavesBytesUntouched() throws {
        let original = #"{"records":[],"schema_version":2}"#
        try fileService.writeFile(at: statePath, content: original)

        XCTAssertThrowsError(try store.upsert(sampleRecord(slug: "alpha", artifactPath: "/tmp/alpha"))) { error in
            XCTAssertEqual(error as? DeployStateError, .unsupportedSchema(2))
        }
        XCTAssertEqual(try fileService.readFile(at: statePath), original)
    }

    func testUpsertAndRemoveAgainstCorruptFileThrowUnreadableAndLeaveBytesUntouched() throws {
        let original = "not json"
        try fileService.writeFile(at: statePath, content: original)

        XCTAssertThrowsError(try store.upsert(sampleRecord(slug: "alpha", artifactPath: "/tmp/alpha"))) { error in
            XCTAssertEqual(error as? DeployStateError, .unreadable(statePath))
        }
        XCTAssertEqual(try fileService.readFile(at: statePath), original)

        XCTAssertThrowsError(try store.remove(artifactPath: "/tmp/alpha")) { error in
            XCTAssertEqual(error as? DeployStateError, .unreadable(statePath))
        }
        XCTAssertEqual(try fileService.readFile(at: statePath), original)
    }

    func testReplaceAllMayOverwriteCorruptFileButNotNewerSchema() throws {
        let record = sampleRecord(slug: "alpha", artifactPath: "/tmp/alpha")
        try fileService.writeFile(at: statePath, content: "not json")
        try store.replaceAll([record])
        XCTAssertEqual(try store.read().records, [record])

        let newer = #"{"records":[],"schema_version":2}"#
        try fileService.writeFile(at: statePath, content: newer)
        XCTAssertThrowsError(try store.replaceAll([])) { error in
            XCTAssertEqual(error as? DeployStateError, .unsupportedSchema(2))
        }
        XCTAssertEqual(try fileService.readFile(at: statePath), newer)

        let futureShape = #"{"records":{"future":"shape"},"schema_version":2}"#
        try fileService.writeFile(at: statePath, content: futureShape)
        XCTAssertThrowsError(try store.replaceAll([])) { error in
            XCTAssertEqual(error as? DeployStateError, .unsupportedSchema(2))
        }
        XCTAssertEqual(try fileService.readFile(at: statePath), futureShape)
    }

    func testOverflowingSchemaVersionIsUnsupportedNotUnreadableAndReplaceAllRefuses() throws {
        // A numeric schema_version too large for Int must classify as a FUTURE schema, not corrupt
        // bytes — otherwise the replaceAll healer would overwrite a newer-schema file, violating the
        // frozen never-downgrade rule (PLAN-16 / 16.1 Layer-2 P2).
        let overflow = #"{"records":[],"schema_version":99999999999999999999999999}"#
        try fileService.writeFile(at: statePath, content: overflow)

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DeployStateError, .unsupportedSchema(Int.max))
        }
        XCTAssertThrowsError(try store.replaceAll([])) { error in
            XCTAssertEqual(error as? DeployStateError, .unsupportedSchema(Int.max))
        }
        XCTAssertEqual(try fileService.readFile(at: statePath), overflow)
    }

    func testEncodingIsDeterministicAndSortedByArtifactPath() throws {
        let zed = sampleRecord(slug: "zed", artifactPath: "/tmp/z")
        let alpha = sampleRecord(slug: "alpha", artifactPath: "/tmp/a")

        try store.replaceAll([zed, alpha])
        let firstBytes = try fileService.readFile(at: statePath)
        try store.replaceAll([zed, alpha])
        let secondBytes = try fileService.readFile(at: statePath)

        XCTAssertEqual(firstBytes, secondBytes)
        let readable = firstBytes.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertLessThan(
            try XCTUnwrap(readable.range(of: #""artifact_path" : "/tmp/a""#)?.lowerBound),
            try XCTUnwrap(readable.range(of: #""artifact_path" : "/tmp/z""#)?.lowerBound)
        )
        XCTAssertTrue(firstBytes.contains(#""schema_version" : 1"#))
    }

    func testConcurrentUpsertsSerializeThroughLockWithoutLostUpdates() throws {
        let queue = DispatchQueue(label: "DeployStateStoreTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let count = 20
        var errors: [Error] = []
        let errorsLock = NSLock()

        for index in 0..<count {
            group.enter()
            queue.async {
                do {
                    try self.store.upsert(
                        self.sampleRecord(slug: "skill-\(index)", artifactPath: "/tmp/artifact-\(index)")
                    )
                } catch {
                    errorsLock.lock()
                    errors.append(error)
                    errorsLock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.isEmpty, "unexpected upsert errors: \(errors)")
        XCTAssertEqual(try store.read().records.map { $0.artifactPath },
                       (0..<count).map { "/tmp/artifact-\($0)" }.sorted())
    }

    func testMutationHoldsDeployStateLockWhileWriting() throws {
        let lockAsserting = LockAssertingFileService(lockPath: lockPath, statePath: statePath)
        let lockCheckedStore = DeployStateStore(fileService: lockAsserting, appSupportDir: tempDir)

        try lockCheckedStore.upsert(sampleRecord(slug: "locked", artifactPath: "/tmp/locked"))

        XCTAssertTrue(fileService.fileExists(at: lockPath), "mutation must create deploy-state.lock")
    }

    private func sampleRecord(
        slug: String,
        artifactPath: String,
        recordedAt: String = "2026-07-17T12:00:00Z"
    ) -> DeployStateRecord {
        DeployStateRecord(
            slug: slug,
            platform: "cursor",
            scope: "user",
            projectIdentityKey: nil,
            artifactPath: artifactPath,
            recordedAt: recordedAt
        )
    }
}
