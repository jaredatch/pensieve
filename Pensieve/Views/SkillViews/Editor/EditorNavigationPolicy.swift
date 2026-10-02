import WebKit

/// The pure, unit-tested core of both navigation delegate methods: cancel everything except the
/// initial local load and http/https link activations (which open in the system browser).
enum EditorNavigationPolicy {
    enum Decision: Equatable { case allowInitialLoad, openExternally, cancel }

    static func decision(for url: URL, navigationType: WKNavigationType, scheme: String) -> Decision {
        if navigationType == .other, url.scheme == scheme { return .allowInitialLoad }
        if navigationType == .linkActivated, let s = url.scheme?.lowercased(), s == "http" || s == "https" {
            return .openExternally
        }
        return .cancel   // file:, data:, javascript:, mailto:, other schemes, any non-initial scheme load
    }
}
