import XCTest
@testable import Pensieve

final class SkillStoreRenameTests: XCTestCase {
    func testRenameSkillMovesAtomicallyAndRefusesEveryOccupant() throws {
        let files = FileService()
        let root = TestTemporaryDirectory.path + "StoreRename-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: root) }
        let store = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
        _ = try store.createSkill(name: "alpha", description: "job", body: "body")
        let original = try store.readData(directoryName: "alpha")
        let script = Data([0, 255, 10, 42])
        try files.writeData(at: root + "/skills/alpha/scripts/run.sh", data: script)
        try store.renameSkill(directoryName: "alpha", to: "beta-two")
        XCTAssertEqual(try store.listSkills(), ["beta-two"])
        XCTAssertEqual(try store.readData(directoryName: "beta-two"), original)
        XCTAssertEqual(try store.readBody(directoryName: "beta-two"), String(data: original, encoding: .utf8))
        XCTAssertEqual(try files.readData(at: root + "/skills/beta-two/scripts/run.sh"), script)
        XCTAssertFalse(files.directoryExists(at: root + "/skills/alpha"))
        try store.renameSkill(directoryName: "beta-two", to: "alpha")
        for kind in ["file", "link", "folder", "case"] {
            let occupant = root + "/skills/" + (kind == "case" ? "BETA-TWO" : "beta-two")
            switch kind {
            case "file": try files.writeData(at: occupant, data: script)
            case "link": try files.createSymlink(at: occupant, pointingTo: root + "/missing")
            default: try files.createDirectory(at: occupant)
            }
            XCTAssertThrowsError(try store.renameSkill(directoryName: "alpha", to: "beta-two"), kind)
            XCTAssertEqual(try store.readData(directoryName: "alpha"), original)
            XCTAssertEqual(try files.readData(at: root + "/skills/alpha/scripts/run.sh"), script)
            XCTAssertTrue(try files.entryExistsWithoutFollowingLinks(at: occupant))
            if kind == "file" { XCTAssertEqual(try files.readData(at: occupant), script) }
            if kind == "link" { XCTAssertEqual(try files.symlinkTarget(at: occupant), root + "/missing") }
            if kind == "folder" || kind == "case" { XCTAssertEqual(try files.listDirectory(at: occupant), []) }
            if files.isSymlink(at: occupant) || kind == "file" {
                try files.deleteFile(at: occupant)
            } else { try files.deleteDirectory(at: occupant) }
        }
        try files.createSymlink(at: root + "/skills/linked", pointingTo: root + "/skills/alpha")
        XCTAssertThrowsError(try store.renameSkill(directoryName: "linked", to: "beta-two"))
        for destination in ["../escape", "..", "nested/name"] {
            XCTAssertThrowsError(try store.renameSkill(directoryName: "alpha", to: destination))
        }
        XCTAssertThrowsError(try store.renameSkill(directoryName: "missing", to: "beta-two"))
        XCTAssertEqual(try store.readData(directoryName: "alpha"), original)
    }
}
