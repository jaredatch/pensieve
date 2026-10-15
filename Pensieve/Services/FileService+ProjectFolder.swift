import Darwin
import Foundation

/// Proof of a successful root check. Construction stays at the FileService admission boundary;
/// writers still create without parents and reclassify a vanished root after failed creation.
struct ProjectDirectory {
    let path: String
    fileprivate init(path: String) { self.path = path }

    /// User-wide operations are admitted; saved project paths must be absolute before disk access.
    static func canAccess(_ projectPath: String?) -> Bool {
        projectPath.map(PathSyntax.isAbsolute) ?? true
    }
}

extension FileServiceProtocol {
    /// Unmodeled probes and nonrecursive writes fail without accessing the host filesystem.
    func directoryExistsFollowingLinks(at path: String) throws -> Bool { throw CocoaError(.fileReadUnknown) }
    func createDirectoryWithoutParents(at path: String) throws { throw CocoaError(.featureUnsupported) }
    func writeFileWithoutParents(at path: String, content: String) throws { throw CocoaError(.featureUnsupported) }
    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    @discardableResult
    func requireProjectDirectory(at path: String) throws -> ProjectDirectory {
        guard ProjectDirectory.canAccess(path) else { throw ProjectFolderError.missing(path) }
        let exists: Bool
        do {
            exists = try directoryExistsFollowingLinks(at: path)
        } catch {
            throw ProjectFolderError.couldNotCheck(path: path, reason: error.localizedDescription)
        }
        guard exists else { throw ProjectFolderError.missing(path) }
        return ProjectDirectory(path: path)
    }

    func writeFileInProject(at path: String, content: String, projectPath: String) throws {
        try writeFileInProject(at: path, content: content, project: requireProjectDirectory(at: projectPath))
    }

    func writeFileInProject(at path: String, content: String, project: ProjectDirectory) throws {
        try writeInProject(at: path, project: project) {
            try writeFileWithoutParents(at: path, content: content)
        }
    }

    func createSymlinkInProject(at path: String, pointingTo target: String, projectPath: String) throws {
        try createSymlinkInProject(at: path, pointingTo: target, project: requireProjectDirectory(at: projectPath))
    }

    func createSymlinkInProject(at path: String, pointingTo target: String, project: ProjectDirectory) throws {
        try writeInProject(at: path, project: project) {
            try createSymlinkWithoutParents(at: path, pointingTo: target)
        }
    }

    /// The supplied writer stays private; callers pass content or a target to the bounded methods.
    private func writeInProject(at artifactPath: String, project: ProjectDirectory, write: () throws -> Void) throws {
        let projectPath = project.path
        guard let relative = PathSyntax.relativePath(artifactPath, under: projectPath), !relative.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let components = PathSyntax.components(relative)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
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
    private static let directoryProbes = ProjectDirectoryProbes.shared

    func directoryExistsFollowingLinks(at path: String) throws -> Bool {
        try Self.directoryProbes.check(at: path, probe: directoryProbe)
    }

    static func probeDirectory(_ path: String) throws -> Bool {
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
            guard (try? directoryExistsFollowingLinks(at: path)) == true else { throw error }
        }
    }

    func writeFileWithoutParents(at path: String, content: String) throws {
        try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    func createSymlinkWithoutParents(at linkPath: String, pointingTo targetPath: String) throws {
        let manager = FileManager.default
        let existing = try entryTypeWithoutFollowingLinks(at: linkPath)
        if let existing, existing != .symlink {
            throw SymlinkCreationError.occupiedPath(linkPath)
        }
        do {
            if existing != nil {
                // unlink never removes a directory that replaces the admitted link.
                if unlink(linkPath) != 0 && errno != ENOENT {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: linkPath])
                }
            }
            try manager.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
        } catch {
            // Classify a non-link that won the create race; inconclusive lookup preserves the write error.
            if let occupant = try? entryTypeWithoutFollowingLinks(at: linkPath), occupant != .symlink {
                throw SymlinkCreationError.occupiedPath(linkPath)
            }
            throw error
        }
    }
}

enum SymlinkCreationError: LocalizedError {
    case occupiedPath(String)

