import Darwin
import Foundation

extension FileService {
    /// Admits one directory without following its leaf, optionally relative to a held parent.
    /// The caller owns the returned descriptor and preserves its operation and path in errors.
    static func openDirectory(at path: String, relativeTo directoryDescriptor: Int32 = AT_FDCWD,
                              reportingPath: String? = nil, operation: String = "open") throws -> Int32 {
        let descriptor = openat(directoryDescriptor, path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DescriptorFileCopy.error(operation, path: reportingPath ?? path, code: errno)
        }
        return descriptor
    }
}

struct FileEntryStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let fileType: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        size = status.st_size
        fileType = status.st_mode & S_IFMT
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

/// Shared by single-file copying and imported-folder copying. A sibling temporary file preserves
/// the destination until rename; descriptor chunks keep memory use independent of file size.
enum DescriptorFileCopy {
    struct Options {
        var maximumBytes = Int.max
        var checkingCancellation = false
        var renameFile: (String, String) -> Int32 = { Darwin.rename($0, $1) }
        var read: (Int32, UnsafeMutableRawPointer?, Int) -> Int = Darwin.read
        func checkCancellation() throws {
            if checkingCancellation { try Task.checkCancellation() }
        }
    }

    static func error(_ operation: String, path: String, code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: "\(operation)(\(path)): " + String(cString: strerror(code))
        ])
    }

    /// The source descriptor and metadata must come from FileService.openRegularFile.
    @discardableResult
    static func copy(from descriptor: Int32, status: stat, sourcePath: String, to destination: String,
                     options: Options, copiedChunk: (Int) throws -> Void = { _ in }) throws -> Int {
        try options.checkCancellation()
        guard options.maximumBytes >= 0, status.st_size >= 0, status.st_size <= options.maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        let temporary = parent + "/.pensieve-copy-" + UUID().uuidString + ".tmp"
        let output = try createTemporary(at: temporary, for: destination, permissions: status.st_mode & 0o777)
        var renamed = false
        defer {
            close(output)
            if !renamed { unlink(temporary) }
        }
        guard fchmod(output, status.st_mode & 0o777) == 0 else { throw error("fchmod", path: destination, code: errno) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total = 0
        while true {
            try options.checkCancellation()
            let remaining = options.maximumBytes - total
            let requested = remaining < buffer.count ? remaining + 1 : buffer.count
            let count = buffer.withUnsafeMutableBytes { options.read(descriptor, $0.baseAddress, requested) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw error("read", path: sourcePath, code: errno)
            }
            guard count <= remaining else { throw CocoaError(.fileReadTooLarge) }
            try writeChunk(buffer, count: count, output: output, destination: destination)
            total += count
            try copiedChunk(count)
        }
        try options.checkCancellation()
        guard options.renameFile(temporary, destination) == 0 else { throw error("rename", path: destination, code: errno) }
        renamed = true
        return total
    }

    private static func createTemporary(at temporary: String, for destination: String, permissions: mode_t) throws -> Int32 {
        do {
            return try FileService.openRegularFile(at: temporary, creatingWithPermissions: permissions).descriptor
        } catch {
            let failure = error as NSError
            throw NSError(domain: failure.domain, code: failure.code, userInfo: [
                NSFilePathErrorKey: temporary,
                NSLocalizedDescriptionKey:
                    "open(\(temporary)) for \(destination): " + String(cString: strerror(Int32(failure.code)))
            ])
        }
    }

    private static func writeChunk(_ buffer: [UInt8], count: Int, output: Int32, destination: String) throws {
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < count {
                let written = Darwin.write(output, bytes.baseAddress?.advanced(by: offset), count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw error("write", path: destination, code: written == 0 ? EIO : errno) }
                offset += written
            }
        }
    }

}
