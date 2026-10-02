import XCTest
@testable import Pensieve

final class EditorAssetResolverTests: XCTestCase {
    func testInRootRequestResolvesUnderRoot() {
        let root = URL(fileURLWithPath: "/tmp/pensieve-editor-assets", isDirectory: true)
        let resolved = EditorAssetResolver.resolve(root: root, requestPath: "/index.html")

        XCTAssertEqual(resolved?.path, "/tmp/pensieve-editor-assets/index.html")
    }

    func testDeepTraversalIsRefused() {
        let root = URL(fileURLWithPath: "/tmp/pensieve-editor-assets", isDirectory: true)

        XCTAssertNil(EditorAssetResolver.resolve(root: root, requestPath: "/../../../etc/passwd"))
    }

    func testSingleEscapeIsRefused() {
        let root = URL(fileURLWithPath: "/tmp/pensieve-editor-assets", isDirectory: true)

        XCTAssertNil(EditorAssetResolver.resolve(root: root, requestPath: "/../etc/hosts"))
    }

    func testRootRequestResolves() {
        let root = URL(fileURLWithPath: "/tmp/pensieve-editor-assets", isDirectory: true)
        let resolved = EditorAssetResolver.resolve(root: root, requestPath: "/")

        XCTAssertEqual(resolved?.standardizedFileURL.path, root.standardizedFileURL.path)
    }
}