    var errorDescription: String? {
        switch self {
        case .occupiedPath(let path):
            "Something already exists at \(path)."
        }
    }
}

/// Concurrent callers share one answer and wait within the app's default two-second bound. The lock protects
/// the flight map and answers; timed-out workers stay registered until the raw probe returns.
final class ProjectDirectoryProbes: @unchecked Sendable {
    static let shared = ProjectDirectoryProbes()

    private final class Flight {
        let ready = DispatchGroup()
        let deadline: DispatchTime
        var answer: Result<Bool, Error>?

        init(deadline: DispatchTime) { self.deadline = deadline; ready.enter() }
    }
    private let lock = NSLock()
    private var flights: [String: Flight] = [:]
    private var waitSeconds: TimeInterval = 2
    private let now: () -> DispatchTime
    private let wait: (DispatchGroup, DispatchTime) -> DispatchTimeoutResult

    /// Only the test bundle changes this budget. Existing flights retain their original deadline.
    var deadlineSeconds: TimeInterval {
        get { lock.withLock { waitSeconds } }
        set { lock.withLock { waitSeconds = newValue } }
    }

    /// Tests control clock advancement and observe waits on an isolated registry. Production uses
    /// the monotonic clock and the real broadcast wait; the raw probe always runs on its worker.
    init(now: @escaping () -> DispatchTime = DispatchTime.now,
         wait: @escaping (DispatchGroup, DispatchTime) -> DispatchTimeoutResult = { $0.wait(timeout: $1) }) {
        self.now = now
        self.wait = wait
    }

    func check(at path: String, probe: @escaping (String) throws -> Bool) throws -> Bool {
        let key = PathSyntax.components(path).joined(separator: "/")
        lock.lock()
        let flight: Flight
        let startsProbe: Bool
        if let existing = flights[key] {
            guard now() < existing.deadline else {
                lock.unlock()
                throw timeout(at: path, reason: "An earlier folder check is still running.")
            }
            flight = existing
            startsProbe = false
        } else {
            flight = Flight(deadline: now() + waitSeconds)
            flights[key] = flight
            startsProbe = true
        }
        lock.unlock()
        if startsProbe {
            // Semaphore/group waits do not donate priority to the raw filesystem lookup.
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = Result { try probe(path) }
                self.lock.withLock {
                    flight.answer = answer
                    self.flights[key] = nil
                }
                flight.ready.leave()
            }
        }
        guard wait(flight.ready, flight.deadline) == .success else {
            throw timeout(at: path, reason: "The folder didn't answer in time.")
        }
        return try lock.withLock {
            guard let answer = flight.answer else { throw CocoaError(.fileReadUnknown) }
            return try answer.get()
        }
    }

    private func timeout(at path: String, reason: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT),
                userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: reason])
    }
}

extension FileServiceProtocol {
    /// Modeled collaborators retain their existing write behavior without host I/O.
    func writeStoreFile(at path: String, content: String, root: String, control: Bool) throws {
        try writeFile(at: path, content: content)
    }
    func cleanStoreIntermediates(at root: String) throws {}
}

extension FileService {
    /// Plain rename never displaces a folder. No failed publication falls back into the worktree.
    func writeStoreFile(at path: String, content: String, root: String, control: Bool) throws {
        if !control { try createDirectory(at: (path as NSString).deletingLastPathComponent) }
        let metadata = try storeMetadataDirectory(root: root)
        let directory: String
        if control {
            guard let metadata else { throw CocoaError(.fileNoSuchFile) }
            directory = metadata
        } else if let metadata, fileIdentity(at: metadata, followingLinks: true)?.device
                    == fileIdentity(at: root, followingLinks: true)?.device {
            directory = metadata
        } else {
            guard let temporary = try skillIntermediateDirectory(root: root) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            directory = temporary
            try createDirectory(at: directory)
        }
        try cleanStoreIntermediates(at: root, excluding: directory)
        try withStoreIntermediateLock(directory) {
            try sweepStoreIntermediates(in: directory)
            let temporary = directory + "/.pensieve-write-" + UUID().uuidString
            defer { try? deleteFile(at: temporary) }
            try writeStoreIntermediate(content, at: temporary)
            if control, let type = try entryTypeWithoutFollowingLinks(at: path), type == .directory || type == .symlink {
                throw storePublicationError(at: path, code: type == .directory ? EISDIR : ELOOP)
            }
            guard Darwin.rename(temporary, path) == 0 else { throw storePublicationError(at: path, code: errno) }
        }
    }

