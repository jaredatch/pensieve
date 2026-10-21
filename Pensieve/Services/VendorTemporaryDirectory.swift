import Foundation

/// Store publishers prepare outside the store on its own device. The resolved-path key keeps
/// separate stores with the same basename from sweeping each other's abandoned preparations.
enum VendorTemporaryDirectory {
    static func namespace(storeRoot: String, fileService: FileServiceProtocol,
                          kind: String = "vendor") throws -> (parent: String, prefix: String) {
        let location = try namespaces(storeRoot: storeRoot, fileService: fileService, kinds: [kind])
        return (location.parent, location.prefixes[0])
    }

    static func namespaces(storeRoot: String, fileService: FileServiceProtocol,
                           kinds: [String]) throws -> (parent: String, prefixes: [String]) {
        let parent = try fileService.storeTemporaryParent(root: storeRoot)
        let key = try fileService.storeKey(root: storeRoot)
        return (parent + "/.pensieve-" + key, kinds.map { $0 + "-" })
    }

    static func legacyNamespace(storeRoot: String) -> (parent: String, prefix: String) {
        ((storeRoot as NSString).deletingLastPathComponent,
         (storeRoot as NSString).lastPathComponent + ".vendor-")
    }

    static func makePath(storeRoot: String, fileService: FileServiceProtocol, kind: String = "vendor") throws -> String {
        let location = try namespace(storeRoot: storeRoot, fileService: fileService, kind: kind)
        if try !fileService.storeContainerExists(at: location.parent) {
            do {
                try fileService.createDirectory(at: location.parent)
            } catch {
                // A concurrent creator is fine only when it left a real directory.
                guard (try? fileService.storeContainerExists(at: location.parent)) == true else { throw error }
            }
        }
        // Recheck after creation, which may have raced a file or link into this name.
        guard try fileService.storeContainerExists(at: location.parent) else { throw CocoaError(.fileNoSuchFile) }
        return location.parent + "/" + location.prefix + UUID().uuidString + ".tmp"
    }

    static func contains(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(".tmp") else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(".tmp".count))) != nil
    }
}
