import Darwin
import Foundation

// MARK: - Protocol

protocol FileServiceProtocol {
    func readFile(at path: String) throws -> String
    func readData(at path: String) throws -> Data
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data
    func readRegularFileHeader(at path: String, maximumBytes: Int) throws -> Data
    /// Checks the opened inode's resolved path is inside this directory before reading any bytes.
    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data
    func writeFile(at path: String, content: String) throws
    func writeData(at path: String, data: Data) throws
    func writeExecutableFile(at path: String, content: String) throws
    func copyFile(at sourcePath: String, to destinationPath: String) throws
    /// Copies regular entries from one no-follow directory descriptor; never traverses child links.
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws -> RegularFileCopyReceipt
    func deleteFile(at path: String) throws
    func fileExists(at path: String) -> Bool
    /// The final entry itself, including dangling links. Only ENOENT is absence; other failures throw.
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool
    /// No-follow entry type. Only ENOENT is nil; every other lookup failure throws.
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType?
    func isExecutableFile(at path: String) -> Bool
    func isUserExecutableFile(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool
    /// Follows links. Missing/non-directory is false; other lookup failures throw.
    func directoryExistsFollowingLinks(at path: String) throws -> Bool
    func createDirectory(at path: String) throws
    /// Reuses directories (following links), or creates one level without creating parents.
    func createDirectoryWithoutParents(at path: String) throws
    func writeFileWithoutParents(at path: String, content: String) throws
    /// Replaces only links. A non-link occupant throws SymlinkCreationError.occupiedPath.
    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws
    func deleteDirectory(at path: String) throws
    /// Replaces only links. A non-link occupant throws SymlinkCreationError.occupiedPath.
    func createSymlink(at linkPath: String, pointingTo targetPath: String) throws
    func symlinkTarget(at path: String) throws -> String
    func isSymlink(at path: String) -> Bool
    func isRegularFile(at path: String) -> Bool
    func listDirectory(at path: String) throws -> [String]
    /// Proves read and search access to a folder without enumerating its entries.
    func checkDirectoryReadable(at path: String) throws
    func contentsHash(at path: String) throws -> String
    /// The file system's identity for a path — device and inode: the link itself when
    /// `followingLinks` is false, what it reaches when true; nil when nothing is there. Two spellings
    /// of one directory (case on a case-insensitive volume, a link and its target) share it; two
    /// directories never do. (PLAN-30 / 30.2 review; inert default below.)
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity?
    /// `realpath(3)`: every link resolved and `/private` kept, unlike `resolvingSymlinksInPath`. A path
    /// that does not exist comes back as given. (Inert default below.)
    func realPath(at path: String) -> String
    /// Resolves every link with realpath(3); every failure, including absence, throws.
    func resolveRealPath(at path: String) throws -> String
    func regularFileMetadata(at path: String) -> RegularFileMetadata?
    func touchRegularFile(at path: String, date: Date) throws
}

enum FileEntryType { case directory, symlink, regular, other }

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
    /// Inert default: an unmodeled directory probe is unknown and never accesses the host.
    func checkDirectoryReadable(at path: String) throws { throw CocoaError(.fileReadUnknown) }

    /// Existing doubles refuse byte writes unless they explicitly support them; never fall through to host I/O.
    func writeData(at path: String, data: Data) throws {
        throw CocoaError(.featureUnsupported)
    }

    /// Inert default: an unmodeled lookup is unknown and performs no host I/O.
    func entryExistsWithoutFollowingLinks(at path: String) throws -> Bool {
        throw CocoaError(.fileReadUnknown)
    }

    /// Inert default: an unmodeled entry type is unknown and performs no host I/O.
    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        throw CocoaError(.fileReadUnknown)
    }

    /// Inert default: a double that does not model identity answers "unknown", and a
    /// consumer falls back to spelling.
    func fileIdentity(at path: String, followingLinks: Bool) -> FileIdentity? { nil }

    /// Inert default: no resolution.
    func realPath(at path: String) -> String { path }

    /// Inert default: unmodeled resolution is unknown and performs no host I/O.
    func resolveRealPath(at path: String) throws -> String { throw CocoaError(.fileReadUnknown) }

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

    /// Inert default: doubles must explicitly model bounded reads; never fall through to host I/O.
    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    /// Inert default: containment must be modeled explicitly, never reduced to an unguarded read.
    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    /// Copy one untrusted repository entry through one no-follow descriptor, so the regular-file check
    /// and byte read refer to the same file object even if the checkout changes concurrently. Intermediate
    /// directory resolution remains path-based by design: that requires a same-user concurrent attacker and
    /// is outside the store threat model, consistent with `safeSkillDirectory`. `O_NONBLOCK` keeps a
    /// substituted FIFO from blocking the open before `fstat` can reject it — for a regular file the
    /// flag has no effect on the subsequent reads.
    func copyFile(at sourcePath: String, to destinationPath: String) throws {
        let (fd, status) = try FileService.openRegularFile(at: sourcePath)
        defer { close(fd) }
        try DescriptorFileCopy.copy(from: fd, status: status, sourcePath: sourcePath, to: destinationPath)
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
    let directoryProbe: (String) throws -> Bool

    init(directoryProbe: @escaping (String) throws -> Bool = FileService.probeDirectory) {
        self.directoryProbe = directoryProbe
    }

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
        try writeFileWithoutParents(at: path, content: content)
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
        try entryTypeWithoutFollowingLinks(at: path) != nil
    }

    func entryTypeWithoutFollowingLinks(at path: String) throws -> FileEntryType? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        case S_IFREG: return .regular
        default: return .other
        }
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
        try createSymlinkWithoutParents(at: linkPath, pointingTo: targetPath)
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
        let (descriptor, status) = try Self.openRegularFile(at: path)
        defer { close(descriptor) }
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
