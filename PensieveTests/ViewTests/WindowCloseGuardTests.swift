import AppKit
import XCTest
@testable import Pensieve

/// The window-close proxy, hosted: a real `NSWindow` with a recording delegate, the proxy attached over it.
@MainActor
final class WindowCloseGuardTests: XCTestCase {
    private final class RecordingDelegate: NSObject, NSWindowDelegate {
        var shouldCloseCalls = 0
        var didResizeCalls = 0
        /// What the original delegate answers when the proxy forwards the close decision to it.
        var answer = true

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldCloseCalls += 1
            return answer
        }

        func windowDidResize(_ notification: Notification) {
            didResizeCalls += 1
        }
    }

    /// A real window with the recorder as its delegate and the proxy attached over it (a struct, not a
    /// tuple: strict lint caps tuples at two members).
    private struct Harness {
        let window: NSWindow
        let original: RecordingDelegate
        let proxy: WindowDelegateProxy
    }

    private func makeWindow() -> Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // a programmatic window frees itself on close; the harness owns this one
        let original = RecordingDelegate()
        window.delegate = original
        let proxy = WindowDelegateProxy()
        proxy.attach(to: window)
        return Harness(window: window, original: original, proxy: proxy)
    }

    /// Whether `body` closed the window, read from the notification the close posts.
    private func closes(_ window: NSWindow, during body: () -> Void) -> Bool {
        var closed = false
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { _ in closed = true }
        body()
        NotificationCenter.default.removeObserver(token)
        return closed
    }

    func testVetoKeepsTheWindowAndAsksNobodyElse() {
        let harness = makeWindow()
        let (window, original, proxy) = (harness.window, harness.original, harness.proxy)
        var asked = 0
        proxy.shouldClose = { _ in
            asked += 1
            return false
        }

        let closed = closes(window) { window.performClose(nil) }

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(original.shouldCloseCalls, 0)
        XCTAssertFalse(closed)
    }

    func testNoVetoForwardsToTheOriginalAndCloses() {
        let harness = makeWindow()
        let (window, original, proxy) = (harness.window, harness.original, harness.proxy)
        proxy.shouldClose = { _ in true }

        let closed = closes(window) { window.performClose(nil) }

        XCTAssertEqual(original.shouldCloseCalls, 1)
        XCTAssertTrue(closed)
    }

    /// The original delegate's own veto is forwarded, not just asked for (round 5: a proxy that asked and
    /// ignored the answer passed every earlier test).
    func testTheOriginalDelegatesVetoIsForwarded() {
        let harness = makeWindow()
        let (window, original, proxy) = (harness.window, harness.original, harness.proxy)
        proxy.shouldClose = { _ in true }
        original.answer = false

        let closed = closes(window) { window.performClose(nil) }

        XCTAssertEqual(original.shouldCloseCalls, 1)
        XCTAssertFalse(closed)
    }

    func testOtherDelegateMethodsReachTheOriginal() {
        let harness = makeWindow()
        let (window, original) = (harness.window, harness.original)

        window.setFrame(NSRect(x: 0, y: 0, width: 400, height: 200), display: false)

        XCTAssertGreaterThanOrEqual(original.didResizeCalls, 1)
    }

    func testAttachIsIdempotentAndFollowsAReplacedDelegate() {
        let harness = makeWindow()
        let (window, original, proxy) = (harness.window, harness.original, harness.proxy)

        proxy.attach(to: window)
        XCTAssertTrue(window.delegate === proxy)
        XCTAssertTrue(proxy.original === original)

        let replacement = RecordingDelegate()
        window.delegate = replacement
        proxy.attach(to: window)
        XCTAssertTrue(window.delegate === proxy)
        XCTAssertTrue(proxy.original === replacement)
    }
}
