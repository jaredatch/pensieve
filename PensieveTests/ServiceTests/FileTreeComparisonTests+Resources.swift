import Darwin
import XCTest
@testable import Pensieve

extension FileTreeComparisonTests {
    func testThreeHundredDirectoriesKeepDescriptorsBoundedByDepth() throws {
        for index in 0..<150 {
            for side in [old, new] {
                try files.writeFile(at: side + "/folder\(index)/file", content: side == old ? "old" : "new")
            }
        }
        let baseline = openDescriptorCount()
        var peak = baseline
        defer { XCTAssertLessThanOrEqual(peak - baseline, 8, "two depth-one parents plus a constant") }
        let comparison = try compare { event in
            if case .directory = event { peak = max(peak, self.openDescriptorCount()) }
            if case .opened = event { peak = max(peak, self.openDescriptorCount()) }
        }
        XCTAssertEqual(comparison.changes.count, 150)
        XCTAssertFalse(comparison.isIncomplete)
        peak = max(peak, openDescriptorCount())
        let receipt = "WALK_DESCRIPTORS baseline=\(baseline) peak=\(peak) directories=300 depth=1"
        XCTContext.runActivity(named: receipt) { _ in }
        print(receipt)
        try PreviewResourceTestEvidence.record("walk", message: receipt)
    }

    func testEntryCapAcrossBothFoldersRefusesBeforeContentReads() throws {
        let half = FileTreeComparisonLimits.maximumInventoryEntries / 2
        for index in 0...half {
            for side in [old, new] { try files.writeData(at: side + "/file\(index)", data: Data()) }
        }
        var reads = 0
        XCTAssertThrowsError(try compare { if case .read = $0 { reads += 1 } }) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large to preview"))
        }
        XCTAssertEqual(reads, 0)
    }

    func testDepthCapAllowsItsBoundaryAndRefusesTheNextDirectory() throws {
        let maximum = FileTreeComparisonLimits.maximumDirectoryDepth
        let boundary = new + String(repeating: "/d", count: maximum)
        try files.writeFile(at: boundary + "/file", content: "allowed")
        let allowed = try compare()
        XCTAssertEqual(allowed.changes.count, 1)
        XCTAssertFalse(allowed.isIncomplete)
        try files.createDirectory(at: boundary + "/too-deep")
        XCTAssertThrowsError(try compare()) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large to preview"))
        }
    }

    func testParentIdentityIsRevalidatedWhenReopenedAfterInventory() throws {
        let path = old + "/nested"
        try files.writeFile(at: path + "/file", content: "old")
        var replaced = false
        XCTAssertThrowsError(try compare { event in
            if case let .directory(directory) = event, directory == self.new {
                try self.files.replaceItem(at: self.root + "/parked", with: path)
                try self.files.writeFile(at: path + "/file", content: "replacement")
                replaced = true
            }
        }) { error in XCTAssertTrue(error.localizedDescription.contains(path)) }
        XCTAssertTrue(replaced)
    }

    func testSmallAndOversizedModeOnlyChangesHaveModesAndNoHunks() throws {
        for count in [5, 2 * 1_024 * 1_024] {
            for side in [old, new] {
                try files.writeData(at: side + "/mode", data: Data(repeating: 65, count: count))
            }
            XCTAssertEqual(chmod(old + "/mode", 0o644), 0)
            XCTAssertEqual(chmod(new + "/mode", 0o751), 0)
            let preview = PinnedSkillDiff(comparison: try compare())
            XCTAssertEqual(preview.files.first?.kind, .modified)
            XCTAssertEqual(preview.files.first?.content, .modeOnly(old: 0o644, new: 0o751))
            XCTAssertNil(preview.files.first?.diff)
            XCTAssertEqual(preview.files.first?.linesAdded, 0)
            XCTAssertEqual(preview.files.first?.linesRemoved, 0)
        }
    }

    func testPermissionChangeDuringReadRemainsTooLarge() throws {
        for side in [old, new] { try files.writeFile(at: side + "/mode", content: "same") }
        var changed = false
        let result = try compare { event in
            if case .read = event, !changed {
                XCTAssertEqual(chmod(self.new + "/mode", 0o751), 0)
                changed = true
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(result.changes.first?.content, .tooLarge)
    }

    private func openDescriptorCount() -> Int {
        // Inspect, never change, process resources in the XCTest host.
        (0..<4_096).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }
}
