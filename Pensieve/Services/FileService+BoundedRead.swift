import Darwin
import Foundation

extension FileService {
    /// Reads one bounded regular file through one no-follow descriptor. `O_NONBLOCK` ensures a FIFO
    /// substituted before `open` cannot hang the caller, while `fstat` rejects every non-regular node.
    /// The size is checked both before and during the read because another process can grow a file
    /// after it is opened. (PLAN-39 / 39.1.)
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        try readRegularFileData(at: path, maximumBytes: maximumBytes, read: Darwin.read)
    }

    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        try readRegularFileData(at: path, maximumBytes: maximumBytes, read: Darwin.read, containedIn: directory)
    }

    /// The injected syscall keeps descriptor admission and the read loop together when testing
    /// concurrent growth. The normal entry point always uses Darwin.read.
    func readRegularFileData(at path: String, maximumBytes: Int,
                             read: (Int32, UnsafeMutableRawPointer?, Int) -> Int,
                             containedIn directory: String? = nil
    ) throws -> Data {
        guard maximumBytes >= 0 else { throw CocoaError(.fileReadTooLarge) }
        let (descriptor, status) = try Self.openRegularFile(at: path)
        defer { close(descriptor) }
        if let directory {
            // URL.standardizedFileURL strips /private on macOS; F_GETPATH retains it.
            let root = realPath(at: directory)
            var openedPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &openedPath) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let resolved = String(cString: openedPath)
            guard resolved.hasPrefix(root + "/") else { throw CocoaError(.fileReadNoPermission) }
        }
        guard status.st_size >= 0, status.st_size <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }

        var data = Data()
        let bufferSize = min(max(maximumBytes, 1), 64 * 1_024)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let remaining = maximumBytes - data.count
            // At most one byte beyond the cap, without overflowing an Int.max limit.
            let requestCount = remaining < buffer.count ? remaining + 1 : buffer.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, requestCount)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
            guard count <= maximumBytes, data.count <= maximumBytes - count else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(buffer, count: count)
        }
    }

    /// Prefix admission uses the same regular-leaf helper and one bounded retained buffer.
    /// It does not infer equality or completeness for bytes beyond the requested prefix.
    func readRegularFilePrefix(at path: String, maximumBytes: Int) throws -> Data {
        try readRegularFilePrefix(at: path, maximumBytes: maximumBytes, allocation: { _ in })
    }

    /// Reports the retained buffer size at allocation for resource regression tests.
    func readRegularFilePrefix(at path: String, maximumBytes: Int, allocation: (Int) -> Void) throws -> Data {
        guard maximumBytes >= 0 else { throw CocoaError(.fileReadTooLarge) }
        let (descriptor, status) = try Self.openRegularFile(at: path)
        defer { close(descriptor) }
        guard status.st_size >= 0 else { throw CocoaError(.fileReadUnknown) }
        // maximumBytes includes the caller's one lookahead byte. Never reserve the whole
        // text bound for a small file; retain only min(bound, admitted size) + 1.
        let capacity = maximumBytes == 0 ? 0 : min(maximumBytes - 1, Int(status.st_size)) + 1
        var result = Data(count: capacity)
        allocation(result.count)
        var offset = 0
        while offset < result.count {
            try Task.checkCancellation()
            let requested = min(64 * 1_024, result.count - offset)
            let count = result.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress?.advanced(by: offset), requested) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw DescriptorFileCopy.error("read", path: path, code: errno) }
            if count == 0 { break }
            offset += count
        }
        result.count = offset
        return result
    }

    /// Admit one regular leaf for reading, copying or timestamp updates, optionally relative to a
    /// held directory. Creation is exclusive for atomic copy siblings. Failed admission removes any
    /// created leaf and closes the descriptor; success transfers temporary-file cleanup to the caller.
    /// The injected inspection syscall lets tests force failure after exclusive creation.
    static func openRegularFile(at path: String, relativeTo directory: Int32 = AT_FDCWD,
                                creatingWithPermissions permissions: mode_t? = nil,
                                reportingPath: String? = nil,
                                inspect: (Int32, UnsafeMutablePointer<stat>) -> Int32 = Darwin.fstat
    ) throws -> (descriptor: Int32, status: stat) {
        let errorPath = reportingPath ?? path
        let access = permissions == nil ? O_RDONLY : O_WRONLY | O_CREAT | O_EXCL
        let descriptor = openat(directory, path, access | O_NOFOLLOW | O_NONBLOCK, permissions ?? 0)
        guard descriptor >= 0 else {
            let errorCode = errno
            let operation = directory == AT_FDCWD ? "open" : "openat"
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode),
                          userInfo: [NSFilePathErrorKey: errorPath,
                                     NSLocalizedDescriptionKey:
                                        "\(operation)(\(errorPath)): " + String(cString: strerror(errorCode))])
        }
        do {
            var status = stat()
            guard inspect(descriptor, &status) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let kind = status.st_mode & S_IFMT
            guard kind == S_IFREG else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(kind == S_IFDIR ? EISDIR : EFTYPE),
                              userInfo: [NSFilePathErrorKey: errorPath,
                                         NSLocalizedDescriptionKey: "not a regular file: \(errorPath)"])
            }
            return (descriptor, status)
        } catch {
            if permissions != nil {
                // Copy siblings have fresh UUID names created by this call with O_EXCL, so this
                // name-based unlink cannot remove a pre-existing leaf. Keep the directory held.
                unlinkat(directory, path, 0)
            }
            close(descriptor)
            throw error
        }
    }
}
