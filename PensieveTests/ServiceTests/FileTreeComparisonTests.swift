import Darwin
import XCTest
@testable import Pensieve

final class FileTreeComparisonTests: XCTestCase {
    var root: String!
    let files = FileService()
    var old: String { root + "/old" }
    var new: String { root + "/new" }

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "FileTreeComparison-\(UUID().uuidString)"
        try files.createDirectory(at: old)
        try files.createDirectory(at: new)
    }
    override func tearDownWithError() throws { try files.deleteDirectory(at: root) }

    func compare(limits: FileTreeComparisonLimits = .updatePreview,
                 excludingGit: Bool = true,
                 checkpoint: @escaping (FileService.ComparisonCheckpoint) throws -> Void = { _ in }
    ) throws -> FileTreeComparison {
        try files.compareFileTrees(local: old, upstream: new, excludingUpstreamGit: excludingGit,
                                   limits: limits, checkpoint: checkpoint)
    }

    func testComparisonConvenienceDispatchesToTheCanonicalProtocolRequirement() throws {
        let spy = ImportBoundedReadSpy()
        let service: FileServiceProtocol = spy
        XCTAssertNoThrow(try service.compareFileTrees(local: old, upstream: new, excludingUpstreamGit: true,
                                                     limits: .updatePreview))
        XCTAssertEqual(spy.comparisonThreads.count, 1, "A double implements just the canonical comparison requirement")
    }

    func testAddedRemovedChangedUnchangedAndLocalGitMatchReplacement() throws {
        try files.writeFile(at: old + "/remove.txt", content: "one\ntwo\n")
        try files.writeFile(at: new + "/add.txt", content: "three\n")
        try files.writeFile(at: old + "/nested/change.txt", content: "old\nkeep\n")
        try files.writeFile(at: new + "/nested/change.txt", content: "new\nkeep\nextra\n")
        for side in [old, new] { try files.writeFile(at: side + "/same.txt", content: "unchanged\n") }
        try files.writeFile(at: old + "/.git/config", content: "local metadata\n")
        try files.writeFile(at: new + "/.git/config", content: "clone metadata\n")
        let preview = try PinnedSkillDiff.build(comparison: try compare())
        XCTAssertEqual(preview.files.map(\.path), [".git/config", "add.txt", "nested/change.txt", "remove.txt"])
        XCTAssertEqual(preview.files.map(\.kind), [.removed, .added, .modified, .removed])
        XCTAssertEqual(preview.files.map(\.linesAdded), [0, 1, 2, 0])
        XCTAssertEqual(preview.files.map(\.linesRemoved), [1, 0, 1, 2])
        XCTAssertFalse(preview.isIncomplete)
        let nestedPreview = try compare(excludingGit: false)
        XCTAssertEqual(nestedPreview.changes.first?.kind, .modified)
    }

    func testInvalidUTF8AndNulAreBinaryWithNoLines() throws {
        try files.writeData(at: new + "/invalid", data: Data([0xff]))
        try files.writeData(at: new + "/nul", data: Data([65, 0]))
        let preview = try PinnedSkillDiff.build(comparison: try compare())
        XCTAssertEqual(preview.files.map(\.content), [.binary, .binary])
        XCTAssertTrue(preview.files.allSatisfy { $0.diff == nil && $0.linesAdded == nil && $0.linesRemoved == nil })
    }

    func testIdenticalOversizedOmittedAndLateDifferenceListedWithoutLoadingWholeFile() throws {
        let data = Data(repeating: 65, count: 2 * 1_024 * 1_024)
        for side in [old, new] { try files.writeData(at: side + "/big", data: data) }
        var largestRetained = 0
        let same = try compare { if case let .read(_, _, retained) = $0 { largestRetained = max(largestRetained, retained) } }
        XCTAssertTrue(same.changes.isEmpty)
        XCTAssertEqual(same.bytesRead, data.count * 2)
        XCTAssertLessThanOrEqual(largestRetained, 64 * 1_024)
        var changed = data
        changed[changed.count - 1] = 66
        try files.writeData(at: new + "/big", data: changed)
        let different = try compare()
        XCTAssertEqual(different.changes, [FileTreeChange(path: "big", kind: .modified, content: .tooLarge)])
        XCTAssertEqual(different.bytesRead, data.count * 2)
    }

    func testDifferentOversizedSizesNeedNoReadsAndEarlyDifferenceStopsComparison() throws {
        try files.writeData(at: old + "/big", data: Data(repeating: 65, count: 2 * 1_024 * 1_024))
        try files.writeData(at: new + "/big", data: Data(repeating: 66, count: 2 * 1_024 * 1_024 + 1))
        XCTAssertEqual(try compare().bytesRead, 0)
        try files.writeData(at: new + "/big", data: Data(repeating: 66, count: 2 * 1_024 * 1_024))
        let preview = try compare()
        XCTAssertEqual(preview.bytesRead, 2 * 64 * 1_024)
        XCTAssertEqual(preview.changes.first?.content, .tooLarge)
    }

    func testEmptyFileAddsAndModeOnlyChangeRemainVisible() throws {
        try files.writeData(at: new + "/empty", data: Data())
        for side in [old, new] { try files.writeFile(at: side + "/mode", content: "same\n") }
        XCTAssertEqual(chmod(new + "/mode", 0o755), 0)
        let preview = try PinnedSkillDiff.build(comparison: try compare())
        XCTAssertEqual(preview.files.map(\.path), ["empty", "mode"])
        XCTAssertEqual(preview.files.map(\.linesAdded), [0, 0])
        XCTAssertEqual(preview.files.map(\.linesRemoved), [0, 0])
    }
}
