import Darwin
import XCTest
@testable import Pensieve

final class StoreTemporaryFolderTests: XCTestCase {
    private let files = FileService()
    private var root: String!
    private var namespace: String!

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "StoreTemporaryFolders-" + UUID().uuidString
        try files.createDirectory(at: root)
        // Assert against the real allocator's parent: the leak lives outside the fixture store.
        namespace = try files.storeTemporaryParent(root: root) + "/.pensieve-store-writes-" + files.storeKey(root: root)
    }

    override func tearDownWithError() throws {
        for path in [namespace!, namespace + "-alternate", legacyNamespace(), root!]
        where try files.entryExistsWithoutFollowingLinks(at: path) {
            try files.deleteDirectory(at: path)
        }
    }

    func testBodySaveRemovesEmptyNamespace() throws {
        let bytes = "---\r\nname: Example\r\n---\r\nBody 🧠\n"
        try store().writeBody(directoryName: "existing", body: bytes)
        XCTAssertEqual(try files.readData(at: destination), Data(bytes.utf8))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: namespace))
    }

    func testNamespaceRemovedBeforeOpenIsRecreated() throws {
        try assertRemovedNamespaceSave(point: "namespace-removed-before-open")
    }

    func testNamespaceRemovedBeforeLockIsRecreated() throws {
        try assertRemovedNamespaceSave(point: "namespace-removed-before-lock")
    }

    func testFailedPublicationRemovesEmptyNamespace() throws {
        try files.createDirectory(at: destination)
        XCTAssertThrowsError(try store().writeBody(directoryName: "existing", body: "new body")) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EISDIR))
            XCTAssertEqual(error.userInfo[NSFilePathErrorKey] as? String, self.destination)
        }
        XCTAssertTrue(files.directoryExists(at: destination))
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: namespace))
    }

    func testForeignPrimaryIsPreservedAndAlternateIsRemoved() throws {
        try files.writeFile(at: namespace, content: "foreign occupant")
        try store().writeBody(directoryName: "existing", body: "saved through alternate")
        XCTAssertEqual(try files.readFile(at: destination), "saved through alternate")
        XCTAssertEqual(try files.readFile(at: namespace), "foreign occupant")
        XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: namespace + "-alternate"))
    }

    func testSweepRemovesEmptyNamespacesAndPreservesUnownedEntries() throws {
        let directories = [namespace!, namespace + "-alternate", legacyNamespace()]
        for directory in directories {
            try files.writeFile(at: directory + "/.pensieve-write-" + UUID().uuidString, content: "abandoned")
        }
        try files.cleanStoreIntermediates(at: root)
        for directory in directories {
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: directory), directory)
        }
        for directory in directories {
            try files.writeFile(at: directory + "/.pensieve-write-not-a-uuid", content: "foreign")
            try files.writeFile(at: directory + "/.pensieve-write-" + UUID().uuidString, content: "abandoned")
        }
        try files.cleanStoreIntermediates(at: root)
        for directory in directories {
            XCTAssertEqual(try files.listDirectory(at: directory), [".pensieve-write-not-a-uuid"])
            XCTAssertEqual(try files.readFile(at: directory + "/.pensieve-write-not-a-uuid"), "foreign")
        }
    }

    private var destination: String { root + "/skills/existing/SKILL.md" }

    private func store() -> SkillStore {
        SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
    }

    private func legacyNamespace() -> String {
        let identity = files.fileIdentity(at: root, followingLinks: true)!
        return (namespace as NSString).deletingLastPathComponent
            + "/.pensieve-store-writes-\(identity.device)-\(identity.inode)"
    }

    private func assertRemovedNamespaceSave(point: String) throws {
        try NativeTestWork.run { [self] in
            try files.writeFile(at: destination, content: "original")
            let probe = try StoreWriteCrashProbe(directory: root + "/probe")
            XCTAssertEqual(try probe.run(root: root, writer: "body", point: point), 0, point)
            XCTAssertEqual(try files.readData(at: destination), Data("rewritten body".utf8))
            XCTAssertFalse(try files.entryExistsWithoutFollowingLinks(at: namespace), point)
            XCTAssertEqual(try files.readFile(at: probe.library + ".removed"), point,
                           "The probe must actually remove the namespace at the requested boundary")
        }
    }
}
