import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    func testCopyFileRefusesFifoWithoutBlocking() throws {
        let fifoPath = tempDir + "/fifo-source"
        guard mkfifo(fifoPath, 0o644) == 0 else {
            return XCTFail("mkfifo failed: " + String(cString: strerror(errno)))
        }
        let destination = tempDir + "/fifo-dest"
        let done = expectation(description: "copyFile returned")
        var thrown: Error?
        DispatchQueue.global().async {
            do {
                try self.fileService.copyFile(at: fifoPath, to: destination)
            } catch {
                thrown = error
            }
            done.fulfill()
        }

        // Bounded on purpose: if O_NONBLOCK regresses, the open blocks forever — this wait FAILS
        // the test at 5s instead of wedging the whole suite, and the writer-open below releases
        // the blocked reader so the leaked thread unwinds.
        let outcome = XCTWaiter().wait(for: [done], timeout: 5) // upper-bound: Five-second FIFO deadlock limit.
        guard outcome == .completed else {
            let writerFD = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if writerFD >= 0 { close(writerFD) }
            return XCTFail("copyFile blocked on a writerless FIFO — O_NONBLOCK regressed")
        }
        XCTAssertNotNil(thrown)
        XCTAssertFalse(fileService.fileExists(at: destination))
    }
}