    func cleanStoreIntermediates(at root: String) throws {
        guard directoryExists(at: root) else { return }
        try cleanStoreIntermediates(at: root, excluding: nil)
    }

    private func cleanStoreIntermediates(at root: String, excluding: String?) throws {
        let locations = [try storeMetadataDirectory(root: root), try skillIntermediateDirectory(root: root)]
        for case let directory? in locations where directory != excluding && directoryExists(at: directory) {
            try withStoreIntermediateLock(directory) { try sweepStoreIntermediates(in: directory) }
        }
    }

    private func storeMetadataDirectory(root: String) throws -> String? {
        let metadata = root + "/.git"
        guard let type = try entryTypeWithoutFollowingLinks(at: metadata) else { return nil }
        let directory: String
        if type == .regular {
            let text = try readFile(at: metadata).trimmingCharacters(in: .newlines)
            guard text.hasPrefix("gitdir: ") else { throw CocoaError(.fileWriteUnknown) }
            let target = String(text.dropFirst(8))
            directory = PathSyntax.isAbsolute(target) ? target : root + "/" + target
        } else { directory = metadata }
        guard directoryExists(at: directory) else { throw CocoaError(.fileNoSuchFile) }
        let resolved = try resolveRealPath(at: directory)
        let store = try resolveRealPath(at: root)
        guard resolved != store, resolved == store + "/.git" || !PathSyntax.hasPrefix(resolved, store + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return resolved
    }

    /// Before Git setup, use a private namespace on the destination's volume. The parent of a
    /// mounted or linked store need not be writable. Never create a partial .git repository.
    private func skillIntermediateDirectory(root: String) throws -> String? {
        let store = try resolveRealPath(at: root)
        guard let identity = fileIdentity(at: store, followingLinks: true) else { throw CocoaError(.fileNoSuchFile) }
        var parent = FileManager.default.temporaryDirectory.path
        if fileIdentity(at: parent, followingLinks: true)?.device != identity.device {
            let replacement = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: URL(fileURLWithPath: store), create: true)
            parent = replacement.deletingLastPathComponent().path
            try deleteDirectory(at: replacement.path)
        }
        parent = try resolveRealPath(at: parent)
        guard parent != store, !PathSyntax.hasPrefix(parent, store + "/") else { return nil }
        return parent + "/.pensieve-store-writes-\(identity.device)-\(identity.inode)"
    }

    /// Directory flock covers creation, sweep and publication, and the kernel releases it on death.
    /// The directory stays in place so concurrent writers always lock the same inode.
    private func withStoreIntermediateLock(_ directory: String, body: () throws -> Void) throws {
        let descriptor = try Self.openDirectory(at: directory)
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw storePublicationError(at: directory, code: errno)
        }
        try body()
    }

    private func sweepStoreIntermediates(in directory: String) throws {
        let prefix = ".pensieve-write-"
        for name in try listDirectory(at: directory) where name.hasPrefix(prefix)
            && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
            let path = directory + "/" + name
            guard try entryTypeWithoutFollowingLinks(at: path) == .regular else { continue }
            guard unlink(path) == 0 || errno == ENOENT else { throw storePublicationError(at: path, code: errno) }
        }
    }

    private func storePublicationError(at path: String, code: Int32) -> NSError {
        let description = code == EISDIR ? "not a regular file: \(path)"
            : "open(\(path)): " + String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: description])
    }

    private func writeStoreIntermediate(_ content: String, at path: String) throws {
        let (descriptor, _) = try Self.openRegularFile(at: path, creatingWithPermissions: 0o644)
        defer { close(descriptor) }
        try Data(content.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw storePublicationError(at: path, code: errno) }
                offset += written
            }
        }
    }
}
