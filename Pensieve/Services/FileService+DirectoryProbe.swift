import Darwin
import Foundation

extension FileService {
    func directoryEntryIdentity(at path: String) -> Data? {
        let parent = (path as NSString).deletingLastPathComponent
        guard let identity = fileIdentity(at: parent, followingLinks: true) else { return nil }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_NAME)
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) + 16)
        let name: Data? = buffer.withUnsafeMutableBytes { bytes in
            guard getattrlist(path, &attributes, bytes.baseAddress, bytes.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return nil }
            let reference = bytes.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset)
            let count = Int(reference.attr_length)
            guard start >= 12, count > 0, start <= bytes.count - count else { return nil }
            return Data(bytes[start..<(start + count - 1)])
        }
        guard let name else { return nil }
        return Data("\(identity.device):\(identity.inode):".utf8) + name
    }

    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        var info = stat()
        let status = followingLinks ? stat(path, &info) : lstat(path, &info)
        return status == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }

    func realPath(at path: String) -> String {
        (try? resolveRealPath(at: path)) ?? path
    }

    func resolveRealPath(at path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Optional native entry observations for repair confirmation. The base filesystem protocol stays
/// unchanged; adapters without this capability still expose their type, identity and regular size.
struct FileEntryObservation {
    let type: FileEntryType?
    let metadata: Data
}

protocol FileEntryObserving {
    func entryObservation(at path: String) throws -> FileEntryObservation
}

extension FileService: FileEntryObserving {
    func entryObservation(at path: String) throws -> FileEntryObservation {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let type: FileEntryType
        switch info.st_mode & S_IFMT {
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        case S_IFREG: type = .regular
        default: type = .other
        }
        // Access time changes while taking the token. Modification/change times and identity do not.
        return FileEntryObservation(type: type, metadata: Data("\(info.st_mode):\(info.st_dev):\(info.st_ino):\(info.st_size):"
            .appending("\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):")
            .appending("\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_flags)").utf8))
    }
}

extension FileServiceProtocol {
    func manifestEntryObservation(at path: String) -> FileEntryObservation {
        if let observer = self as? FileEntryObserving {
            do { return try observer.entryObservation(at: path) } catch {
                let failure = error as NSError
                return FileEntryObservation(type: nil, metadata: Data("unobserved:\(failure.domain):\(failure.code)".utf8))
            }
        }
        let identity = fileIdentity(at: path, followingLinks: false)
        let metadata = regularFileMetadata(at: path)
        return FileEntryObservation(type: try? entryTypeWithoutFollowingLinks(at: path),
            metadata: Data("\(String(describing: identity)):\(String(describing: metadata))".utf8))
    }
}

enum StoreContainerError: LocalizedError {
    case linked(String)

    var errorDescription: String? {
        switch self {
        case .linked(let path):
            "“\((path as NSString).abbreviatingWithTildeInPath)” is a link to another folder. "
                + "Pensieve needs a real folder there."
        }
    }
}

extension FileServiceProtocol {
    /// Store-owned containers may be absent, but a present entry must be a real directory.
    /// Links above the store root still resolve normally; links inside it are never admitted.
    func storeContainerExists(at path: String) throws -> Bool {
        guard let type = try entryTypeWithoutFollowingLinks(at: path) else { return false }
        if type == .symlink { throw StoreContainerError.linked(path) }
        guard type == .directory else { throw CocoaError(.fileReadUnsupportedScheme) }
        return true
    }

    /// Compare one directory entry with its resolved parent. Missing leaves inherit the parent's
    /// spelling, so links in ancestors and /private aliases resolve identically on both sides.
    func isRealpathContained(_ path: String) -> Bool {
        guard !isSymlink(at: path) else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let leaf = (path as NSString).lastPathComponent
        let expected = realPath(at: parent) + "/" + leaf
        do { return try resolveRealPath(at: path) == expected } catch {
            // Only a missing entry may inherit its parent's spelling. Resolution failures
            // for present or unreadable entries must not turn the literal path into proof.
            do { return try entryTypeWithoutFollowingLinks(at: path) == nil } catch { return false }
        }
    }
}
