import CryptoKit
import Darwin
import Foundation

extension FileServiceProtocol {
    /// Path-only default for modeled filesystems; concrete FileService admits a same-device system location.
    func storeTemporaryParent(root: String) throws -> String { (root as NSString).deletingLastPathComponent }

    /// Unmodeled cleanup never touches host files.
    func removeEmptyDirectory(at path: String) throws {}

    /// Atomically publish over an absent or empty directory, preserving every other occupant.
    func publishDirectory(at sourcePath: String, to destinationPath: String) throws {
        try publishDirectory(at: sourcePath, to: destinationPath, exclusively: false)
    }

    /// Atomically publish only to an absent entry, refusing files, links and even empty folders.
    func publishNewDirectory(at sourcePath: String, to destinationPath: String) throws {
        try publishDirectory(at: sourcePath, to: destinationPath, exclusively: true)
    }

    /// One FileService boundary for both rename modes. Source and destination must share a volume.
    private func publishDirectory(at sourcePath: String, to destinationPath: String, exclusively: Bool) throws {
        let operation = exclusively ? "publish new directory" : "publish directory"
        guard try entryTypeWithoutFollowingLinks(at: sourcePath) == .directory else {
            throw DescriptorFileCopy.error(operation, path: sourcePath, code: ENOTDIR)
        }
        let result = exclusively
            ? renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            : Darwin.rename(sourcePath, destinationPath)
        guard result == 0 else {
            let code = errno
            if !exclusively && (code == ENOTEMPTY || code == EEXIST || code == ENOTDIR) {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                    NSFilePathErrorKey: destinationPath,
                    NSLocalizedDescriptionKey:
                        "The store destination '\(destinationPath)' already exists and is not an empty directory."
                ])
            }
            throw DescriptorFileCopy.error(operation, path: destinationPath, code: code)
        }
    }
}

extension FileServiceProtocol {
    /// Modeled collaborators retain their existing write behavior without host I/O.
    func writeStoreFile(at path: String, content: String, root: String, control: Bool) throws {
        try writeFile(at: path, content: content)
    }
    func cleanStoreIntermediates(at root: String) throws {}
}

