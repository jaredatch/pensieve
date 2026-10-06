import Foundation

/// Only web links may leave a skill's rendered preview or source editor.
enum WebLinkPolicy {
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
