import Darwin
import Foundation

/// Metadata and live parent descriptors bind the walk and the subsequent leaf admission to one tree.
/// Directory identities are rechecked so a disappeared or replaced directory never becomes an absent file.
final class ComparisonDirectory {
    let path: String
    let stream: UnsafeMutablePointer<DIR>
    let parent: ComparisonDirectory?
    let name: String
    let identity: FileIdentity
    var descriptor: Int32 { dirfd(stream) }

    init(path: String, name: String, parent: ComparisonDirectory?) throws {
        self.path = path
        self.name = name
        self.parent = parent
        let descriptor = try FileService.openDirectory(at: parent == nil ? path : name,
                                                       relativeTo: parent?.descriptor ?? AT_FDCWD,
                                                       reportingPath: path, operation: "open directory")
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw DescriptorFileCopy.error("fdopendir", path: path, code: code)
        }
        self.stream = stream
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            closedir(stream)
            throw DescriptorFileCopy.error("fstat", path: path, code: code)
        }
        identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
        // fstat follows no name; admission already required a directory. Check access on that inode.
        guard faccessat(descriptor, ".", R_OK | X_OK, 0) == 0 else {
            let code = errno
            closedir(stream)
            throw DescriptorFileCopy.error("directory access", path: path, code: code)
        }
    }

    deinit { closedir(stream) }

    func validate() throws {
        try parent?.validate()
        var current = stat()
        guard fstatat(parent?.descriptor ?? AT_FDCWD, parent == nil ? path : name,
                      &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DescriptorFileCopy.error("directory lookup", path: path, code: errno)
        }
        guard current.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(device: current.st_dev, inode: current.st_ino) == identity else {
            throw DescriptorFileCopy.error("directory changed", path: path, code: ESTALE)
        }
    }

    func entries() throws -> [(String, stat)] {
        try validate()
        var result: [(String, stat)] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw DescriptorFileCopy.error("readdir", path: path, code: errno) }
                try validate()
                return result.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DescriptorFileCopy.error("entry lookup", path: path + "/" + name, code: errno)
            }
            result.append((name, status))
        }
    }
}

struct ComparisonFile {
    let directory: ComparisonDirectory
    let name: String
    let status: stat
    var path: String { directory.path + "/" + name }

    func open() throws -> ComparisonOpenedFile {
        try directory.validate()
        let (descriptor, status) = try FileService.openRegularFile(at: name, relativeTo: directory.descriptor,
                                                                  reportingPath: path)
        return ComparisonOpenedFile(descriptor: descriptor, entry: self, initial: status)
    }
}

final class ComparisonOpenedFile {
    let descriptor: Int32
    let entry: ComparisonFile
    let initial: stat
    init(descriptor: Int32, entry: ComparisonFile, initial: stat) {
        self.descriptor = descriptor
        self.entry = entry
        self.initial = initial
    }
    deinit { close(descriptor) }

    func changed() throws -> Bool {
        try entry.directory.validate()
        var current = stat()
        guard fstat(descriptor, &current) == 0 else {
            throw DescriptorFileCopy.error("fstat", path: entry.path, code: errno)
        }
        var named = stat()
        guard fstatat(entry.directory.descriptor, entry.name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DescriptorFileCopy.error("file lookup", path: entry.path, code: errno)
        }
        guard named.st_mode & S_IFMT == S_IFREG else {
            throw DescriptorFileCopy.error("file type changed", path: entry.path, code: EFTYPE)
        }
        return !Self.same(initial, current) || !Self.same(initial, named) || !Self.same(initial, entry.status)
    }

    private static func same(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_size == right.st_size
            && left.st_mode == right.st_mode
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
}

extension FileService {
    func comparisonInventory(at path: String, excludingGit: Bool,
                             checkpoint: (String) throws -> Void) throws -> [String: ComparisonFile] {
        let root = try ComparisonDirectory(path: path, name: "", parent: nil)
        var files: [String: ComparisonFile] = [:]
        try collectComparisonFiles(root, relative: "", excludingGit: excludingGit, files: &files, checkpoint: checkpoint)
        return files
    }

    private func collectComparisonFiles(_ directory: ComparisonDirectory, relative: String, excludingGit: Bool,
                                        files: inout [String: ComparisonFile], checkpoint: (String) throws -> Void) throws {
        try checkpoint(directory.path)
        for (name, status) in try directory.entries() {
            if relative.isEmpty && excludingGit && name == ".git" { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                let child = try ComparisonDirectory(path: directory.path + "/" + name, name: name, parent: directory)
                try collectComparisonFiles(child, relative: path, excludingGit: false, files: &files, checkpoint: checkpoint)
            case S_IFREG:
                files[path] = ComparisonFile(directory: directory, name: name, status: status)
            default:
                throw DescriptorFileCopy.error("symlink or special file", path: directory.path + "/" + name, code: EFTYPE)
            }
        }
        try directory.validate()
    }
}
