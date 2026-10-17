import Foundation
import XCTest

/// Holds the fixture's real flock in a child process, bounded to 90 seconds if teardown is lost.
/// Closing stdin releases it. The ready byte comes only from inside lockf's critical section.
final class ExternalSyncLockHolder {
    private let process = Process()
    private let input = Pipe()
    private var released = false

    init(path: String) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", path, "/bin/bash", "-c", "printf R; read -r -t 90 release"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("R".utf8))
    }

    func release() {
        guard !released else { return }
        released = true
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }

    deinit { release() }
}
