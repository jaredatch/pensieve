import Foundation
import WebKit

extension TestWait {
    @MainActor
    static func waitForEditorText(_ expected: String, in editor: WKWebView, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var evaluationFinished = false
            var text: String?
            editor.evaluateJavaScript(
                "window.Editor && window.Editor.getContent ? window.Editor.getContent() : null"
            ) { result, _ in
                text = result as? String
                evaluationFinished = true
            }
            while !evaluationFinished, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            guard evaluationFinished else { return nil }
            if text == expected { return text }
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return nil
    }
}
