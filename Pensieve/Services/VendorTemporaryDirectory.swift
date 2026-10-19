import Foundation

/// Store publishers prepare outside the store on its own device. The resolved-path key keeps
/// separate stores with the same basename from sweeping each other's abandoned preparations.
enum VendorTemporaryDirectory {
    static func namespace(storeRoot: String, fileService: FileServiceProtocol,
                          kind: String = "vendor") throws -> (parent: String, prefix: String) {
        let parent = try fileService.storeTemporaryParent(root: storeRoot)
        let key = try fileService.storeKey(root: storeRoot)
        return (parent, ".pensieve-" + key + "." + kind + "-")
    }

    static func legacyNamespace(storeRoot: String) -> (parent: String, prefix: String) {
        ((storeRoot as NSString).deletingLastPathComponent,
         (storeRoot as NSString).lastPathComponent + ".vendor-")
    }

    static func makePath(storeRoot: String, fileService: FileServiceProtocol, kind: String = "vendor") throws -> String {
        let location = try namespace(storeRoot: storeRoot, fileService: fileService, kind: kind)
        return location.parent + "/" + location.prefix + UUID().uuidString + ".tmp"
    }

    static func contains(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(".tmp".count))) != nil
    }
}
