import WebKit
import Security

/// Serves ONLY the app's own bundled editor assets over the private `pensieve-editor://` scheme,
/// traversal-guarded by `EditorAssetResolver`, and stamps a fresh per-load CSP nonce into both the
/// HTML and the `Content-Security-Policy` HTTP header so they match (authorizing CodeMirror's
/// runtime-injected styles). Reads `Bundle.main`'s read-only resources -- OUTSIDE the FileService
/// boundary (same class as `Bundle.main.url(forResource:)`); the user's skill content never flows here.
final class EditorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pensieve-editor"

    /// The strict CSP (Artifact E), with a `__CSP_NONCE__` placeholder replaced per load.
    static let cspTemplate =
        "default-src 'none'; script-src 'self'; style-src 'self' 'nonce-__CSP_NONCE__'; " +
        "img-src 'self' data:; font-src 'self'; connect-src 'none'; object-src 'none'; " +
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    private let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let resolved = EditorAssetResolver.resolve(root: root, requestPath: url.path),
              var data = try? Data(contentsOf: resolved) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        var headers = ["Content-Type": Self.mimeType(for: resolved)]
        if resolved.pathExtension.lowercased() == "html" {
            // ONE fresh per-load nonce into BOTH the served HTML (every __CSP_NONCE__) AND the CSP
            // header, so EditorView.cspNonce (read from the <meta>) matches the header's nonce.
            let nonce = Self.freshNonce()
            guard let html = String(data: data, encoding: .utf8)?.replacingOccurrences(
                of: "__CSP_NONCE__",
                with: nonce
            ) else {
                task.didFailWithError(URLError(.badServerResponse)); return
            }
            data = Data(html.utf8)
            headers["Content-Security-Policy"] = Self.cspTemplate.replacingOccurrences(of: "__CSP_NONCE__", with: nonce)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            task.didFailWithError(URLError(.badServerResponse)); return
        }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js":   return "text/javascript; charset=utf-8"
        case "css":  return "text/css; charset=utf-8"
        default:     return "application/octet-stream"
        }
    }

    // A CSP nonce must be unguessable and per-response. Fail closed: if the CSPRNG ever returns
    // non-success (not expected on macOS), fall back to a random UUID rather than serving the
    // all-zero buffer (a predictable nonce) — review finding, 03.2.
    private static func freshNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
    }
}
