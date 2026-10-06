import Darwin
import Foundation

/// Proof of a successful root check. Construction stays at the FileService admission boundary;
/// writers still create without parents and reclassify a vanished root after failed creation.
struct ProjectDirectory {
    let path: String
    fileprivate init(path: String) { self.path = path }

    /// User-wide operations are admitted; saved project paths must be absolute before disk access.
    static func canAccess(_ projectPath: String?) -> Bool {
        projectPath.map { $0.utf8.first == UInt8(ascii: "/") } ?? true
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
        let prefix = (projectPath.utf8.last == UInt8(ascii: "/") ? projectPath : projectPath + "/").utf8
        guard artifactPath.utf8.starts(with: prefix) else { throw CocoaError(.fileWriteInvalidFileName) }
        let components = artifactPath.utf8.dropFirst(prefix.count).split(separator: UInt8(ascii: "/"))
            .compactMap { String(bytes: $0, encoding: .utf8) }
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
    private static let directoryProbes = ProjectDirectoryProbes()

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
            // Foundation decomposes the destination's Unicode spelling. Ownership needs the literal target bytes.
            if symlink(targetPath, linkPath) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: linkPath])
            }
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

/// Concurrent callers share one answer and wait within a two-second bound. The lock protects
/// the flight map and answers; timed-out workers stay registered until the raw probe returns.
final class ProjectDirectoryProbes: @unchecked Sendable {
    private final class Flight {
        let ready = DispatchGroup()
        let deadline: DispatchTime
        var answer: Result<Bool, Error>?

        init(deadline: DispatchTime) { self.deadline = deadline; ready.enter() }
    }
    private let lock = NSLock()
    private var flights: [Data: Flight] = [:]
    private let now: () -> DispatchTime
    private let wait: (DispatchGroup, DispatchTime) -> DispatchTimeoutResult

    /// Tests control clock advancement and observe waits on an isolated registry. Production uses
    /// the monotonic clock and the real broadcast wait; the raw probe always runs on its worker.
    init(now: @escaping () -> DispatchTime = DispatchTime.now,
         wait: @escaping (DispatchGroup, DispatchTime) -> DispatchTimeoutResult = { $0.wait(timeout: $1) }) {
        self.now = now
        self.wait = wait
    }

    func check(at path: String, probe: @escaping (String) throws -> Bool) throws -> Bool {
        let key = Data(path.utf8.split(separator: UInt8(ascii: "/")).joined(separator: [UInt8(ascii: "/")]))
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
            flight = Flight(deadline: now() + 2)
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
