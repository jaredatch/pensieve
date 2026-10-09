import XCTest
@testable import Pensieve

final class FileWatchServiceTests: XCTestCase {
    private var watcher: FileWatchService!
    private var tempRoot: String!

    override func setUpWithError() throws {
        tempRoot = TestTemporaryDirectory.path + "PensieveFileWatchTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        watcher?.stop()

        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot) {
            try FileManager.default.removeItem(atPath: tempRoot)
        }
    }

    func testStartDeliversChangedDirectoryNameForExternalSkillWrite() throws {
        let directoryNames = ["external-edit"] + PathJoiningScalars.values.map { PathJoiningScalars.name("edit", scalar: $0) }
        for name in directoryNames {
            try FileManager.default.createDirectory(atPath: tempRoot + "/" + name, withIntermediateDirectories: true)
        }

        var receivedDirectoryNames: [String] = []
        watcher = FileWatchService(rootDir: tempRoot) { changedDirectoryName in
            receivedDirectoryNames.append(changedDirectoryName)
        }

        XCTAssertTrue(watcher.start())

        // SinceNow can advance past the first write while the stream starts under load.
        // Keep writing while the main run loop lets the main-queue delivery run.
        let deadline = Date().addingTimeInterval(TestWait.hostedActionTimeoutSeconds)
        var nextWrite = Date.distantPast
        var writeNumber = 0
        // Prove an external write is delivered once the stream is live, rather than its first write after start().
        while !Set(directoryNames).isSubset(of: Set(receivedDirectoryNames)), Date() < deadline {
            if Date() >= nextWrite {
                for name in directoryNames {
                    try "# External Edit \(writeNumber)".write(toFile: tempRoot + "/" + name + "/SKILL.md",
                                                            atomically: true, encoding: .utf8)
                }
                writeNumber += 1
                nextWrite = Date().addingTimeInterval(0.5)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(Set(directoryNames).isSubset(of: Set(receivedDirectoryNames)),
                      "FileWatch delivery never arrived for repeated external skill writes: \(receivedDirectoryNames)")
    }

    func testStartIsQuietWithoutExternalWrites() {
        let quiet = expectation(description: "No change signal arrives")
        quiet.isInverted = true

        watcher = FileWatchService(rootDir: tempRoot) { _ in
            quiet.fulfill()
        }

        XCTAssertTrue(watcher.start())

        wait(for: [quiet], timeout: 1.0) // upper-bound: Inverted expectation observes no file changes.
    }
}
