import Darwin
import XCTest
@testable import Pensieve

extension ManifestScenarioCarryTests {
    func testConcurrentManifestWritersSerializeWholeBuildAndSwap() throws {
        try files.writeFile(at: root + "/manifest/scenarios/legacy.yaml", content: "keep")
        let firstOpened = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let secondOpened = DispatchSemaphore(value: 0)
        let order = CarryOrder()
        let finished = DispatchGroup()
        let errors = CarryErrors()
        let first = ScenarioCarryFileService()
        first.afterDirectoryCheck = {
            firstOpened.signal()
            if releaseFirst.wait(timeout: .now() + 5) != .success { errors.record(DeployStubFailure()) }
        }
        let second = ScenarioCarryFileService()
        second.afterDirectoryCheck = {
            order.record("second opened")
            secondOpened.signal()
        }
        let root = try XCTUnwrap(root)
        let snapshot = empty
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do { try ManifestService(fileService: first).write(snapshot, toRoot: root) } catch { errors.record(error) }
        }
        XCTAssertEqual(firstOpened.wait(timeout: .now() + 5), .success)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do {
                try ManifestService(fileService: second, writeLockAttempted: { acquired in
                    order.record(acquired ? "second acquired" : "second blocked")
                    secondAttempted.signal()
                }).write(snapshot, toRoot: root)
            } catch { errors.record(error) }
        }
        XCTAssertEqual(secondAttempted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(order.values, ["second blocked"], "second writer must encounter the held process lock")
        XCTAssertEqual(secondOpened.wait(timeout: .now() + 0.5), .timedOut,
                       "second writer entered the locked region before the first writer was released")
        order.record("first released")
        releaseFirst.signal()
        XCTAssertEqual(secondOpened.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        XCTAssertEqual(order.values, ["second blocked", "first released", "second opened"])
        XCTAssertEqual(try files.readFile(at: root + "/manifest/scenarios/legacy.yaml"), "keep")
    }

    func testDirectoryUnlinkedDuringCarryFailsClosedAndRetries() throws {
        try assertChangedSourceFails(beforeSwap: false, replacement: true)
    }

    func testEntryRewrittenDuringCarryFailsClosedAndRetries() throws {
        try assertChangedSourceFails(beforeSwap: false, replacement: false)
    }

    func testDirectoryModifiedDuringCarryFailsClosedAndRetries() throws {
        let source = root + "/manifest/scenarios"
        for initiallyAbsent in [false, true] {
            if initiallyAbsent { try files.deleteDirectory(at: source) } else {
                try files.writeFile(at: source + "/legacy.yaml", content: "keep")
            }
            let guarded = ScenarioCarryFileService()
            var expected: [String: Data] = [:]
            guarded.checkpointAction = { point in
                switch point {
                case .opened where !initiallyAbsent, .unavailable where initiallyAbsent:
                    try self.files.writeFile(at: source + "/new.yaml", content: "new")
                    expected = try self.treeBytes(at: self.root + "/manifest")
                default: break
                }
            }
            XCTAssertThrowsError(try ManifestService(fileService: guarded).write(empty, toRoot: root))
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(try treeBytes(at: root + "/manifest"), expected)
            try manifest.write(empty, toRoot: root)
            XCTAssertEqual(try treeBytes(at: root + "/manifest"), expected)
        }
    }

    func testFileTruncatedMidChunkCopyFailsClosedAndRetries() throws {
        let source = root + "/manifest/scenarios/legacy.yaml"
        try files.writeData(at: source, data: Data(repeating: 42, count: 256 * 1_024))
        let guarded = ScenarioCarryFileService()
        var expected: [String: Data] = [:]
        var fired = false
        guarded.checkpointAction = { point in
            guard case .copiedChunk = point, !fired else { return }
            fired = true
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: source))
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("replacement".utf8))
            expected = try self.treeBytes(at: self.root + "/manifest")
        }
        XCTAssertThrowsError(try ManifestService(fileService: guarded).write(empty, toRoot: root))
        XCTAssertTrue(fired)
        XCTAssertEqual(try treeBytes(at: root + "/manifest"), expected)
        try manifest.write(empty, toRoot: root)
        XCTAssertEqual(try files.readFile(at: source), "replacement")
    }

    func testSourceRevalidatedImmediatelyBeforeSwapForUpdatedAndAddedFiles() throws {
        for replacement in [false, true] {
            try assertChangedSourceFails(beforeSwap: true, replacement: replacement)
        }
    }

    func testLegacyCopyUsesBoundedChunksAndPreservesAllBytes() throws {
        let bytes = Data((0..<(512 * 1_024 + 17)).map { UInt8($0 % 251) })
        try files.writeData(at: root + "/manifest/scenarios/large.bin", data: bytes)
        let guarded = ScenarioCarryFileService()
        var counts: [Int] = []
        guarded.checkpointAction = { point in
            if case .copiedChunk(_, let count) = point { counts.append(count) }
        }
        try ManifestService(fileService: guarded).write(empty, toRoot: root)
        XCTAssertGreaterThan(counts.count, 1)
        XCTAssertTrue(counts.allSatisfy { $0 > 0 && $0 <= 64 * 1_024 })
        XCTAssertEqual(counts.reduce(0, +), bytes.count)
        XCTAssertEqual(try files.readData(at: root + "/manifest/scenarios/large.bin"), bytes)
    }

    func testCopyErrorsNameTheFailingPathAndPOSIXReason() throws {
        let source = root + "/manifest/scenarios/legacy.yaml"
        try files.writeFile(at: source, content: "keep")
        let missing = root + "/missing/legacy.yaml"
        XCTAssertThrowsError(try files.copyFile(at: source, to: missing)) { error in
            XCTAssertTrue(error.localizedDescription.contains(missing))
            XCTAssertTrue(error.localizedDescription.contains(String(cString: strerror(ENOENT))))
        }
        XCTAssertThrowsError(try files.copyRegularFiles(fromDirectory: root + "/manifest/scenarios",
                                                       toDirectory: root + "/missing")) { error in
            XCTAssertTrue(error.localizedDescription.contains(missing))
            XCTAssertTrue(error.localizedDescription.contains(String(cString: strerror(ENOENT))))
        }
    }

    private func assertChangedSourceFails(beforeSwap: Bool, replacement: Bool) throws {
        let source = root + "/manifest/scenarios"
        try files.writeFile(at: source + "/legacy.yaml", content: "before")
        let guarded = ScenarioCarryFileService()
        var expected: [String: Data] = [:]
        var fired = false
        let change = {
            guard !fired else { return }
            fired = true
            if replacement && !beforeSwap {
                try self.files.deleteDirectory(at: source)
                try self.files.writeFile(at: source + "/legacy.yaml", content: "before")
            } else if replacement {
                try self.files.writeFile(at: source + "/added.yaml", content: "new")
            } else {
                try self.files.writeFile(at: source + "/legacy.yaml", content: "updated bytes")
            }
            expected = try self.treeBytes(at: self.root + "/manifest")
        }
        if beforeSwap { guarded.beforeSwap = change } else {
            guarded.checkpointAction = { point in
                if replacement, case .opened = point { try change() }
                if !replacement, case .copying = point { try change() }
            }
        }
        var changed = empty
        changed.categories = [CategoryRecord(name: "Changed", projectKeys: [], skillSlugs: [])]
        XCTAssertThrowsError(try ManifestService(fileService: guarded).write(changed, toRoot: root))
        XCTAssertTrue(fired)
        XCTAssertEqual(try treeBytes(at: root + "/manifest"), expected)
        try manifest.write(changed, toRoot: root)
        XCTAssertEqual(try manifest.read(fromRoot: root).categories, changed.categories)
        for (path, bytes) in expected where path.hasPrefix("scenarios/") {
            XCTAssertEqual(try files.readData(at: root + "/manifest/" + path), bytes)
        }
    }
}

/// Only records cross-thread test errors; all modeled I/O stays in the temporary store's FileService.
private final class CarryErrors {
    private let lock = NSLock()
    private var errors: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error.localizedDescription) }
}

/// Ordered cross-thread checkpoint events; the semaphore publishes the lock-attempt event before inspection.
private final class CarryOrder {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; events.append(event) }
}
