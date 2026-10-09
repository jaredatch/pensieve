import Foundation

/// Resolves a request path under a fixed root and refuses anything that escapes it (defeats `../`
/// traversal). Pure => unit-testable without a web view. The load-bearing line is the
/// standardized URL plus scalar/component containment through PathSyntax.
enum EditorAssetResolver {
    static func resolve(root: URL, requestPath: String) -> URL? {
        let resolved = root.appendingPathComponent(requestPath).standardizedFileURL
        let base = root.standardizedFileURL.path
        return resolved.path == base || PathSyntax.hasPrefix(resolved.path, base + "/") ? resolved : nil
    }
}
