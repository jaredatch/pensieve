import Darwin
import Foundation

// MARK: - Protocol

protocol FileServiceProtocol {
    func readFile(at path: String) throws -> String
    func readData(at path: String) throws -> Data
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data
    func writeFile(at path: String, content: String) throws
    func writeData(at path: String, data: Data) throws
    func writeExecutableFile(at path: String, content: String) throws
    func copyFile(at sourcePath: String, to destinationPath: String) throws
    func deleteFile(at path: String) throws
    func fileExists(at path: String) -> Bool
    /// The final entry itself, including dangling links. Only ENOENT is absence; other failures throw.
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool
    func isExecutableFile(at path: String) -> Bool
    func isUserExecutableFile(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool
    func createDirectory(at path: String) throws
    func deleteDirectory(at path: String) throws
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws
    func symlinkTarget(at path: String) throws -> String
    func isSymlink(at path: String) -> Bool
    func isRegularFile(at path: String) -> Bool
    func listDirectory(at path: String) throws -> [String]
    func contentsHash(at path: String) throws -> String
    /// The file system's identity for a path — device and inode: the link itself when
    /// `followingLinks` is false, what it reaches when true; nil when nothing is there. Two spellings
    /// of one directory (case on a case-insensitive volume, a link and its target) share it; two
    /// directories never do. (PLAN-30 / 30.2 review; inert default below.)
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity?
    /// `realpath(3)`: every link resolved and `/private` kept, unlike `resolvingSymlinksInPath`. A path
    /// that does not exist comes back as given. (Inert default below.)
    func realPath(at path: String) -> String
    func regularFileMetadata(at path: String) -> RegularFileMetadata?
    func touchRegularFile(at path: String, date: Date) throws
}

/// A file's identity on its volume; see `FileServiceProtocol.fileIdentity(at:followingLinks:)`.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

struct RegularFileMetadata: Equatable {
    let byteCount: Int
    let modificationDate: Date
}

// MARK: - Default implementations

extension FileServiceProtocol {
    /// Existing doubles refuse byte writes unless they explicitly support them; never fall through to host I/O.
    func writeData(at path: String, data: Data) throws {
        throw CocoaError(.featureUnsupported)
    }

    /// Inert default: an unmodeled lookup is unknown and performs no host I/O.
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        throw CocoaError(.fileReadUnknown)
    }

    /// Inert default: a double that does not model identity answers "unknown", and a
    /// consumer falls back to spelling.
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? { nil }

    /// Inert default: no resolution.
    func realPath(at path: String) -> String { path }

    /// Inert default: a double that does not model regular-file metadata answers unknown.
    func regularFileMetadata(at path: String) -> RegularFileMetadata? { nil }

    /// Inert default: a double that does not model file timestamps does no host I/O.
    func touchRegularFile(at path: String, date: Date) throws {}

    /// Binary-safe read for vendored assets. The regular-file guard uses lstat semantics so callers
    /// never follow a symlinked leaf while hashing untrusted repository content.
    func readData(at path: String) throws -> Data {
        guard isRegularFile(at: path) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Reads one bounded regular file through one no-follow descriptor. `O_NONBLOCK` ensures a FIFO
    /// substituted before `open` cannot hang the caller, while `fstat` rejects every non-regular node.
    /// The size is checked both before and during the read because another process can grow a file
    /// after it is opened. (PLAN-39 / 39.1.)
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        try FileService().readRegularFileData(at: path, maximumBytes: maximumBytes)
    }

