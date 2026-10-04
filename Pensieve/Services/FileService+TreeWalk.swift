import Darwin
import Foundation

/// Inventory identities retain no descriptors. Reopening holds and validates only this parent chain.
final class ComparisonDirectoryReference {
    let path: String
    let name: String
    let parent: ComparisonDirectoryReference?
    let identity: FileIdentity
    let depth: Int

    init(path: String, name: String, parent: ComparisonDirectoryReference?, identity: FileIdentity) {
        self.path = path
        self.name = name
        self.parent = parent
        self.identity = identity
        depth = parent.map { $0.depth + 1 } ?? 0
    }

    func open() throws -> ComparisonDirectory {
        let parent = try parent?.open()
        return try ComparisonDirectory(path: path, name: name, parent: parent, expectedIdentity: identity)
    }
}

/// Owns one live directory during traversal or leaf reading, and closes it when that scope ends.
final class ComparisonDirectory {
    let stream: UnsafeMutablePointer<DIR>
    let parent: ComparisonDirectory?
    let reference: ComparisonDirectoryReference
    var path: String { reference.path }
    var descriptor: Int32 { dirfd(stream) }

    init(path: String, name: String, parent: ComparisonDirectory?, expectedIdentity: FileIdentity? = nil) throws {
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
        let identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
        guard expectedIdentity == nil || expectedIdentity == identity else {
            closedir(stream)
            throw DescriptorFileCopy.error("directory changed", path: path, code: ESTALE)
        }
        guard faccessat(descriptor, ".", R_OK | X_OK, 0) == 0 else {
            let code = errno
            closedir(stream)
            throw DescriptorFileCopy.error("directory access", path: path, code: code)
        }
        reference = ComparisonDirectoryReference(path: path, name: name, parent: parent?.reference, identity: identity)
    }

    deinit { closedir(stream) }

    func validate() throws {
        try parent?.validate()
        var current = stat()
        guard fstatat(parent?.descriptor ?? AT_FDCWD, parent == nil ? path : reference.name,
                      &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DescriptorFileCopy.error("directory lookup", path: path, code: errno)
        }
        guard current.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(device: current.st_dev, inode: current.st_ino) == reference.identity else {
            throw DescriptorFileCopy.error("directory changed", path: path, code: ESTALE)
        }
    }

    /// Stream entries into the shared budget before retaining metadata or opening a child.
    func forEachEntry(excludingGit: Bool, budget: ComparisonInventoryBudget,
                      body: (String, stat) throws -> Void) throws {
        try validate()
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw DescriptorFileCopy.error("readdir", path: path, code: errno) }
                try validate()
                return
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." || (excludingGit && name == ".git") { continue }
            try budget.consumeEntry()
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DescriptorFileCopy.error("entry lookup", path: path + "/" + name, code: errno)
            }
            try body(name, status)
        }
    }
}

final class ComparisonInventoryBudget {
    let limits: FileTreeComparisonLimits
    var entries = 0
    init(limits: FileTreeComparisonLimits) { self.limits = limits }
    func consumeEntry() throws {
        guard entries < limits.maximumEntries else { throw FileTreeComparisonError.treeTooLarge }
        entries += 1
    }
    func checkDepth(_ depth: Int) throws {
        guard depth <= limits.maximumDepth else { throw FileTreeComparisonError.treeTooLarge }
    }
}

struct ComparisonFile {
    let directory: ComparisonDirectoryReference
    let name: String
    let status: stat
    var path: String { directory.path + "/" + name }

    func open() throws -> ComparisonOpenedFile {
        let parent = try directory.open()
        try parent.validate()
        let (descriptor, status) = try FileService.openRegularFile(at: name, relativeTo: parent.descriptor, reportingPath: path)
        return ComparisonOpenedFile(descriptor: descriptor, directory: parent, entry: self, initial: status)
    }
}

final class ComparisonOpenedFile {
    let descriptor: Int32
    let directory: ComparisonDirectory
    let entry: ComparisonFile
    let initial: stat
    init(descriptor: Int32, directory: ComparisonDirectory, entry: ComparisonFile, initial: stat) {
        self.descriptor = descriptor
        self.directory = directory
        self.entry = entry
        self.initial = initial
    }
    deinit { close(descriptor) }

    func changed() throws -> Bool {
        try directory.validate()
        var current = stat()
        guard fstat(descriptor, &current) == 0 else {
            throw DescriptorFileCopy.error("fstat", path: entry.path, code: errno)
        }
        var named = stat()
        guard fstatat(directory.descriptor, entry.name, &named, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw DescriptorFileCopy.error("file lookup", path: entry.path, code: errno)
        }
        guard named.st_mode & S_IFMT == S_IFREG else {
            throw DescriptorFileCopy.error("file type changed", path: entry.path, code: EFTYPE)
        }
        return !Self.same(initial, current) || !Self.same(initial, named) || !Self.same(initial, entry.status)
    }

    private static func same(_ left: stat, _ right: stat) -> Bool {
        FileEntryStamp(left) == FileEntryStamp(right) && left.st_mode == right.st_mode
    }
}

extension FileService {
    func comparisonInventory(at path: String, excludingGit: Bool, budget: ComparisonInventoryBudget,
                             checkpoint: (String) throws -> Void) throws -> [String: ComparisonFile] {
        let root = try ComparisonDirectory(path: path, name: "", parent: nil)
        var files: [String: ComparisonFile] = [:]
        try collectComparisonFiles(root, relative: "", excludingGit: excludingGit,
                                   files: &files, budget: budget, checkpoint: checkpoint)
        return files
    }

    private func collectComparisonFiles(_ directory: ComparisonDirectory, relative: String, excludingGit: Bool,
                                        files: inout [String: ComparisonFile], budget: ComparisonInventoryBudget,
                                        checkpoint: (String) throws -> Void) throws {
        try checkpoint(directory.path)
        try directory.forEachEntry(excludingGit: excludingGit, budget: budget) { name, status in
            let path = relative.isEmpty ? name : relative + "/" + name
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                try budget.checkDepth(directory.reference.depth + 1)
                let child = try ComparisonDirectory(path: directory.path + "/" + name, name: name, parent: directory)
                try collectComparisonFiles(child, relative: path, excludingGit: false,
                                           files: &files, budget: budget, checkpoint: checkpoint)
            case S_IFREG:
                files[path] = ComparisonFile(directory: directory.reference, name: name, status: status)
            default:
                throw DescriptorFileCopy.error("symlink or special file", path: directory.path + "/" + name, code: EFTYPE)
            }
        }
        try directory.validate()
    }
}
