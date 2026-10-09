import XCTest
@testable import Pensieve

final class PathSyntaxTests: XCTestCase {
    func testComponentsAndCanonicalComparisonRetainFilesystemSpelling() {
        for scalar in PathJoiningScalars.values {
            let name = PathJoiningScalars.name("name", scalar: scalar)
            XCTAssertTrue(PathSyntax.isAbsolute("/" + name))
            XCTAssertFalse(PathSyntax.isAbsolute(name))
            XCTAssertTrue(PathSyntax.hasSeparator("parent/" + name))
            XCTAssertFalse(PathSyntax.hasSeparator(name))
            XCTAssertTrue(PathSyntax.startsWithTilde("~" + name))
            XCTAssertEqual(PathSyntax.components("/" + name + "//file", omittingEmptySubsequences: false),
                           ["", name, "", "file"])
            let path = "/cafe\u{0301}/" + name + "/file"
            XCTAssertEqual(PathSyntax.relativePath(path, under: "/caf\u{00E9}"), name + "/file")
            XCTAssertTrue(PathSyntax.hasPrefix(path, "/caf\u{00E9}/"))
            XCTAssertTrue(PathSyntax.hasSuffix(path, "/" + name + "/file"))
            XCTAssertFalse(PathSyntax.hasSuffix(path, "/other/file"))
            XCTAssertFalse(PathSyntax.isWithin("/caf\u{00E9}-other/" + name, root: "/caf\u{00E9}"))
            XCTAssertEqual(PathSyntax.relativePath("/" + name, under: "/"), name)
            XCTAssertEqual(PathSyntax.relativePath(name + "/file", under: name), "file")
        }
        XCTAssertNil(PathSyntax.relativePath("", under: "/"))
        XCTAssertFalse(PathSyntax.isWithin("", root: "/"))
        XCTAssertNil(PathSyntax.relativePath("file", under: ""))
        XCTAssertFalse(PathSyntax.isWithin("/root", root: "/root", includingRoot: false))
        XCTAssertTrue(PathSyntax.isWithin("/root", root: "/root"))
        XCTAssertEqual(PathSyntax.relativePath("/root/file", under: "/root/"), "file")
    }
}
