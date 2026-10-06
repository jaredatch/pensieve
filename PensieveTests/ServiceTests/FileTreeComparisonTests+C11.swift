import Darwin
import XCTest
@testable import Pensieve

extension FileTreeComparisonTests {
    func testModeOnlyUsesCopiedPermissionsAndExplainsTheActualChange() throws {
        for (before, after, reason) in [
            (0o644, 0o744, "File contents are unchanged. Executable permission changed from off to on."),
            (0o600, 0o644, "File contents are unchanged. Permissions changed from 0600 to 0644.")
        ] {
            for side in [old, new] { try files.writeFile(at: side + "/mode", content: "same") }
            XCTAssertEqual(chmod(old + "/mode", mode_t(before)), 0)
            XCTAssertEqual(chmod(new + "/mode", mode_t(after)), 0)
            let preview = try PinnedSkillDiff.build(comparison: try compare())
            let file = try XCTUnwrap(preview.files.first)
            XCTAssertEqual(file.content, .modeOnly(old: UInt32(before), new: UInt32(after)))
            XCTAssertEqual(ViewChangesPresentation.unavailableReason(file), reason,
                           "Mode-only copy must describe the bits that actually changed")
            XCTAssertNil(file.diff)
        }
        XCTAssertEqual(chmod(old + "/mode", 0o1644), 0)
        XCTAssertEqual(chmod(new + "/mode", 0o644), 0)
        XCTAssertTrue(try compare().changes.isEmpty,
                      "Special bits are not copied by Update and must not create preview changes")
    }
}
