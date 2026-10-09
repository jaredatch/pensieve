import Foundation
import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    func writeSyncControlFiles(at root: String) throws {
        let attrs = "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
        try attrs.write(toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
        try ".DS_Store\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    }

    func assertConflictIndexRemovalDefault(_ unmodeled: GitServiceProtocol, at root: String) {
        XCTAssertThrowsError(try unmodeled.removeConflictEntryFromIndex("skills/x/SKILL.md", at: root)) {
            guard case let GitError.repositoryUnreadable(path, detail) = $0 else {
                return XCTFail("Unmodeled index removal must report repositoryUnreadable: \($0)")
            }
            XCTAssertEqual(path, root)
            XCTAssertEqual(detail, "Conflict index removal is unavailable.")
        }
    }

}
