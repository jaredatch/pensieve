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
        let directoryName = "external-edit"
        let skillDir = tempRoot + "/" + directoryName
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)

        var receivedDirectoryNames: [String] = []
        watcher = FileWatchService(rootDir: tempRoot) { changedDirectoryName in
            receivedDirectoryNames.append(changedDirectoryName)
        }

        XCTAssertTrue(watcher.start())

        // SinceNow can advance past the first write while the stream starts under load.
        // Keep writing while the main run loop lets the main-queue delivery run.
        let deadline = Date().addingTimeInterval(10.0)
        var nextWrite = Date.distantPast
        var writeNumber = 0
        while !receivedDirectoryNames.contains(directoryName), Date() < deadline {
            if Date() >= nextWrite {
                try "# External Edit \(writeNumber)".write(
                    toFile: skillDir + "/SKILL.md",
                    atomically: true,
                    encoding: .utf8
                )
                writeNumber += 1
                nextWrite = Date().addingTimeInterval(0.5)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(receivedDirectoryNames.contains(directoryName),
                      "FileWatch delivery never arrived for repeated external skill writes")
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
