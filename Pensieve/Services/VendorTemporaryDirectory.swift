import Foundation

/// The install/import preparation namespace, outside the configured store and owned by its locked sweep.
enum VendorTemporaryDirectory {
    static func namespace(storeRoot: String) -> (parent: String, prefix: String) {
        ((storeRoot as NSString).deletingLastPathComponent, (storeRoot as NSString).lastPathComponent + ".vendor-")
    }

    static func makePath(storeRoot: String) -> String {
        let location = namespace(storeRoot: storeRoot)
        return location.parent + "/" + location.prefix + UUID().uuidString + ".tmp"
    }

    static func contains(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(".tmp".count))) != nil
    }
}
