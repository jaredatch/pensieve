import Darwin
import Foundation

/// Keeps the descriptor-bound source alive until the caller validates it immediately before swap.
struct RegularFileCopyReceipt {
    let validateSource: () throws -> Void
}

extension FileService {
    enum DirectoryCopyCheckpoint {
        case opened
        case unavailable
        case copying(String)
        case copiedChunk(String, Int)
    }

    @discardableResult
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws -> RegularFileCopyReceipt {
        try copyRegularFiles(fromDirectory: source, toDirectory: destination, checkpoint: { _ in })
    }

    /// Checkpoints expose opening, child copying and bounded progress, with no host path fallback.
    @discardableResult
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String,
                          checkpoint: (DirectoryCopyCheckpoint) throws -> Void) throws -> RegularFileCopyReceipt {
        let descriptor = open(source, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            guard code == ENOENT || code == ENOTDIR || code == ELOOP else {
                throw DescriptorFileCopy.error("open", path: source, code: code)
            }
            try checkpoint(.unavailable)
            let initial = try DirectoryCopySource.pathStamp(source)
            guard (initial?.mode ?? 0) & S_IFMT != S_IFDIR else {
                throw DescriptorFileCopy.error("source changed", path: source, code: ESTALE)
            }
            return RegularFileCopyReceipt {
                guard try DirectoryCopySource.pathStamp(source) == initial else {
                    throw DescriptorFileCopy.error("source changed", path: source, code: ESTALE)
                }
            }
        }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw DescriptorFileCopy.error("fdopendir", path: source, code: code)
        }
        let opened = try DirectoryCopySource(path: source, directory: directory)
        try checkpoint(.opened)
        try opened.captureEntries()
        for name in opened.entries.keys.sorted() {
            guard opened.entries[name]?.isRegular == true else { continue }
            let path = source + "/" + name
            try checkpoint(.copying(name))
            let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard child >= 0 else { throw DescriptorFileCopy.error("openat", path: path, code: errno) }
            defer { close(child) }
            guard try DirectoryCopySource.descriptorStamp(child, path: path) == opened.entries[name] else {
                throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
            }
            try DescriptorFileCopy.copy(from: child, sourcePath: path, to: destination + "/" + name) { count in
                try checkpoint(.copiedChunk(name, count))
            }
            guard try DirectoryCopySource.descriptorStamp(child, path: path) == opened.entries[name] else {
                throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
            }
        }
        try opened.validate()
        return RegularFileCopyReceipt { try opened.validate() }
    }
}

private struct CopyEntryStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let links: nlink_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    var isRegular: Bool { mode & S_IFMT == S_IFREG }

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        size = status.st_size
        mode = status.st_mode
        links = status.st_nlink
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

/// Owns one no-follow directory stream. Each validation re-lists it and checks the live path,
/// directory identity/mtime and every entry's identity, size, mode, link count and timestamps.
private final class DirectoryCopySource {
    let path: String
    let directory: UnsafeMutablePointer<DIR>
    let initial: CopyEntryStamp
    var entries: [String: CopyEntryStamp] = [:]
    var descriptor: Int32 { dirfd(directory) }

    init(path: String, directory: UnsafeMutablePointer<DIR>) throws {
        self.path = path
        self.directory = directory
        do { initial = try Self.descriptorStamp(dirfd(directory), path: path) } catch {
            closedir(directory)
            throw error
        }
    }
    deinit { closedir(directory) }

    static func descriptorStamp(_ descriptor: Int32, path: String) throws -> CopyEntryStamp {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DescriptorFileCopy.error("fstat", path: path, code: errno)
        }
        return CopyEntryStamp(status)
    }

    static func pathStamp(_ path: String) throws -> CopyEntryStamp? {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw DescriptorFileCopy.error("lstat", path: path, code: code)
        }
        return CopyEntryStamp(status)
    }

    func captureEntries() throws {
        try validateDirectory()
        entries = try entryStamps()
        try validateDirectory()
    }

    func validate() throws {
        try validateDirectory()
        guard try entryStamps() == entries else {
            throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
        }
        try validateDirectory()
    }

    private func validateDirectory() throws {
        guard initial.links > 0,
              try Self.descriptorStamp(descriptor, path: path) == initial,
              try Self.pathStamp(path) == initial else {
            throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
        }
    }

    private func entryStamps() throws -> [String: CopyEntryStamp] {
        rewinddir(directory)
        var result: [String: CopyEntryStamp] = [:]
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw DescriptorFileCopy.error("readdir", path: path, code: errno) }
                return result
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DescriptorFileCopy.error("fstatat", path: path + "/" + name, code: errno)
            }
            result[name] = CopyEntryStamp(status)
        }
    }
}

/// Shared by single-file copying and directory-relative carrying. Memory use is independent of file size.
enum DescriptorFileCopy {
    static func error(_ operation: String, path: String, code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: "\(operation)(\(path)): " + String(cString: strerror(code))
        ])
    }

    static func copy(from descriptor: Int32, sourcePath: String, to destination: String,
                     copiedChunk: (Int) throws -> Void = { _ in }) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw error("fstat", path: sourcePath, code: errno) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw error("not regular", path: sourcePath, code: EFTYPE) }
        let output = open(destination, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, status.st_mode & 0o777)
        guard output >= 0 else { throw error("open", path: destination, code: errno) }
        defer { close(output) }
        guard fchmod(output, status.st_mode & 0o777) == 0 else { throw error("fchmod", path: destination, code: errno) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw error("read", path: sourcePath, code: errno)
            }
            try writeChunk(buffer, count: count, output: output, destination: destination)
            try copiedChunk(count)
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
