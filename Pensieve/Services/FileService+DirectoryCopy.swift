import Darwin
import Foundation

extension FileServiceProtocol {
    /// Existing doubles can model an empty/absent directory without host I/O. A nonempty
    /// directory needs an explicit implementation of the descriptor-bound copy operation.
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws {
        guard !isSymlink(at: source), directoryExists(at: source) else { return }
        guard try listDirectory(at: source).isEmpty else { throw CocoaError(.featureUnsupported) }
    }
}

extension FileService {
    enum DirectoryCopyCheckpoint {
        case opened
        case copying(String)
    }

    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String) throws {
        try copyRegularFiles(fromDirectory: source, toDirectory: destination, checkpoint: { _ in })
    }

    /// The checkpoint injects directory replacement and listing/copy failures in tests. It runs
    /// after opening the directory and before listing, or before opening each regular child.
    func copyRegularFiles(fromDirectory source: String, toDirectory destination: String,
                          checkpoint: (DirectoryCopyCheckpoint) throws -> Void) throws {
        let descriptor = open(source, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR || code == ELOOP { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { closedir(directory) }
        try checkpoint(.opened)
        let names = try directoryEntryNames(directory)
        for name in names.sorted() {
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else { continue }
            try checkpoint(.copying(name))
            try copyRegularEntry(name, descriptor: descriptor, to: destination + "/" + name)
        }
    }

    private func directoryEntryNames(_ directory: UnsafeMutablePointer<DIR>) throws -> [String] {
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                return names
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    private func copyRegularEntry(_ name: String, descriptor: Int32, to destination: String) throws {
        let child = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard child >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: child, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(child, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
        }
        let data = try handle.readToEnd() ?? Data()
        guard FileManager.default.createFile(atPath: destination, contents: data,
                                            attributes: [.posixPermissions: status.st_mode & 0o777]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
