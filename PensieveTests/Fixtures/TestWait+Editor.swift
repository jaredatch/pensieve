import AppKit
import WebKit
import XCTest

extension TestWait {
    @MainActor
    static func waitForEditor(in host: NSView, minimumHeight: CGFloat = 0,
                              timeout: Duration = .seconds(3)) async throws -> WKWebView {
        var editor: WKWebView?
        await until(timeout: timeout, failureMessage: "Source editor must finish layout") {
            host.layoutSubtreeIfNeeded()
            editor = firstEditor(in: host)
            return editor != nil && editor?.frame.height ?? 0 >= minimumHeight
        }
        return try XCTUnwrap(editor)
    }

    @MainActor
    private static func firstEditor(in view: NSView) -> WKWebView? {
        if let editor = view as? WKWebView { return editor }
        return view.subviews.lazy.compactMap { firstEditor(in: $0) }.first
    }

    @MainActor
    static func waitForEditorText(_ expected: String, in editor: WKWebView, timeout: Duration) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastText: String?
        repeat {
            var evaluationFinished = false
            var text: String?
            editor.evaluateJavaScript(
                "window.Editor && window.Editor.getContent ? window.Editor.getContent() : null"
            ) { result, _ in
                text = result as? String
                evaluationFinished = true
            }
            while !evaluationFinished, clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            guard evaluationFinished else { return lastText }
            lastText = text
            if text == expected { return text }
            try? await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        return lastText
    }
}
