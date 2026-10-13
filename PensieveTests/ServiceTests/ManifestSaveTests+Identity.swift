import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testHeldManifestScanCannotRestoreIdentityBeforeEditorSaveOrHistoryRestore() async throws {
        for restore in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let held = TestWait.Gate(owner: self)
            defer { held.open() }
            h.recording.afterRebuildSnapshot = { try held.wait() }
            _ = h.library.editorBody(for: h.alpha)
            h.library.updateMetadata(h.beta, tags: ["queued"], scope: .user, context: h.context)
            await TestWait.until(failureMessage: "The manifest scan did not finish") { held.waiterCount == 1 }
            let document = try XCTUnwrap(h.library.readSkillDocument(h.alpha))
                .replacingOccurrences(of: "description: description", with: "description: New description")
            if restore {
                try restoreSkillHistoryVersion(skill: h.alpha, body: document, store: h.library.skillStore,
                    library: h.library, notifier: {})
            } else {
                h.library.noteEditorChanged(h.alpha, body: document)
                XCTAssertTrue(h.library.saveDraft(h.alpha))
            }
            XCTAssertEqual(h.alpha.skillDescription, "New description")
            held.open()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.alpha.skillDescription, "New description")
            XCTAssertEqual(h.alpha.name, "Alpha")
            XCTAssertEqual(h.beta.tags, ["queued"], "Overlay acceptance still applies")
            XCTAssertEqual(h.library.readSkillDocument(h.alpha), document)
        }
    }
}
