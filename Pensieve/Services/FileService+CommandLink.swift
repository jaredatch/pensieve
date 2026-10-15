import Darwin
import Foundation

struct CommandLinkEntry: Equatable, Codable {
    enum Kind: String, Codable { case directory, symlink, socket, other }
    let kind: Kind
    let owner: UInt32
    let device: Int32
    let inode: UInt64
    let target: String?
}

enum CommandLinkAction: String, Codable { case install, uninstall, repair }

struct CommandLinkRequest: Codable {
    let action: CommandLinkAction
    let directory: String
    let executable: String
    let user: UInt32
    let expected: CommandLinkEntry?
}

struct CommandLinkError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension FileServiceProtocol {
    /// Unmodeled privileged operations refuse without reading or changing host paths.
    func commandLinkEntry(at path: String) throws -> CommandLinkEntry? { throw CocoaError(.featureUnsupported) }
    func changeCommandLink(_ request: CommandLinkRequest) throws { throw CocoaError(.featureUnsupported) }
}

extension FileService {
    func commandLinkEntry(at path: String) throws -> CommandLinkEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw commandLinkSystemError(path)
        }
        let kind: CommandLinkEntry.Kind = info.st_mode & S_IFMT == S_IFDIR ? .directory
            : (info.st_mode & S_IFMT == S_IFLNK ? .symlink : (info.st_mode & S_IFMT == S_IFSOCK ? .socket : .other))
        return CommandLinkEntry(kind: kind, owner: info.st_uid, device: info.st_dev, inode: info.st_ino,
                                target: kind == .symlink ? try symlinkTarget(at: path) : nil)
    }

    /// Rechecks after authorization. Parent descriptors prevent a replaced directory symlink from
    /// redirecting privileged writes. Creation is exclusive; removal requires the inspected inode.
    func changeCommandLink(_ request: CommandLinkRequest) throws {
        let directory = URL(fileURLWithPath: request.directory)
        let parent = directory.deletingLastPathComponent().path
        let leaf = directory.lastPathComponent
        guard PathSyntax.isAbsolute(request.directory), leaf == "bin" else {
            throw CommandLinkError(message: "The command folder must be an absolute bin directory.")
        }
        let parentFD = try Self.openDirectory(at: parent, reportingPath: parent, operation: "open")
        defer { close(parentFD) }
        try checkCommandDirectory(parentFD, user: request.user, path: parent)
        if mkdirat(parentFD, leaf, 0o755) != 0 && errno != EEXIST {
            throw commandLinkSystemError(request.directory)
        }
        let folderFD = try Self.openDirectory(at: leaf, relativeTo: parentFD,
                                             reportingPath: request.directory, operation: "openat")
        defer { close(folderFD) }
        try checkCommandDirectory(folderFD, user: request.user, path: request.directory)
        let path = request.directory + "/pensieve"
        // Check the pathname still names the opened parent, then inspect the current leaf.
        var folderInfo = stat()
        guard fstat(folderFD, &folderInfo) == 0,
              let currentFolder = try commandLinkEntry(at: request.directory),
              currentFolder.device == folderInfo.st_dev, currentFolder.inode == folderInfo.st_ino else {
            throw CommandLinkError(message: "The command folder changed. Nothing was changed.")
        }
        let current = try commandLinkEntry(at: path)
        guard current == request.expected else {
            throw CommandLinkError(message: "Something appeared or changed at \(path). The link wasn't changed.")
        }
        try removeCommandLinkIfNeeded(request, current: current, folderFD: folderFD, path: path)
        if request.action != .uninstall {
            guard symlinkat(request.executable, folderFD, "pensieve") == 0 else {
                throw CommandLinkError(message: "The link wasn't made at \(path): \(String(cString: strerror(errno))). "
                    + "The command folder was kept.")
            }
        }
    }

    private func removeCommandLinkIfNeeded(_ request: CommandLinkRequest, current: CommandLinkEntry?,
                                           folderFD: Int32, path: String) throws {
        if request.action == .install {
            guard current == nil else { throw CommandLinkError(message: "\(path) is already occupied.") }
        } else {
            guard let current, current.kind == .symlink, let target = current.target,
                  try CommandLinkOwnership.isPensieve(target, files: self),
                  try (request.action != .repair || CommandLinkOwnership.isMissingApp(target, files: self)) else {
                throw CommandLinkError(message: "\(path) no longer holds the Pensieve link to change.")
            }
            var leafInfo = stat()
            guard fstatat(folderFD, "pensieve", &leafInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  leafInfo.st_dev == current.device, leafInfo.st_ino == current.inode,
                  unlinkat(folderFD, "pensieve", 0) == 0 else { throw commandLinkSystemError(path) }
        }
    }

    private func checkCommandDirectory(_ descriptor: Int32, user: UInt32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw commandLinkSystemError(path) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0 || info.st_uid == user else {
            throw CommandLinkError(message: "\(path) must be a directory owned by root or your user.")
        }
    }

    private func commandLinkSystemError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}

/// A dangling link is recognized by the app/executable spelling, never by resolving its target.
/// Existing apps also prove their bundle identity before their link may be removed.
enum CommandLinkOwnership {
    static func appPath(_ target: String) -> String? {
        guard PathSyntax.isAbsolute(target) else { return nil }
        let url = URL(fileURLWithPath: target)
        let helpers = url.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard url.lastPathComponent == "pensieve", helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", app.pathExtension == "app",
              app.lastPathComponent.hasPrefix("Pensieve"), url.standardized.path == target else { return nil }
        return app.path
    }

    static func isPensieve(_ target: String, files: FileServiceProtocol) throws -> Bool {
        guard let app = appPath(target) else { return false }
        guard try files.entryExistsWithoutFollowingLinks(at: app) else { return true }
        let bytes = try files.readRegularFileData(at: app + "/Contents/Info.plist", maximumBytes: 1_048_576)
        let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        return ["com.jaredatch.Pensieve", "com.jaredatch.Pensieve.debug", "com.jaredatch.Pensieve.dogfood"]
            .contains(info?["CFBundleIdentifier"] as? String ?? "")
    }

    static func isMissingApp(_ target: String, files: FileServiceProtocol) throws -> Bool {
        guard let app = appPath(target) else { return false }
        return try !files.entryExistsWithoutFollowingLinks(at: app)
    }
}
