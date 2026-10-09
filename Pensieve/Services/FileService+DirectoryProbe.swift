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
