import AppKit
import XCTest
@testable import Pensieve

@MainActor
final class WindowPolicyTests: XCTestCase {
    /// The production app applies this before any window exists (`PensieveApp.init`); the flag is
    /// process-global, so the test restores whatever the host had.
    func testApplyDisablesAutomaticWindowTabbing() {
        let previous = NSWindow.allowsAutomaticWindowTabbing
        defer { NSWindow.allowsAutomaticWindowTabbing = previous }

        NSWindow.allowsAutomaticWindowTabbing = true
        WindowPolicy.apply()

        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    private func makeWindow(identifier: String?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        window.isReleasedWhenClosed = false
        return window
    }

    func testMainWindowIsTheVisibleGroupWindowNeverASheetOrSettings() {
        let main = makeWindow(identifier: "main-AppWindow-1")
        let settings = makeWindow(identifier: "com_apple_SwiftUI_Settings_window")
        let untagged = makeWindow(identifier: nil)
        defer { [main, settings, untagged].forEach { $0.orderOut(nil) } }
        [main, settings, untagged].forEach { $0.orderFront(nil) }

        XCTAssertTrue(WindowPolicy.mainWindow(among: [settings, untagged, main]) === main)
        XCTAssertNil(WindowPolicy.mainWindow(among: [settings, untagged]))
    }

    func testMainWindowIgnoresAClosedGroupWindow() {
        let closed = makeWindow(identifier: "main-AppWindow-1")
        XCTAssertFalse(closed.isVisible)

        XCTAssertNil(WindowPolicy.mainWindow(among: [closed]))
    }

    func testShowMainWindowBringsTheExistingWindowForwardInsteadOfOpening() {
        let main = makeWindow(identifier: "main-AppWindow-1")
        defer { main.orderOut(nil) }
        main.orderFront(nil)
        var opened = 0

        WindowPolicy.showMainWindow(among: [main]) { opened += 1 }

        XCTAssertEqual(opened, 0)
        XCTAssertTrue(main.isVisible)
    }

    func testExtraMainWindowsAreEveryMainWindowAfterTheFirst() {
        let first = makeWindow(identifier: "main-AppWindow-1")
        let second = makeWindow(identifier: "main-AppWindow-2")
        let settings = makeWindow(identifier: "com_apple_SwiftUI_Settings_window")

        let extras = WindowPolicy.extraMainWindows(among: [settings, first, second])

        XCTAssertEqual(extras.count, 1)
        XCTAssertTrue(extras.first === second)
        XCTAssertTrue(WindowPolicy.extraMainWindows(among: [settings, first]).isEmpty)
    }

    func testShowMainWindowOpensWhenNoneExists() {
        var opened = 0

        WindowPolicy.showMainWindow(among: [makeWindow(identifier: nil)]) { opened += 1 }

        XCTAssertEqual(opened, 1)
    }
}
