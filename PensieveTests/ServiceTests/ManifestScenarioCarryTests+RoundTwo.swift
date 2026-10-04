import Darwin
import XCTest
@testable import Pensieve

extension ManifestScenarioCarryTests {
    func testArchitectureDescribesCarryMetadataInvalidation() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let architecture = try String(contentsOf: sourceRoot.appendingPathComponent("docs/ARCHITECTURE.md"), encoding: .utf8)
        XCTAssertFalse(architecture.contains("Link counts are excluded."))
        for comparison in ["inode", "size", "modification time", "ctime"] {
            XCTAssertTrue(architecture.contains(comparison), comparison)
        }
        XCTAssertTrue(architecture.contains("A hard link changes ctime"))
        XCTAssertTrue(architecture.contains("the next manifest write carries the unchanged bytes successfully"))
    }

    func testHarmlessFileAndFolderMetadataChangesDoNotRejectManifestWrite() throws {
        for kind in ["file-xattr", "file-mode", "hard-link", "folder-xattr", "folder-mode"] {
            let source = root + "/manifest/scenarios"
            let path = source + "/legacy.yaml"
            try files.writeFile(at: path, content: "unchanged bytes")
            let initial = files.regularFileMetadata(at: path)
            let guarded = ScenarioCarryFileService()
            var fired = false
            let change = {
                guard !fired else { return }
                fired = true
                switch kind {
                case "hard-link":
                    try FileManager.default.linkItem(atPath: path, toPath: self.root + "/extra-link")
                case "file-mode", "folder-mode":
                    XCTAssertEqual(chmod(kind == "file-mode" ? path : source, 0o700), 0)
                default:
                    let target = kind == "file-xattr" ? path : source
                    let bytes = Array("metadata".utf8)
                    XCTAssertEqual(bytes.withUnsafeBytes {
                        setxattr(target, "com.pensieve.test", $0.baseAddress, $0.count, 0, 0)
                    }, 0)
                }
            }
            if kind.hasPrefix("folder") { guarded.beforeSwap = change } else {
                guarded.checkpointAction = { point in
                    if case .copiedChunk = point { try change() }
                }
            }
            var changed = empty
            changed.categories = [CategoryRecord(name: kind, projectKeys: [], skillSlugs: [])]
            let before = try treeBytes(at: root + "/manifest")
            XCTAssertThrowsError(try ManifestService(fileService: guarded).write(changed, toRoot: root), kind)
            XCTAssertTrue(fired, kind)
            XCTAssertEqual(try treeBytes(at: root + "/manifest"), before, kind)
            try manifest.write(changed, toRoot: root)
            XCTAssertEqual(try manifest.read(fromRoot: root).categories, changed.categories, kind)
            XCTAssertEqual(try files.readFile(at: path), "unchanged bytes", kind)
            if kind == "hard-link" { try files.deleteFile(at: root + "/extra-link") }
            // Atomic carry may choose a fresh mtime, but the source's bytes/size were unchanged at validation.
            XCTAssertEqual(files.regularFileMetadata(at: path)?.byteCount, initial?.byteCount)
        }
    }
}