extension FileService {
    func removeEmptyDirectory(at path: String) throws {
        guard rmdir(path) != 0 else { return }
        let code = errno
        guard code != ENOENT, code != ENOTEMPTY else { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    /// Publication uses the admitted directory descriptor throughout. A replaced namespace cannot
    /// redirect this writer into a directory protected by another lock. Rename never displaces folders.
    func writeStoreFile(at path: String, content: String, root: String, control: Bool) throws {
        if !control { try createDirectory(at: (path as NSString).deletingLastPathComponent) }
        let metadata: String?
        if control { metadata = try storeMetadataDirectory(root: root) } else {
            metadata = try? storeMetadataDirectory(root: root)
        }
        let directory: String
        if let metadata {
            directory = metadata
        } else {
            guard !control else { throw CocoaError(.fileNoSuchFile) }
            let location = try resolvedStoreLocation(root: root)
            let parent = try storeTemporaryParent(location: location)
            let candidates = skillNamespaces(store: location.path, parent: parent)
            guard let candidate = candidates.first(where: {
                let type = try? entryTypeWithoutFollowingLinks(at: $0)
                return type == nil || type == .directory
            }) else { throw storePublicationError(at: parent, code: EEXIST) }
            directory = candidate
            try createDirectory(at: directory)
        }
        let descriptor = try Self.openDirectory(at: directory)
        defer { close(descriptor) }
        let locked = lockStoreIntermediates(descriptor)
        // Controls are swept once by rule preparation. A direct skill save owns its own sweep.
        if locked && !control { sweepStoreIntermediates(in: descriptor) }
        let temporary = ".pensieve-write-" + UUID().uuidString
        defer { unlinkat(descriptor, temporary, 0) }
        var existing = stat()
        let mode: mode_t? = !control && lstat(path, &existing) == 0 && existing.st_mode & S_IFMT == S_IFREG
            ? existing.st_mode & 0o7777 : nil
        try writeStoreIntermediate(content, name: temporary, directory: descriptor, mode: mode)
        if control, let type = try entryTypeWithoutFollowingLinks(at: path), type == .directory || type == .symlink {
            throw storePublicationError(at: path, code: type == .directory ? EISDIR : ELOOP)
        }
        guard renameat(descriptor, temporary, AT_FDCWD, path) == 0 else {
            throw storePublicationError(at: path, code: errno)
        }
    }

    /// Tidying is best effort: an unavailable lock, namespace or leftover must not refuse the operation.
    /// A metadata-backed operation never asks Foundation to create a fallback location on another volume.
    func cleanStoreIntermediates(at root: String) throws {
        guard directoryExists(at: root) else { return }
        let metadata = try? storeMetadataDirectory(root: root)
        if let metadata { cleanStoreDirectory(metadata) }
        let parent: String?
        let system = FileManager.default.temporaryDirectory.path
        if sameStoreDevice(system, root) {
            parent = try? resolveRealPath(at: system)
        } else if metadata == nil {
            parent = try? storeTemporaryParent(root: root)
        } else { parent = nil }
        guard let parent else { return }
        if let location = try? resolvedStoreLocation(root: root) {
            for directory in skillNamespaces(store: location.path, parent: parent) { cleanStoreDirectory(directory) }
        }
        // Reclaim this store's previous-format namespace when its identity is still known.
        if let identity = fileIdentity(at: root, followingLinks: true) {
            cleanStoreDirectory(parent + "/.pensieve-store-writes-\(identity.device)-\(identity.inode)")
        }
    }

    private func cleanStoreDirectory(_ directory: String) {
        guard let descriptor = try? Self.openDirectory(at: directory) else { return }
        defer { close(descriptor) }
        if lockStoreIntermediates(descriptor) { sweepStoreIntermediates(in: descriptor) }
    }

    private func sameStoreDevice(_ first: String, _ second: String) -> Bool {
        guard let device = fileIdentity(at: first, followingLinks: true)?.device else { return false }
        return device == fileIdentity(at: second, followingLinks: true)?.device
    }

    func storeTemporaryParent(root: String) throws -> String {
        try storeTemporaryParent(location: resolvedStoreLocation(root: root))
    }

    private func storeTemporaryParent(location: (path: String, existingAncestor: String)) throws -> String {
        let store = location.path
        var parent = FileManager.default.temporaryDirectory.path
        if !sameStoreDevice(parent, location.existingAncestor) {
            // A volume-root store has no outside location on its own device. Refuse before
            // Foundation creates .TemporaryItems inside it; configuring Git supplies metadata.
            var volume = statfs()
            guard statfs(location.existingAncestor, &volume) == 0 else { throw storePublicationError(at: store, code: errno) }
            let mount = withUnsafePointer(to: &volume.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard try resolveRealPath(at: mount) != store else {
                throw storePublicationError(at: store, code: EXDEV)
            }
            let replacement = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: URL(fileURLWithPath: location.existingAncestor), create: true)
            parent = replacement.deletingLastPathComponent().path
            try? deleteDirectory(at: replacement.path)
        }
        parent = try resolveRealPath(at: parent)
        guard sameStoreDevice(parent, location.existingAncestor) else { throw storePublicationError(at: parent, code: EXDEV) }
        guard parent != store, !PathSyntax.hasPrefix(parent, store + "/") else {
            throw storePublicationError(at: parent, code: EINVAL)
        }
        return parent
    }

    /// Key by the resolved store path, so replacing its inode or remounting its device does not orphan writes.
    /// The alternate preserves a foreign occupant at the ordinary namespace, including a symlink.
    private func skillNamespaces(store: String, parent: String) -> [String] {
        guard parent != store, !PathSyntax.hasPrefix(parent, store + "/") else { return [] }
        let key = storeKey(resolvedPath: store)
        let directory = parent + "/.pensieve-store-writes-" + key
        return [directory, directory + "-alternate"]
    }

    private func lockStoreIntermediates(_ descriptor: Int32) -> Bool {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    private func sweepStoreIntermediates(in descriptor: Int32) {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { return }
        guard let stream = fdopendir(duplicate) else { close(duplicate); return }
        defer { closedir(stream) }
        let prefix = ".pensieve-write-"
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & S_IFMT == S_IFREG else { continue }
            _ = unlinkat(descriptor, name, 0)
        }
    }

    private func storePublicationError(at path: String, code: Int32) -> NSError {
        let description = code == EISDIR ? "not a regular file: \(path)"
            : "open(\(path)): " + String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: description])
    }

