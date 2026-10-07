import XCTest
@testable import Pensieve

final class DeployRemovalServiceTests: XCTestCase {
    private var root = ""
    private let files = FileService()

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "RemovalBatch-\(UUID().uuidString)"
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws { try files.deleteDirectory(at: root) }

    func testRemovalBlockerFencesEveryRetiringAction() throws {
        let state = DeployStateStore(fileService: files, appSupportDir: root + "/support")
        let path = root + "/keep"
        try files.writeFile(at: path, content: "Keep")
        let record = DeployStateRecord(slug: "keep", platform: "claudeCode", scope: "user",
            projectIdentityKey: nil, artifactPath: path, recordedAt: "2026-10-07T00:00:00Z")
        try state.replaceAll([record])
        let actions: [DeployRemovalAction] = [.retireWithoutInspection,
            .inspect(DeployRemovalOperation(fileService: files, path: path, classify: { false })),
            .inspect(DeployRemovalOperation(fileService: files, path: path, classify: { true }))]
        for action in actions {
            try state.replaceAll([record])
            var candidate = DeployRemovalCandidate(key: DeployRemovalKey(slug: "keep", platform: .claudeCode,
                projectPath: nil, artifactPath: path), evidence: [.deployState], action: action)
            candidate.removalBlocker = DeletionTestError()
            let result = DeployRemovalService(stateStore: state).remove([candidate])
            XCTAssertTrue(result.outcomes.first?.failure is DeletionTestError)
            XCTAssertFalse(result.didAttemptDeletion)
            XCTAssertFalse(result.didChangeRecords)
            XCTAssertEqual(try files.readFile(at: path), "Keep")
            XCTAssertEqual(try state.read().records, [record])
        }
    }

    func testArtifactFailuresStaySeparateFromBatchStateFailure() throws {
        let mapped = LinkServiceCanonicalDirectoryFileService(wrapped: files, pathMappings: [], physicalSandbox: root)
        let state = DeployStateStore(fileService: mapped, appSupportDir: root + "/support")
        let skills = root + "/store/skills"
        let paths = ["removed", "foreign", "unreadable", "delete-failed"].map { root + "/agent/" + $0 }
        for (index, path) in paths.enumerated() {
            try files.createSymlink(at: path, pointingTo: index == 1 ? root + "/outside" : skills + "/gone")
        }
        try state.replaceAll(paths.enumerated().map { index, path in
            DeployStateRecord(slug: String(index), platform: "claudeCode", scope: "user",
                projectIdentityKey: nil, artifactPath: path, recordedAt: "2026-10-06T00:00:00Z")
        })
        mapped.beforeSymlinkRead = { path in
            if path == paths[2] { throw DeletionTestError() }
        }
        mapped.beforeArtifactDeletion = { path in
            if path == paths[3] { throw DeletionTestError() }
        }
        var writes = 0
        mapped.beforeDeployStateWrite = { _ in
            writes += 1
            throw DeletionTestError()
        }
        let ownership = DeployArtifactOwnership(fileService: mapped)
        let candidates = paths.enumerated().map { index, path in
            DeployRemovalCandidate(key: DeployRemovalKey(slug: String(index), platform: .claudeCode,
                projectPath: nil, artifactPath: path), evidence: [.selection],
                operation: DeployRemovalOperation(fileService: mapped, path: path) {
                    try ownership.link(at: path, skillsDirectory: skills, linksFile: false).isOwned
                })
        }
        let result = DeployRemovalService(stateStore: state).remove(candidates)
        XCTAssertEqual(result.removed, [candidates[0].key])
        XCTAssertEqual(result.outcomes.filter(\.retired).map(\.key), [candidates[1].key])
        XCTAssertEqual(Set(result.outcomes.filter { $0.failure != nil }.map(\.key)), [candidates[2].key, candidates[3].key])
        XCTAssertTrue(result.outcomes[2].failure is ArtifactOwnershipError)
        XCTAssertTrue(result.outcomes[3].failure is DeletionTestError)
        XCTAssertTrue(result.stateWriteFailure is DeletionTestError)
        XCTAssertFalse(result.didChangeRecords)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(files.isSymlink(at: paths[0]))
        XCTAssertEqual(try files.symlinkTarget(at: paths[1]), root + "/outside")
        for path in paths.dropFirst(2) { XCTAssertTrue(files.isSymlink(at: path)) }
        XCTAssertEqual(try state.read().records.map(\.artifactPath).sorted(), paths.sorted())
    }
}
