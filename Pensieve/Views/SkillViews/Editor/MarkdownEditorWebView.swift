import SwiftUI
import WebKit

/// A hardened WKWebView host for the vendored CodeMirror editor. 03.2 landed the security foundation;
/// 03.3 adds the Swift↔JS bridge (ready-gated pushes, data-marshalled transport, re-entrancy guard).
/// 03.4 wires it into SkillEditorView.
struct MarkdownEditorWebView: NSViewRepresentable {
    var bodyToLoad: String = ""
    var loadVersion: Int = 0
    var readOnly = false
    var onReady: () -> Void = {}                          // fired on editorDidReady
    var onContentChange: (String) -> Void = { _ in }      // fired on a user edit

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onContentChange: onContentChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onContentChange = onContentChange
        context.coordinator.setTheme(colorScheme == .dark ? "dark" : "light")
        context.coordinator.setReadOnly(readOnly)
        context.coordinator.pushIfNewer(body: bodyToLoad, version: loadVersion)
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private(set) var webView: WKWebView?
        var onReady: () -> Void
        var onContentChange: (String) -> Void
        var onNavigationFinished: (() -> Void)?            // test hook

        private var isReady = false
        private var pending: [(WKWebView) -> Void] = []    // ready-gate buffer
        private var lastPushedVersion = 0
        private var lastTheme: String?
        private var lastReadOnly: Bool?

        init(onReady: @escaping () -> Void, onContentChange: @escaping (String) -> Void) {
            self.onReady = onReady
            self.onContentChange = onContentChange
        }

        func makeWebView() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            config.websiteDataStore = .nonPersistent()
            config.limitsNavigationsToAppBoundDomains = true
            let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            config.setURLSchemeHandler(EditorAssetSchemeHandler(root: root),
                                       forURLScheme: EditorAssetSchemeHandler.scheme)
            // Bridge: register the editor→Swift handlers via a WEAK proxy to avoid the
            // userContentController → handler → Coordinator → webView → config retain cycle.
            let proxy = WeakScriptMessageHandler(self)
            config.userContentController.add(proxy, name: "editorDidReady")
            config.userContentController.add(proxy, name: "contentDidChange")

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = false
            webView.allowsLinkPreview = false
            #if DEBUG
            if #available(macOS 13.3, *) { webView.isInspectable = true }
            #endif
            // Transparent web view: let the host Color(.textBackgroundColor) show through (§4). WKWebView
            // draws an opaque (white) background by default and exposes `drawsBackground` ONLY as a KVC key
            // — there is no `setDrawsBackground:` ObjC method, so `responds(to:)` returns false and a guard
            // on it would skip this, leaving an opaque white view (unreadable light-on-white in dark mode).
            // Set it directly via KVC (the MarkEdit/CotEditor pattern); WKWebView is KVC-compliant here.
            webView.setValue(false, forKey: "drawsBackground")
            self.webView = webView
            load()
            return webView
        }

        deinit {
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        }

        func load() {
            guard let webView, let url = URL(string: "pensieve-editor://app/index.html") else { return }
            webView.load(URLRequest(url: url))
        }

        // MARK: Swift → editor (ready-gated; untrusted text crosses ONLY here, as a data argument)

        /// Push the document. The body is bound as a named argument — it is data, never code, even in
        /// principle. This is the ONLY path untrusted text takes into the editor.
        func setBody(_ body: String) {
            enqueue { webView in
                webView.callAsyncJavaScript("window.Editor.setContent(text)",
                                            arguments: ["text": body], in: nil, in: .page) { _ in }
            }
        }

        /// Sync light/dark appearance into the editor. Constant JS source; the scheme is a bound data arg.
        func setTheme(_ scheme: String) {
            guard scheme != lastTheme else { return }
            lastTheme = scheme
            enqueue { webView in
                webView.callAsyncJavaScript("window.Editor.setTheme(scheme)",
                                            arguments: ["scheme": scheme], in: nil, in: .page) { _ in }
            }
        }

        /// The Content tab's other files show in this editor without editing: a bound data arg, sent once per change.
        func setReadOnly(_ flag: Bool) {
            guard flag != lastReadOnly else { return }
            lastReadOnly = flag
            enqueue { webView in
                webView.callAsyncJavaScript("window.Editor.setReadOnly(flag)",
                                            arguments: ["flag": flag], in: nil, in: .page) { _ in }
            }
        }

        /// Push the body into the editor ONLY when the load token advances (a load/reload), so a stale
        /// `bodyToLoad` can never overwrite live user edits on an incidental SwiftUI update. The ready-gate
        /// in `setBody` buffers the push until the editor signals `editorDidReady`.
        func pushIfNewer(body: String, version: Int) {
            guard version != lastPushedVersion else { return }
            lastPushedVersion = version
            setBody(body)
        }

        /// Test seam: dispatch a simulated user edit (also a data argument).
        func simulateEdit(_ text: String) {
            enqueue { webView in
                webView.callAsyncJavaScript("window.Editor.simulateEdit(t)",
                                            arguments: ["t": text], in: nil, in: .page) { _ in }
            }
        }

        /// Read the current document. Constant JS string — no interpolation.
        func getContent(_ completion: @escaping (String) -> Void) {
            webView?.evaluateJavaScript("window.Editor.getContent()") { result, _ in
                completion(result as? String ?? "")
            }
        }

        /// Test hook: constant-string JS only.
        func evaluateJavaScript(_ js: String, completion: ((Any?, Error?) -> Void)? = nil) {
            webView?.evaluateJavaScript(js) { completion?($0, $1) }
        }

        private func enqueue(_ op: @escaping (WKWebView) -> Void) {
            if isReady, let webView { op(webView) } else { pending.append(op) }
        }

        // MARK: WKScriptMessageHandler (editor → Swift)
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "editorDidReady":
                isReady = true
                if let webView {
                    let ops = pending; pending = []
                    ops.forEach { $0(webView) }
                }
                onReady()
            case "contentDidChange":
                onContentChange(message.body as? String ?? "")
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigationFinished?()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            switch EditorNavigationPolicy.decision(for: url,
                                                   navigationType: action.navigationType,
                                                   scheme: EditorAssetSchemeHandler.scheme) {
            case .allowInitialLoad: decisionHandler(.allow)
            case .openExternally:   NSWorkspace.shared.open(url); decisionHandler(.cancel)
            case .cancel:           decisionHandler(.cancel)
            }
        }

        // MARK: WKUIDelegate — target=_blank / window.open → system browser, never a child web view
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

/// Weak proxy so `userContentController` does not retain the `Coordinator` (breaks the retain cycle
/// that would otherwise leak the web view on every editor mount).
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}
