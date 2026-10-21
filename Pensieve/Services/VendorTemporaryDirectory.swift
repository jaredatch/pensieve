import Foundation

/// Store publishers prepare outside the store on its own device. The resolved-path key keeps
/// separate stores with the same basename from sweeping each other's abandoned preparations.
enum VendorTemporaryDirectory {
    static let kinds = ["vendor", "manifest-build", "machine-state"]

    static func namespace(storeRoot: String, fileService: FileServiceProtocol,
                          kind: String = "vendor") throws -> (parent: String, prefix: String) {
        let parent = try fileService.storeTemporaryParent(root: storeRoot)
        let key = try fileService.storeKey(root: storeRoot)
        return (parent + "/.pensieve-" + key, kind + "-")
    }

    static func legacyNamespace(storeRoot: String) -> (parent: String, prefixes: [String]) {
        ((storeRoot as NSString).deletingLastPathComponent,
         kinds.map { (storeRoot as NSString).lastPathComponent + "." + $0 + "-" })
    }

    /// The caller holds sync.lock through this scope, including cleanup after a failed publication.
    static func withPath<Result>(storeRoot: String, fileService: FileServiceProtocol, kind: String = "vendor",
                                 body: (String) throws -> Result) throws -> Result {
        let path = try makePath(storeRoot: storeRoot, fileService: fileService, kind: kind)
        defer { try? fileService.removeEmptyDirectory(at: (path as NSString).deletingLastPathComponent) }
        return try body(path)
    }

    static func makePath(storeRoot: String, fileService: FileServiceProtocol, kind: String = "vendor") throws -> String {
        let location = try namespace(storeRoot: storeRoot, fileService: fileService, kind: kind)
        try fileService.createDirectory(at: location.parent)
        guard try fileService.storeContainerExists(at: location.parent) else { throw CocoaError(.fileNoSuchFile) }
        return location.parent + "/" + location.prefix + UUID().uuidString + ".tmp"
    }

    static func contains(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(".tmp".count))) != nil
    }
}
