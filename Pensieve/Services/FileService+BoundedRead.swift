import Darwin
import Foundation

extension FileService {
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        try readRegularFileData(at: path, maximumBytes: maximumBytes, read: Darwin.read)
    }

    /// The injected syscall keeps descriptor admission and the read loop together when testing
    /// concurrent growth. The normal entry point always uses Darwin.read.
    func readRegularFileData(at path: String, maximumBytes: Int,
                             read: (Int32, UnsafeMutableRawPointer?, Int) -> Int
    ) throws -> Data {
        guard maximumBytes >= 0 else { throw CocoaError(.fileReadTooLarge) }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(kind == S_IFDIR ? EISDIR : EFTYPE))
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

}
