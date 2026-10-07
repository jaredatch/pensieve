import XCTest
import WebKit
@testable import Pensieve

@MainActor
final class MarkdownEditorBridgeTests: XCTestCase {
    // Loads the editor and returns a ready Coordinator (+ the window keeping the web view alive).
    private func makeReadyEditor(onContentChange: @escaping (String) -> Void)
        -> (MarkdownEditorWebView.Coordinator, NSWindow) {
        let ready = expectation(description: "editorDidReady")
        let coordinator = MarkdownEditorWebView.Coordinator(onReady: { ready.fulfill() },
                                                            onContentChange: onContentChange)
        let webView = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        wait(for: [ready], timeout: TestWait.hostedActionTimeoutSeconds)
        return (coordinator, window)
    }

    // (1) A Swift push of a hostile payload round-trips intact (data-not-code, end to end).
    func testHostilePayloadRoundTrips() {
        let (coordinator, window) = makeReadyEditor(onContentChange: { _ in })
        withExtendedLifetime(window) {
            let hostile = "`</script>` ${x} \"q\" ' \n# heading"
            coordinator.setBody(hostile)
            let done = expectation(description: "round-trip")
            // callAsyncJavaScript(setContent) and evaluateJavaScript(getContent) execute FIFO on the
            // web content, so getContent observes the pushed value — no fixed sleep.
            coordinator.getContent { text in
                XCTAssertEqual(text, hostile)
                done.fulfill()
            }
            wait(for: [done], timeout: TestWait.hostedActionTimeoutSeconds)
        }
    }

    // (2) An editor-side change reaches Swift exactly once; a Swift push does NOT echo back.
    func testEditorSideChangeReachesSwiftAndPushDoesNotEcho() {
        var changes: [String] = []
        let hostile = "`</script>` typed by user"
        let edited = expectation(description: "editor-side change")
        let (coordinator, window) = makeReadyEditor(onContentChange: { text in
            changes.append(text)
            if text == hostile { edited.fulfill() }
        })
        withExtendedLifetime(window) {
            coordinator.setBody("seed")        // Swift push — must NOT echo as a change
            coordinator.simulateEdit(hostile)  // editor-side edit — MUST post contentDidChange
            wait(for: [edited], timeout: TestWait.hostedActionTimeoutSeconds)
            XCTAssertFalse(changes.contains("seed"), "a Swift push must not echo back as a change")
        }
    }

    // (3) Regression (03.3 review): a user edit reverting to the LAST Swift-pushed value must still
    //     report a change. The value-equality echo guard wrongly dropped it; the transaction-annotation
    //     guard suppresses only the push's own echo, not a later collision.
    func testUserRevertToPushedValueStillReportsChange() {
        var changes: [String] = []
        let reverted = expectation(description: "revert to pushed value reported")
        let (coordinator, window) = makeReadyEditor(onContentChange: { text in
            changes.append(text)
            if text == "seed" && changes.contains("draft") { reverted.fulfill() }
        })
        withExtendedLifetime(window) {
            coordinator.setBody("seed")        // push — its echo must be suppressed
            coordinator.simulateEdit("draft")  // user edit — posts "draft"
            coordinator.simulateEdit("seed")   // user reverts to the pushed value — MUST post "seed"
            wait(for: [reverted], timeout: TestWait.hostedActionTimeoutSeconds)
            XCTAssertEqual(changes, ["draft", "seed"],
                           "the push echo must be suppressed but a user revert to the pushed value must post")
        }
    }
}
