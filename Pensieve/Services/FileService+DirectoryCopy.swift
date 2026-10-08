import Darwin
import Foundation

/// Keeps the descriptor-bound source alive until the caller validates it immediately before swap.
struct RegularFileCopyReceipt {
    let validateSource: () throws -> Void
}

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
        let descriptor: Int32
        do {
            descriptor = try Self.openDirectory(at: source)
        } catch {
            let failure = error as NSError
            guard failure.domain == NSPOSIXErrorDomain,
                  failure.code == Int(ENOENT) || failure.code == Int(ENOTDIR) || failure.code == Int(ELOOP) else {
                throw error
            }
            try checkpoint(.unavailable)
            let initial = try DirectoryCopySource.pathStamp(source)
            guard initial?.fileType != S_IFDIR else {
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
            let (child, status) = try Self.openRegularFile(at: name, relativeTo: descriptor, reportingPath: path)
            defer { close(child) }
            guard FileEntryStamp(status) == opened.entries[name] else {
                throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
            }
            try DescriptorFileCopy.copy(from: child, status: status, sourcePath: path, to: destination + "/" + name,
                                        copiedChunk: { count in
                try checkpoint(.copiedChunk(name, count))
            })
            guard try DirectoryCopySource.descriptorStamp(child, path: path) == opened.entries[name] else {
                throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
            }
        }
        try opened.validate()
        return RegularFileCopyReceipt { try opened.validate() }
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
    var isRegular: Bool { fileType == S_IFREG }

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

/// Owns one no-follow directory stream. Each validation re-lists it and checks the live path,
/// directory identity/timestamps and every entry's identity, type, size, mtime and ctime.
private final class DirectoryCopySource {
    let path: String
    let directory: UnsafeMutablePointer<DIR>
    let initial: FileEntryStamp
    var entries: [String: FileEntryStamp] = [:]
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

    static func descriptorStamp(_ descriptor: Int32, path: String) throws -> FileEntryStamp {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DescriptorFileCopy.error("fstat", path: path, code: errno)
        }
        return FileEntryStamp(status)
    }

    static func pathStamp(_ path: String) throws -> FileEntryStamp? {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw DescriptorFileCopy.error("lstat", path: path, code: code)
        }
        return FileEntryStamp(status)
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
        guard try Self.descriptorStamp(descriptor, path: path) == initial,
              try Self.pathStamp(path) == initial else {
            throw DescriptorFileCopy.error("source changed", path: path, code: ESTALE)
        }
    }

    private func entryStamps() throws -> [String: FileEntryStamp] {
        rewinddir(directory)
        var result: [String: FileEntryStamp] = [:]
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
            result[name] = FileEntryStamp(status)
        }
    }
}

/// Shared by single-file copying and directory-relative carrying. A sibling temporary file preserves
/// the destination until rename; descriptor chunks keep memory use independent of file size.
enum DescriptorFileCopy {
    struct Options {
        var maximumBytes = Int.max
        var renameFile: (String, String) -> Int32 = { Darwin.rename($0, $1) }
        var read: (Int32, UnsafeMutableRawPointer?, Int) -> Int = Darwin.read
    }

    static func error(_ operation: String, path: String, code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: "\(operation)(\(path)): " + String(cString: strerror(code))
        ])
    }

    /// The source descriptor and metadata must come from FileService.openRegularFile.
    static func copy(from descriptor: Int32, status: stat, sourcePath: String, to destination: String,
                     renameFile: (String, String) -> Int32 = { Darwin.rename($0, $1) },
                     copiedChunk: (Int) throws -> Void = { _ in }) throws {
        try withoutActuallyEscaping(renameFile) { renameFile in
            try copy(from: descriptor, status: status, sourcePath: sourcePath, to: destination,
                     options: .init(renameFile: renameFile), copiedChunk: copiedChunk)
        }
    }

    @discardableResult
    static func copy(from descriptor: Int32, status: stat, sourcePath: String, to destination: String,
                     options: Options, copiedChunk: (Int) throws -> Void = { _ in }) throws -> Int {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
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
        try Task.checkCancellation()
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
