import Darwin
import Foundation
import XCTest
@testable import Pensieve

final class ProjectDirectoryConcurrencyTests: XCTestCase {
    func testConcurrentCallersShareHealthyProbeAndItsAnswer() async throws {
        for answer in [true, false] {
            let started = expectation(description: "Raw lookup starts")
            let secondStarted = expectation(description: "Concurrent caller starts")
            let completed = expectation(description: "Both callers finish")
            completed.expectedFulfillmentCount = 2
            let release = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var probes = 0
            var answers: [Bool] = []
            var errors: [Error] = []
            let path = "/fixture/\(UUID().uuidString)"
            let files = FileService(directoryProbe: { _ in
                lock.withLock { probes += 1 }
                started.fulfill()
                _ = release.wait(timeout: .now() + 4)
                return answer
            })
            let check = {
                do {
                    let value = try files.directoryExistsFollowingLinks(at: path)
                    lock.withLock { answers.append(value) }
                } catch { lock.withLock { errors.append(error) } }
                completed.fulfill()
            }
            DispatchQueue.global(qos: .userInitiated).async { check() }
            await fulfillment(of: [started], timeout: 2)
            DispatchQueue.global(qos: .userInitiated).async { secondStarted.fulfill(); check() }
            await fulfillment(of: [secondStarted], timeout: 2)
            // A short bounded observation keeps the first lookup in flight while the second joins.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(lock.withLock { errors.isEmpty }, "A healthy concurrent check must wait")
            release.signal()
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertTrue(lock.withLock { errors.isEmpty })
            XCTAssertEqual(lock.withLock { answers }, [answer, answer])
            XCTAssertEqual(lock.withLock { probes }, 1)
        }
    }

    func testLateJoinerUsesFlightDeadlineWithoutClaimingTwoSecondWait() async throws {
        let started = expectation(description: "Raw lookup starts")
        let firstFinished = expectation(description: "First caller times out")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var probes = 0
        let path = "/fixture/\(UUID().uuidString)"
        let files = FileService(directoryProbe: { _ in
            lock.withLock { probes += 1 }
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return true
        })
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try files.directoryExistsFollowingLinks(at: path)
                XCTFail("The blocked first caller must time out")
            } catch { XCTAssertEqual((error as NSError).code, Int(ETIMEDOUT)) }
            firstFinished.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        try await Task.sleep(for: .milliseconds(1500))
        let joinedAt = Date()
        XCTAssertThrowsError(try files.directoryExistsFollowingLinks(at: path)) { error in
            XCTAssertEqual((error as NSError).code, Int(ETIMEDOUT))
            XCTAssertFalse(error.localizedDescription.contains("2 seconds"),
                           "A late joiner's brief wait must not claim two seconds")
        }
        XCTAssertLessThan(Date().timeIntervalSince(joinedAt), 1,
                          "A joiner waits only until the original flight's deadline")
        await fulfillment(of: [firstFinished], timeout: 1)
        XCTAssertEqual(lock.withLock { probes }, 1)
    }

    func testWaitUsesOnlyFlightDeadline() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try FileService().readFile(at: root.appendingPathComponent(
            "Pensieve/Services/FileService+ProjectFolder.swift").path)
        XCTAssertFalse(source.contains("callerDeadline"), "A joiner's deadline is always the flight deadline")
        XCTAssertTrue(source.contains("flight.ready.wait(timeout: flight.deadline)"))
    }

    func testProbeRunsAtUserInitiatedPriorityOrHigher() throws {
        let files = FileService(directoryProbe: { _ in
            let qos = qos_class_self()
            XCTAssertTrue(qos == QOS_CLASS_USER_INITIATED || qos == QOS_CLASS_USER_INTERACTIVE,
                          "A synchronous caller must not wait on a utility-priority lookup")
            return true
        })
        XCTAssertTrue(try files.directoryExistsFollowingLinks(at: "/fixture/\(UUID().uuidString)"))
    }
}