    private func writeStoreIntermediate(_ content: String, name: String, directory: Int32, mode: mode_t?) throws {
        let (descriptor, _) = try Self.openRegularFile(at: name, relativeTo: directory, creatingWithPermissions: mode ?? 0o644)
        defer { close(descriptor) }
        try Data(content.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw storePublicationError(at: name, code: written == 0 ? EIO : errno) }
                offset += written
            }
        }
        if let mode, fchmod(descriptor, mode) != 0 { throw storePublicationError(at: name, code: errno) }
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw storePublicationError(at: name, code: errno) }
        }
    }
}

extension FileServiceProtocol {
    func storeMetadataDirectory(root: String) throws -> String? {
        let metadata = root + "/.git"
        guard let type = try entryTypeWithoutFollowingLinks(at: metadata) else { return nil }
        let directory: String
        if type == .regular {
            let text = try GitDirectoryText.read(at: metadata, fileService: self)
            directory = try GitDirectoryText.directory(text, relativeTo: root)
        } else {
            guard type == .directory else { throw CocoaError(.fileReadUnknown) }
            directory = metadata
        }
        guard directoryExists(at: directory) else { throw CocoaError(.fileNoSuchFile) }
        let resolved = try resolveRealPath(at: directory)
        let store = try resolveRealPath(at: root)
        guard resolved != store, resolved == store + "/.git" || !PathSyntax.hasPrefix(resolved, store + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileService().requireStoreMetadataAccess(resolved, root: root)
        return resolved
    }

}

extension FileService {
    fileprivate func requireStoreMetadataAccess(_ metadata: String, root: String) throws {
        guard sameStoreDevice(metadata, root) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV), userInfo: [
                NSLocalizedDescriptionKey: "Pensieve can't sync because git's folder is on another volume."
            ])
        }
        guard access(metadata, W_OK | X_OK) == 0 else {
            throw storePublicationError(at: metadata, code: errno)
        }
    }
}

// The same resolved path keys body writes and vendor, manifest and machine-state preparations.
extension FileServiceProtocol {
    func storeKey(root: String) throws -> String {
        let store = try resolvedStoreLocation(root: root).path
        return storeKey(resolvedPath: store)
    }

    fileprivate func storeKey(resolvedPath: String) -> String {
        SHA256.hash(data: Data(resolvedPath.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Missing components inherit the nearest existing ancestor's device and resolved spelling.
    /// A present but unresolvable entry (including a dangling link) always throws.
    func resolvedStoreLocation(root: String) throws -> (path: String, existingAncestor: String) {
        do {
            let path = try resolveRealPath(at: root)
            return (path, path)
        } catch {
            guard try entryTypeWithoutFollowingLinks(at: root) == nil else { throw error }
        }
        let parent = (root as NSString).deletingLastPathComponent
        guard parent != root, !(root == "." && parent.isEmpty) else { throw CocoaError(.fileNoSuchFile) }
        let location = try resolvedStoreLocation(root: parent.isEmpty ? "." : parent)
        let path = (location.path as NSString).appendingPathComponent((root as NSString).lastPathComponent)
        return (path, location.existingAncestor)
    }
}
