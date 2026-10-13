import Darwin
import XCTest
@testable import Pensieve

final class SocketEndpointTests: XCTestCase {
    func testReplacesRefusingSocketAndPreservesLiveEndpoint() throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/s"
        try abandonedSocket(at: path)
        var listener: SocketListener? = try directory.files.makeSocketListener(at: path)
        let identity = directory.files.fileIdentity(at: path, followingLinks: false)
        let client = try SocketTransport.connect(to: path)
        close(client)
        XCTAssertThrowsError(try directory.files.makeSocketListener(at: path))
        XCTAssertEqual(directory.files.fileIdentity(at: path, followingLinks: false), identity)
        XCTAssertNotNil(listener)
        listener = nil
        XCTAssertFalse(try directory.files.entryExistsWithoutFollowingLinks(at: path))
        // A live socket without our election lock must also survive the stale-socket probe.
        let other = try rawSocket(at: path, listening: true)
        defer { close(other) }
        let liveIdentity = directory.files.fileIdentity(at: path, followingLinks: false)
        XCTAssertThrowsError(try directory.files.makeSocketListener(at: path))
        XCTAssertEqual(directory.files.fileIdentity(at: path, followingLinks: false), liveIdentity)
        let otherClient = try SocketTransport.connect(to: path)
        close(otherClient)
    }

    func testOccupiedAndUnprobeableEntriesStayInPlace() throws {
        let directory = try SocketTestDirectory()
        for kind in ["file", "symlink", "directory", "unprobeable"] {
            let parent = directory.path + "/" + kind
            let path = parent + "/s"
            try directory.files.createDirectory(at: parent)
            if kind == "directory" {
                try directory.files.createDirectory(at: path)
            } else if kind == "symlink" {
                try directory.files.createSymlink(at: path, pointingTo: "missing")
            } else {
                try directory.files.writeFile(at: path, content: "keep")
            }
            let before = directory.files.fileIdentity(at: path, followingLinks: false)
            if kind == "unprobeable" { XCTAssertEqual(chmod(parent, 0), 0) }
            XCTAssertThrowsError(try directory.files.makeSocketListener(at: path), kind)
            if kind == "unprobeable" { XCTAssertEqual(chmod(parent, 0o700), 0) }
            XCTAssertEqual(directory.files.fileIdentity(at: path, followingLinks: false), before, kind)
        }
        var foreign = stat()
        foreign.st_mode = mode_t(S_IFSOCK | 0o600)
        foreign.st_uid = getuid() + 1
        XCTAssertFalse(FileService.admitsStaleSocket(foreign, user: getuid()))
        foreign.st_uid = getuid()
        XCTAssertTrue(FileService.admitsStaleSocket(foreign, user: getuid()))
        foreign.st_mode = mode_t(S_IFLNK | 0o600)
        XCTAssertFalse(FileService.admitsStaleSocket(foreign, user: getuid()))
    }

    func testConcurrentCopiesElectOneListener() {
        do {
            let directory = try SocketTestDirectory()
            try assertStartingOwnerSurvivesContender(in: directory)
            let path = directory.path + "/s"
            let results = ListenerRaceResults()
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                let listener = try? FileService().makeSocketListener(at: path)
                results.append(listener)
            }
            XCTAssertEqual(results.listeners.count, 1)
            let client = try SocketTransport.connect(to: path)
            close(client)
            XCTAssertTrue(try directory.files.entryExistsWithoutFollowingLinks(at: path))
            withExtendedLifetime(results) {}
        } catch { XCTFail(error.localizedDescription) }
    }

    private func assertStartingOwnerSurvivesContender(in directory: SocketTestDirectory) throws {
        let path = directory.path + "/starting"
        // Model the first copy between bind and listen, holding the real on-disk election lock.
        // Only the OS owner state is supplied; the contender uses production admission and cleanup.
        let lock = try FileService.openRegularFile(at: path + ".lock", creatingWithPermissions: 0o600).descriptor
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let owner = try rawSocket(at: path, listening: false)
        defer { close(owner) }
        let identity = try XCTUnwrap(directory.files.fileIdentity(at: path, followingLinks: false))
        XCTAssertThrowsError(try SocketTransport.connect(to: path)) {
            guard case SocketError.system(_, ECONNREFUSED) = $0 else {
                return XCTFail("The bound owner must not be listening yet: \($0)")
            }
        }

        let contender = try? FileService().makeSocketListener(at: path)
        XCTAssertNil(contender, "A starting copy already owns this endpoint")
        XCTAssertEqual(directory.files.fileIdentity(at: path, followingLinks: false), identity,
                       "The contender must not unlink the starting copy's socket")
        XCTAssertEqual(listen(owner, 4), 0)
        let client = try SocketTransport.connect(to: path)
        defer { close(client) }
        let accepted = accept(owner, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0, "The original socket must remain reachable after it starts listening")
        if accepted >= 0 { close(accepted) }
        withExtendedLifetime(contender) {}
    }

    func testShutdownPreservesReplacementAtItsPath() throws {
        let directory = try SocketTestDirectory()
        for replacement in ["file", "socket"] {
            let path = directory.path + "/" + replacement
            var listener: SocketListener? = try directory.files.makeSocketListener(at: path)
            XCTAssertNotNil(listener)
            try directory.files.deleteFile(at: path)
            if replacement == "file" {
                try directory.files.writeFile(at: path, content: "replacement")
            } else {
                try abandonedSocket(at: path)
            }
            let identity = directory.files.fileIdentity(at: path, followingLinks: false)
            listener = nil
            XCTAssertEqual(directory.files.fileIdentity(at: path, followingLinks: false), identity)
        }
    }

    func testOverlongPathFailsBeforeCreatingItsDirectory() throws {
        let directory = try SocketTestDirectory()
        let path = directory.path + "/" + String(repeating: "é", count: 80)
        XCTAssertThrowsError(try directory.files.makeSocketListener(at: path)) {
            XCTAssertTrue($0.localizedDescription.contains(path))
        }
        XCTAssertEqual(try directory.files.listDirectory(at: directory.path), [])
    }

    private func abandonedSocket(at path: String) throws {
        close(try rawSocket(at: path, listening: false))
    }

    private func rawSocket(at path: String, listening: Bool) throws -> Int32 {
        let descriptor = try SocketTransport.descriptor()
        var address = try SocketTransport.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, String(cString: strerror(errno)))
        if listening { XCTAssertEqual(listen(descriptor, 4), 0) }
        return descriptor
    }
}

/// concurrentPerform joins before reading; the lock serializes the two worker publications.
private final class ListenerRaceResults {
    private let lock = NSLock()
    private(set) var listeners: [SocketListener] = []

    func append(_ listener: SocketListener?) {
        lock.lock()
        defer { lock.unlock() }
        if let listener { listeners.append(listener) }
    }
}
