import AppKit
import XCTest

@MainActor
final class TestWindowLifetimeTests: XCTestCase {
    private var deliberateWindow: NSWindow?

    override func tearDown() {
        deliberateWindow?.animationBehavior = .none
        deliberateWindow?.close()
        deliberateWindow = nil
        super.tearDown()
    }

    func testOpenWindowFailsItsOwningCaseAtTeardown() {
        expectLifetimeFailure(title: "deliberately open host")
        let window = makeWindow(title: "deliberately open host")
        window.contentView = nil
        window.orderFront(nil)
        deliberateWindow = window
    }

    func testClosedRetainedWindowFailsItsOwningCaseAtTeardown() {
        // A test-owned subclass still fails despite the private-framework helper exclusion.
        expectLifetimeFailure(title: "deliberately retained host")
        let window = makeWindow(title: "deliberately retained host")
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.orderFront(nil)
        window.close()
        deliberateWindow = window
    }

    func testClosedRetainedWindowWithTransitionsFailsAtTeardown() {
        expectLifetimeFailure(title: "retained host with transitions")
        let window = makeWindow(title: "retained host with transitions")
        window.contentView = nil
        window.animationBehavior = .default
        window.close()
        deliberateWindow = window
    }

    func testHiddenRetainedContentlessShellWithTransitionsOffIsAccepted() {
        let window = makeWindow(title: "inert retained shell")
        window.orderFront(nil)
        window.close()
        window.contentView = nil
        deliberateWindow = window
    }

    func testReleasedHostAndExistingWindowAreAccepted() {
        // A separate observer must exclude the window already present at its baseline.
        let existing = makeWindow(title: "existing host")
        existing.orderFront(nil)
        defer { existing.close() }
        TestWindowLifetime().testCaseWillStart(self)
        autoreleasepool {
            let hosted = makeWindow(title: "released host")
            hosted.orderFront(nil)
            hosted.close()
        }
    }

    private func expectLifetimeFailure(title: String) {
        XCTAssertEqual(TestWindowLifetime.registrationCount, 1)
        let owner = name
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = {
            $0.compactDescription.contains(owner + " left a test window alive") && $0.compactDescription.contains(title)
        }
        // The bundle observer's real teardown must produce this failure; no direct check invocation.
        XCTExpectFailure("The lifetime guard must reject this deliberately retained window", options: options)
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = LifetimeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = title
        return window
    }
}

private final class LifetimeTestWindow: NSWindow {}