    /// Copy one untrusted repository entry through one no-follow descriptor, so the regular-file check
    /// and byte read refer to the same file object even if the checkout changes concurrently. Intermediate
    /// directory resolution remains path-based by design: that requires a same-user concurrent attacker and
    /// is outside the store threat model, consistent with `safeSkillDirectory`. `O_NONBLOCK` keeps a
    /// substituted FIFO from blocking the open before `fstat` can reject it — for a regular file the
    /// flag has no effect on the subsequent reads.
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        let fd = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open(\(sourcePath)): " + String(cString: strerror(errno))
                ]
            )
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EFTYPE),
                userInfo: [
                    NSLocalizedDescriptionKey: "not a regular file: \(sourcePath)"
                ]
            )
        }
        let data = handle.readDataToEndOfFile()
        let created = FileManager.default.createFile(
            atPath: destinationPath,
            contents: data,
            attributes: [.posixPermissions: status.st_mode & 0o777]
        )
        guard created, FileManager.default.fileExists(atPath: destinationPath) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [
                    NSLocalizedDescriptionKey: "failed to create \(destinationPath)"
                ]
            )
        }
    }

    /// True iff the owner/user executable bit is set on a regular file. Group/world execute bits do
    /// not participate in the stable installed-skill hash.
    func isUserExecutableFile(at path: String) -> Bool {
        guard isRegularFile(at: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.uint16Value & 0o100 != 0
    }

    /// Write `content`, then set the file mode to 0700 (owner rwx only). Provided as a default so every
    /// conformer (the concrete `FileService`, any test stub) inherits it unchanged. The `setAttributes`
    /// call lives INSIDE the FileService layer — the one layer permitted to touch `FileManager` — so it
    /// is within the single-chokepoint boundary, not a bypass. Used for the git askpass helper.
    /// (PLAN-08 / 08.2)
    func writeExecutableFile(at path: String, content: String) throws {
        try writeFile(at: path, content: content)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    /// Atomically replace the item at `path` with the freshly-built one at `sourcePath` (which is
    /// consumed). When `path` already exists this is a single-syscall atomic SWAP (`renamex_np` with
    /// `RENAME_SWAP`) followed by best-effort removal of the displaced old item, so a concurrent reader
    /// sees either the WHOLE old item or the WHOLE new item — never a partial one. When `path` does not
    /// exist yet, the source is atomically moved into place. `sourcePath` MUST be on the same volume as
    /// `path` (a sibling temp path) — a cross-volume swap is not atomic and `renamex_np` rejects it.
    /// Like `writeExecutableFile`, this default lives in the FileService layer — the one layer permitted
    /// to touch `FileManager`/Darwin — so it is inside the single-chokepoint boundary, not a bypass.
    /// (PLAN-12 / 12.3 — the atomic manifest write.)
    func replaceItem(at path: String, with sourcePath: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            guard renamex_np(sourcePath, path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
            try? FileManager.default.removeItem(atPath: sourcePath)   // now holds the displaced old item
        } else {
            try FileManager.default.moveItem(atPath: sourcePath, toPath: path)   // atomic create
        }
    }

    /// True iff `path` is a REGULAR file that exists — not a symlink, directory, FIFO, socket, or device
    /// node. Uses `attributesOfItem` (lstat semantics — does NOT follow the final component), so a
    /// SYMLINKED leaf resolves as `.typeSymbolicLink`, not `.typeRegular`, and is rejected WITHOUT being
    /// followed; a special node resolves as its own type and is rejected too. This is the distinction
    /// `fileExists` cannot make — it follows symlinks and returns true for FIFOs/sockets/devices. Like
    /// the other defaults it lives in the FileService/FileManager chokepoint, so no test double
    /// reimplements it. (PLAN-12 / 12.7 Layer-2 — the leaf-read guard's regular-file contract.)
    func isRegularFile(at path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.type] as? FileAttributeType == .typeRegular
    }
}

// MARK: - Implementation

final class FileService: FileServiceProtocol {
    private let fm = FileManager.default

    func readFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeFile(at path: String, content: String) throws {
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent().path
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Preserve arbitrary bytes and replace an existing destination only once the complete write succeeds.
    func writeData(at path: String, data: Data) throws {
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent().path
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    func deleteFile(at path: String) throws {
        try fm.removeItem(atPath: path)
    }

    func fileExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    func isExecutableFile(at path: String) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    func directoryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func createDirectory(at path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func deleteDirectory(at path: String) throws {
        try fm.removeItem(atPath: path)
    }

    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws {
        let parentDir = URL(fileURLWithPath: linkPath).deletingLastPathComponent().path
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }
        // Remove stale symlink or file if it exists
        if fm.fileExists(atPath: linkPath) || isSymlink(at: linkPath) {
            try fm.removeItem(atPath: linkPath)
        }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
    }

    func symlinkTarget(at path: String) throws -> String {
        try fm.destinationOfSymbolicLink(atPath: path)
    }

    func isSymlink(at path: String) -> Bool {
        let attrs = try? fm.attributesOfItem(atPath: path)
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? {
        var info = stat()
        let status = followingLinks ? stat(path, &info) : lstat(path, &info)
        return status == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }

    func realPath(at path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Reads size and recency from one `lstat`, refusing links and non-regular nodes without opening them.
    func regularFileMetadata(at path: String) -> RegularFileMetadata? {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              let byteCount = Int(exactly: status.st_size) else { return nil }
        let seconds = TimeInterval(status.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return RegularFileMetadata(
            byteCount: byteCount,
            modificationDate: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }

    /// Updates recency through a no-follow descriptor whose type is checked before `futimens`.
    func touchRegularFile(at path: String, date: Date) throws {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
        }
        let interval = date.timeIntervalSince1970
        let seconds = floor(interval)
        let nanoseconds = Int64((interval - seconds) * 1_000_000_000)
        var times = [
            status.st_atimespec,
            Self.normalizedTimespec(seconds: Int(seconds), nanoseconds: nanoseconds)
        ]
        guard futimens(descriptor, &times) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func normalizedTimespec(seconds: Int, nanoseconds: Int64) -> timespec {
        let billion: Int64 = 1_000_000_000
        let carriedSeconds = nanoseconds / billion
        let remainder = nanoseconds % billion
        return timespec(
            tv_sec: seconds + Int(carriedSeconds),
            tv_nsec: Int(remainder)
        )
    }

    func listDirectory(at path: String) throws -> [String] {
        try fm.contentsOfDirectory(atPath: path)
    }

    func contentsHash(at path: String) throws -> String {
        let content = try readFile(at: path)
        // Simple hash using Swift's built-in Hasher for content comparison
        var hasher = Hasher()
        hasher.combine(content)
        let hash = hasher.finalize()
        return String(format: "%016x", hash)
    }
}
