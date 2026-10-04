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

    /// Every creating step is nonrecursive, including the supplied artifact writer. Path-based
    /// operations may fail after deletion, but cannot recreate the project or any ancestor.
    func writeInProject(at artifactPath: String, projectPath: String, write: () throws -> Void) throws {
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
            // Interior occupants and write failures keep their original error when the root remains.
            try requireProjectDirectory(at: projectPath)
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
        try createDirectoryWithoutParents(at: path) { directory in
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        }
    }

    /// The injected create operation exercises a directory appearing immediately before mkdir.
    func createDirectoryWithoutParents(at path: String, create: (String) throws -> Void) throws {
        if try directoryExistsFollowingLinks(at: path) { return }
        do {
            try create(path)
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
        if manager.fileExists(atPath: linkPath) || isSymlink(at: linkPath) {
            try manager.removeItem(atPath: linkPath)
        }
        try manager.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
    }
}
