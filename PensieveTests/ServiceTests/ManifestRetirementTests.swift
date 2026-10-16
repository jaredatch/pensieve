import XCTest
@testable import Pensieve

final class ManifestRetirementTests: XCTestCase {
    var root: String!
    let files = FileService()
    var manifest: ManifestService { ManifestService(fileService: files) }
    var empty: ManifestSnapshot { ManifestSnapshot(schemaVersion: 5, categories: [], projects: [], skills: []) }

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ManifestRetirement-" + UUID().uuidString
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws { try files.deleteDirectory(at: root) }

    func testLegacyEntriesDisappearWithoutChangingOtherManifestFiles() throws {
        var snapshot = sampleManifestSnapshot()
        snapshot.deployIntents = [DeployIntentRecord(machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                                                     skillSlug: "plain", platformRaw: "codex", projectKey: nil)]
        let clean = root + "/clean"
        try manifest.write(snapshot, toRoot: clean)
        let expected = try treeBytes(at: clean + "/manifest")
        let dirty = root + "/dirty"
        try manifest.write(empty, toRoot: dirty)
        let legacy = dirty + "/manifest/scenarios"
        try files.writeFile(at: legacy + "/old.yaml", content: "name: Legacy\n")
        try files.writeFile(at: legacy + "/broken.yaml", content: ":\n  - [\n")
        try files.writeData(at: legacy + "/opaque.bin", data: Data([0, 255]))
        let outside = root + "/outside"
        try files.writeFile(at: outside, content: "untouched")
        try files.createSymlink(at: legacy + "/link", pointingTo: outside)
        try files.writeFile(at: legacy + "/nested/child", content: "retired")

        XCTAssertNoThrow(try manifest.read(fromRoot: dirty))
        try manifest.write(snapshot, toRoot: dirty)

        XCTAssertFalse(files.directoryExists(at: clean + "/manifest/scenarios"))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: legacy))
        XCTAssertEqual(try treeBytes(at: dirty + "/manifest"), expected)
        XCTAssertEqual(try files.readFile(at: outside), "untouched")
    }

    func testLegacyDirectoryLinkIsDiscardedWithoutChangingItsTarget() throws {
        let outside = root + "/outside"
        try files.writeFile(at: outside + "/keep", content: "untouched")
        try manifest.write(empty, toRoot: root)
        let legacy = root + "/manifest/scenarios"
        if files.directoryExists(at: legacy) { try files.deleteDirectory(at: legacy) }
        try files.createSymlink(at: legacy, pointingTo: outside)
        try manifest.write(empty, toRoot: root)
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: legacy))
        XCTAssertEqual(try files.readFile(at: outside + "/keep"), "untouched")
    }

    func testWriteRefusesNewerAndDamagedTreesUntilExplicitRepair() throws {
        try files.writeFile(at: root + "/manifest/manifest.yaml", content: "schema_version: 6\n")
        try files.writeFile(at: root + "/manifest/scenarios/keep.yaml", content: "keep: bytes\n")
        let before = try treeBytes(at: root + "/manifest")
        XCTAssertThrowsError(try manifest.write(empty, toRoot: root)) {
            XCTAssertEqual($0 as? ManifestError, .unsupportedSchema(found: 6, supported: 5))
        }
        XCTAssertEqual(try treeBytes(at: root + "/manifest"), before)
        try files.writeFile(at: root + "/manifest/manifest.yaml", content: "schema_version: nope\n")
        let damaged = try treeBytes(at: root + "/manifest")
        XCTAssertThrowsError(try manifest.write(empty, toRoot: root)) {
            XCTAssertEqual($0 as? ManifestError, .damaged)
        }
        XCTAssertEqual(try treeBytes(at: root + "/manifest"), damaged)
        let token = ManifestDamage.capture(root: root, files: files)
        XCTAssertTrue(try manifest.repair(empty, root: root, replacing: token))
        XCTAssertEqual(try manifest.read(fromRoot: root), empty)
        XCTAssertFalse(files.directoryExists(at: root + "/manifest/scenarios"))
    }

    func testV1TreeWithoutScenariosRemainsReadable() throws {
        try files.writeFile(at: root + "/manifest/manifest.yaml", content: "schema_version: 1\n")
        let read = try manifest.read(fromRoot: root)
        XCTAssertEqual(read.schemaVersion, 1)
        XCTAssertTrue(read.skills.isEmpty)
    }

    func testWrittenTreeDeclaresSchemaVersion5() throws {
        try manifest.write(empty, toRoot: root)
        XCTAssertEqual(try files.readFile(at: root + "/manifest/manifest.yaml"), "schema_version: 5\n")
    }

    func treeBytes(at directory: String) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try files.listDirectory(at: directory) {
            let path = directory + "/" + name
            if files.directoryExists(at: path) {
                for (child, bytes) in try treeBytes(at: path) { result[name + "/" + child] = bytes }
            } else { result[name] = try files.readData(at: path) }
        }
        return result
    }
}
