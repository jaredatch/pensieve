import Foundation

/// JSON-encodes a string to a JS-safe string literal (a strict subset of a JS string literal —
/// guaranteed-valid, self-delimiting DATA). This is the deterministic, unit-tested proof of the
/// data-not-code property. It is deliberately NOT used by `MarkdownEditorWebView` (which uses
/// `callAsyncJavaScript(arguments:)`), so no interpolated `evaluateJavaScript` can reintroduce it.
enum EditorTransport {
    static func jsonString(for text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(bytes: data, encoding: .utf8) ?? "\"\""
    }
}
