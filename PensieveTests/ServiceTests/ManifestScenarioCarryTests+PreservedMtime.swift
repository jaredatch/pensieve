import Darwin
import XCTest
@testable import Pensieve

extension ManifestScenarioCarryTests {
    func testSameSizeInPlaceRewriteWithPreservedMtimeFailsCarryThenRetries() throws {
        let path = root + "/manifest/scenarios/legacy.yaml"
        let original = Data(repeating: 65, count: 256 * 1_024)
        let replacement = Data(repeating: 66, count: original.count)
        try files.writeData(at: path, data: original)
        var initial = stat()
        XCTAssertEqual(lstat(path, &initial), 0)
        let guarded = ScenarioCarryFileService()
        var fired = false
        guarded.checkpointAction = { point in
            guard case .copiedChunk = point, !fired else { return }
            fired = true
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.write(contentsOf: replacement)
            var times = [initial.st_atimespec, initial.st_mtimespec]
            XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
        }
        var changed = empty
        changed.categories = [CategoryRecord(name: "new", projectKeys: [], skillSlugs: [])]
        XCTAssertThrowsError(try ManifestService(fileService: guarded).write(changed, toRoot: root))
        XCTAssertTrue(fired)
        XCTAssertEqual(try manifest.read(fromRoot: root).categories, [])
        XCTAssertEqual(try files.readData(at: path), replacement)
        try manifest.write(changed, toRoot: root)
        XCTAssertEqual(try files.readData(at: path), replacement)
        XCTAssertEqual(try manifest.read(fromRoot: root).categories, changed.categories)
    }
}
