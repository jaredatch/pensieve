import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class UnsavedChangesAlertTests: XCTestCase {
    func testStockCopyAndButtons() {
        let alert = UnsavedChangesAlert.make(fileName: "SKILL.md")

        XCTAssertEqual(alert.messageText, "Do you want to save the changes made to “SKILL.md”?")
        XCTAssertEqual(alert.informativeText, "Your changes will be lost if you don’t save them.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Save", "Cancel", "Don’t Save"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons[2].keyEquivalent, "d")
        XCTAssertEqual(alert.buttons[2].keyEquivalentModifierMask, [.command])
    }

    func testResponsesMapToChoices() {
        XCTAssertEqual(UnsavedChangesAlert.choice(for: .alertFirstButtonReturn), .save)
        XCTAssertEqual(UnsavedChangesAlert.choice(for: .alertSecondButtonReturn), .cancel)
        XCTAssertEqual(UnsavedChangesAlert.choice(for: .alertThirdButtonReturn), .discard)
        XCTAssertEqual(UnsavedChangesAlert.choice(for: .abort), .cancel)
    }

    /// The answer must arrive after the sheet has left the window: the close guard's continuation asks the
    /// window to close through `performClose`, which refuses (beeps) at a window that still has a sheet.
    func testTheAnswerArrivesAfterTheSheetHasLeft() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let answered = expectation(description: "answered")
        var sheetStillAttached: Bool?
        var answer: UnsavedChangesChoice?
        UnsavedChangesAlert.beginSheet(UnsavedChangesAlert.make(fileName: "SKILL.md"), on: window) { choice in
            sheetStillAttached = window.attachedSheet != nil
            answer = choice
            answered.fulfill()
        }
        guard let sheet = window.attachedSheet else { return XCTFail("the sheet did not attach") }
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(answer, .save)
        XCTAssertEqual(sheetStillAttached, false)
    }

    func testAHostClosingUnderTheSheetAnswersCancel() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { if window.isVisible { window.close() } }
        let answered = expectation(description: "answered")
        var answer: UnsavedChangesChoice?
        UnsavedChangesAlert.beginSheet(UnsavedChangesAlert.make(fileName: "SKILL.md"), on: window) { choice in
            answer = choice
            answered.fulfill()
        }
        XCTAssertNotNil(window.attachedSheet)

        window.close()

        wait(for: [answered], timeout: 5)
        XCTAssertEqual(answer, .cancel)
    }
}
