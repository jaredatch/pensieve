import Darwin
import Foundation

extension FileServiceProtocol {
    /// Unmodeled probes and nonrecursive writes fail without accessing the host filesystem.
    func directoryExistsFollowingLinks(at path: String) throws -> Bool { throw CocoaError(.fileReadUnknown) }
    func createDirectoryWithoutParents(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func writeFileWithoutParents(at path: String, content: String) throws { throw CocoaError(.featureUnsupported) }
    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    func requireProjectDirectory(at path: String) throws {
        let exists: Bool
        do {
            exists = try directoryExistsFollowingLinks(at: path)
        } catch {
            throw ProjectFolderError.couldNotCheck(path: path, reason: error.localizedDescription)
        }
        guard exists else { throw ProjectFolderError.missing(path) }
    }

    func writeFileInProject(at path: String, content: String, projectPath: String) throws {
        try writeInProject(at: path, projectPath: projectPath) {
            try writeFileWithoutParents(at: path, content: content)
        }
    }

    func createSymlinkInProject(at path: String, pointingTo target: String, projectPath: String) throws {
        try writeInProject(at: path, projectPath: projectPath) {
            try createSymlinkWithoutParents(at: path, pointingTo: target)
        }
    }

    /// The supplied writer stays private; callers pass content or a target to the bounded methods.
    private func writeInProject(at artifactPath: String, projectPath: String, write: () throws -> Void) throws {
        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard artifactPath.hasPrefix(prefix) else { throw CocoaError(.fileWriteInvalidFileName) }
        let components = artifactPath.dropFirst(prefix.count).split(separator: "/")
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try requireProjectDirectory(at: projectPath)
        do {
            var directory = projectPath
            for component in components.dropLast() {
                directory += "/" + component
                try createDirectoryWithoutParents(at: directory)
            }
            try write()
        } catch {
            // A missing root has one typed error even if it vanished during mkdir or the final write.
            // Inconclusive rechecks must not replace the original creating error.
            if let exists = try? directoryExistsFollowingLinks(at: projectPath), !exists {
                throw ProjectFolderError.missing(projectPath)
            }
            throw error
        }
    }
}

extension FileService {
    func directoryExistsFollowingLinks(at path: String) throws -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
        return (status.st_mode & S_IFMT) == S_IFDIR
    }

    func createDirectoryWithoutParents(at path: String) throws {
        try createDirectoryWithoutParents(at: path, beforeCreate: { _ in })
    }

    /// The checkpoint can stage a race but cannot replace the real nonrecursive mkdir.
    func createDirectoryWithoutParents(at path: String, beforeCreate: (String) throws -> Void) throws {
        if try directoryExistsFollowingLinks(at: path) { return }
        do {
            try beforeCreate(path)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            // A concurrent creator may have won. Accept only a directory, including a link to one.
            guard try directoryExistsFollowingLinks(at: path) else { throw error }
        }
    }

    func writeFileWithoutParents(at path: String, content: String) throws {
        try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        let manager = FileManager.default
        if let type = try entryTypeWithoutFollowingLinks(at: linkPath) {
            guard type == .symlink || type == .regular else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: linkPath])
            }
            // unlink never removes a directory, even if it replaces the checked entry in this window.
            if unlink(linkPath) != 0 && errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: linkPath])
            }
        }
        try manager.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
    }
}
