import Darwin
import Foundation

extension FileServiceProtocol {
    /// Doubles must model header reads explicitly, never fall through to host I/O.
    func readRegularFileHeader(at path: String, maximumBytes: Int) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }
}

extension FileService {
    /// Reads at most the header cap, stopping at the closing frontmatter fence (or the first
    /// non-frontmatter line). Uses the shared no-follow, non-blocking regular-file admission.
    /// A large body does not prevent recognizing a small marked header. Chunks are at most 512 bytes.
    func readRegularFileHeader(at path: String, maximumBytes: Int) throws -> Data {
        try readRegularFileHeader(at: path, maximumBytes: maximumBytes, read: Darwin.read)
    }

    func readRegularFileHeader(at path: String, maximumBytes: Int,
                               read: (Int32, UnsafeMutableRawPointer?, Int) -> Int) throws -> Data {
        guard maximumBytes >= 0 else { throw CocoaError(.fileReadTooLarge) }
        let (descriptor, _) = try Self.openRegularFile(at: path)
        defer { close(descriptor) }
        var result = Data()
        var line = Data()
        var firstLine = true
        var buffer = [UInt8](repeating: 0, count: 512)
        while result.count < maximumBytes {
            let request = min(buffer.count, maximumBytes - result.count)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, request) }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            for byte in buffer.prefix(count) {
                result.append(byte)
                if byte != 10 { line.append(byte); continue }
                if line.last == 13 { line.removeLast() }
                if firstLine, line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
                let fence = line == Data("---".utf8)
                if firstLine ? !fence : fence { return result }
                firstLine = false
                line.removeAll(keepingCapacity: true)
            }
        }
        // An incomplete bounded header carries no authority, including a partial closing fence.
        return Data()
    }
}
