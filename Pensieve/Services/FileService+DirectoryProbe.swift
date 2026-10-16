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
protocol FileEntryObserving {
    func entryObservation(at path: String) throws -> Data
}

extension FileService: FileEntryObserving {
    func entryObservation(at path: String) throws -> Data {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // Access time changes while taking the token. Modification/change times and identity do not.
        return Data("\(info.st_mode):\(info.st_dev):\(info.st_ino):\(info.st_size):"
            .appending("\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):")
            .appending("\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_flags)").utf8)
    }
}

extension FileServiceProtocol {
    func manifestEntryObservation(at path: String) -> Data {
        if let observer = self as? FileEntryObserving {
            do { return try observer.entryObservation(at: path) } catch {
                let failure = error as NSError
                return Data("unobserved:\(failure.domain):\(failure.code)".utf8)
            }
        }
        let identity = fileIdentity(at: path, followingLinks: false)
        let metadata = regularFileMetadata(at: path)
        return Data("\(String(describing: identity)):\(String(describing: metadata))".utf8)
    }
}
