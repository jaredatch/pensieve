import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testPreviewWithMissingOrShortNotesDisplaysWithoutTrapping() async throws {
        let before = (1...20).map { "line \($0)\n" }.joined()
        let after = "changed first\n" + (2...19).map { "line \($0)\n" }.joined() + "changed last\n"
        let preview = try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "SKILL.md", kind: .modified, content: .text(old: before, new: after))
        ], unreadFileCount: 0, bytesRead: before.utf8.count + after.utf8.count))
        let diff = try XCTUnwrap(preview.files.first?.diff)
        XCTAssertEqual(diff.hunks.count, 2, "The missing-notes fixture must reach two hunk indices")
        for notes: [[Int: [String]]] in [[], [[:]]] {
            let window = makeWindow(id: "missing-notes")
            defer { window.contentView = nil; window.close() }
            let presented = UnifiedDiffView(diff: diff, notes: notes)
            let host = NSHostingView(rootView: presented.frame(width: 640, height: 360))
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertEqual(host.fittingSize.height, 360, accuracy: 1,
                           "A preview with missing or short notes must render its diff without trapping")
        }
    }

}
