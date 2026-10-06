import AppKit
import XCTest
@testable import Pensieve

extension UpdateReviewRoutingTests {
    func testWindowHandoffDoesNotQueueUpdatesBehindAnotherMainWindowSheet() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("other-sheet")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let (sheet, preview) = fixture.review(rows: [row])
        let main = makeSheetWindow(id: "main-AppWindow-other-sheet")
        let other = makeSheetWindow(id: "other-sheet")
        main.orderFront(nil)
        main.beginSheet(other, completionHandler: nil)
        defer { main.endSheet(other); other.close(); main.close() }
        XCTAssertTrue(main.attachedSheet === other)
        var opens: [String] = []
        let routing = UpdateReviewRouting(preview: preview, updates: sheet, library: fixture.library,
                                         context: fixture.context, windows: { [main] }, openWindow: { opens.append($0) })
        routing.presentChanges(skillID: skill.id)
        await TestWait.until(failureMessage: "blocked hand-off preview did not finish") { preview.state != .loading }
        routing.window.onUpdate()
        XCTAssertTrue(main.isVisible)
        XCTAssertFalse(sheet.isPresented, "Another main-window sheet must not queue Updates invisibly")
        XCTAssertNil(sheet.initialSelection)
        main.endSheet(other)
        await TestWait.until(failureMessage: "other sheet did not close") { main.attachedSheet == nil }
        XCTAssertFalse(sheet.isPresented, "Closing another sheet must not reveal a queued Updates sheet")
        routing.window.onUpdate()
        XCTAssertTrue(sheet.isPresented, "A fresh hand-off after dismissal must open Updates")
        await sheet.loadAndReport(context: fixture.context)
        XCTAssertEqual(sheet.selectedSkillIDs, [skill.id])
    }
    private func makeSheetWindow(id: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(id)
        return window
    }

}
