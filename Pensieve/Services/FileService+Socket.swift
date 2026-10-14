import Darwin
import Foundation

extension FileService {
    /// A held, persistent lock serializes probe/bind/listen and stale-socket cleanup between copies.
    /// All endpoint metadata, permission changes and unlink operations stay at this filesystem boundary.
    func makeSocketListener(at path: String) throws -> SocketListener {
        var address = try SocketTransport.address(path)
        try createDirectory(at: (path as NSString).deletingLastPathComponent)
        let lockPath = path + ".lock"
        let lock: Int32
        do {
            lock = try Self.openRegularFile(at: lockPath, creatingWithPermissions: 0o600).descriptor
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            lock = try Self.openRegularFile(at: lockPath).descriptor
        }
        var lockStatus = stat()
        guard fcntl(lock, F_SETFD, FD_CLOEXEC) == 0,
              fstat(lock, &lockStatus) == 0, lockStatus.st_uid == getuid(),
              fileIdentity(at: lockPath, followingLinks: false) == FileIdentity(
                device: lockStatus.st_dev, inode: lockStatus.st_ino),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw SocketError.system("socket endpoint already owned: \(path)", EADDRINUSE)
        }
        var ownsLock = true
        defer { if ownsLock { close(lock) } }
        try removeStaleSocket(at: path)
        let descriptor = try SocketTransport.descriptor()
        var ownsDescriptor = true
        var boundIdentity: FileIdentity?
        defer {
            if ownsDescriptor {
                close(descriptor)
                if let boundIdentity { Self.removeSocket(at: path, identity: boundIdentity) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw SocketError.system("bind \(path)", errno) }
        guard let identity = fileIdentity(at: path, followingLinks: false) else {
            throw SocketError.system("inspect \(path)", errno)
        }
        boundIdentity = identity
        guard chmod(path, 0o600) == 0, listen(descriptor, 32) == 0 else {
            throw SocketError.system("listen \(path)", errno)
        }
        ownsDescriptor = false
        ownsLock = false
        return SocketListener(descriptor: descriptor, lock: lock, path: path, identity: identity)
    }

    private func removeStaleSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return }
            throw SocketError.system("inspect \(path)", errno)
        }
        guard Self.admitsStaleSocket(status, user: getuid()) else {
            throw SocketError.system("occupied socket path: \(path)", EEXIST)
        }
        do {
            let probe = try SocketTransport.connect(to: path, timeout: 0.2)
            close(probe)
            throw SocketError.system("live socket: \(path)", EADDRINUSE)
        } catch SocketError.system(_, let code) where code == ECONNREFUSED {
            let identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
            guard fileIdentity(at: path, followingLinks: false) == identity else {
                throw SocketError.system("socket changed: \(path)", EAGAIN)
            }
            guard unlink(path) == 0 else { throw SocketError.system("unlink \(path)", errno) }
        }
    }

    static func admitsStaleSocket(_ status: stat, user: uid_t) -> Bool {
        status.st_mode & S_IFMT == S_IFSOCK && status.st_uid == user
    }

    fileprivate static func removeSocket(at path: String, identity: FileIdentity) {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK,
              status.st_uid == getuid(), status.st_dev == identity.device, status.st_ino == identity.inode else { return }
        if unlink(path) != 0 { NSLog("Pensieve socket cleanup: %s", strerror(errno)) }
    }
}

/// Owns the endpoint and its election lock until the accept source has finished using the descriptor.
final class SocketListener {
    let descriptor: Int32
    private let lock: Int32
    private let path: String
    private let identity: FileIdentity

    fileprivate init(descriptor: Int32, lock: Int32, path: String, identity: FileIdentity) {
        self.descriptor = descriptor
        self.lock = lock
        self.path = path
        self.identity = identity
    }

    func removeOwnedPath() { FileService.removeSocket(at: path, identity: identity) }

    deinit {
        close(descriptor)
        removeOwnedPath()
        close(lock)
    }
}
