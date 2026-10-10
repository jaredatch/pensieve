import XCTest
@testable import Pensieve

extension SyncBytePreservationTests {
    func assertNestedRepositoriesStayLocal(store: String, git: GitService, remote: String) throws {
        let tree = try git.runOrThrow(["--git-dir", remote, "ls-tree", "-r", "main"], in: nil)
        XCTAssertFalse(tree.stdout.contains("160000"), "Sync must never publish a gitlink")
        for relative in nestedRoots {
            XCTAssertTrue(files.directoryExists(at: store + "/skills/" + relative + "/.git"))
            XCTAssertFalse(tree.stdout.contains("skills/" + relative), "Nested repositories stay local")
            try git.stagePath("skills/" + relative, at: store)
            XCTAssertEqual(try git.runOrThrow(["-C", store, "ls-files", "--stage", "--", "skills/" + relative],
                in: nil).stdout, "", "Resolving a path must not stage a gitlink")
        }
        XCTAssertFalse(try git.stageAllAndCommit(at: store, message: "nested repos remain local"),
            "A subsequent sync must not attempt an empty commit for omitted repositories")
    }
}
