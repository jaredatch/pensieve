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

    /// Admit one regular leaf for reading, copying or timestamp updates. Failure closes the
    /// descriptor; success transfers it to the caller, who must close it after using this inode.
    static func openRegularFile(at path: String) throws -> (descriptor: Int32, status: stat) {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode),
                          userInfo: [NSLocalizedDescriptionKey: "open(\(path)): " + String(cString: strerror(errorCode))])
        }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let kind = status.st_mode & S_IFMT
            guard kind == S_IFREG else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(kind == S_IFDIR ? EISDIR : EFTYPE),
                              userInfo: [NSLocalizedDescriptionKey: "not a regular file: \(path)"])
            }
            return (descriptor, status)
        } catch {
            close(descriptor)
            throw error
        }
    }
}
