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

        let delivered = expectation(description: "Delivers changed skill directory")
        // An atomic write is a temp-file create plus a rename; FSEvents may deliver them as two batches,
        // and the service dedupes only within a batch. A repeat delivery is correct, not over-fulfillment
        // (CI run 34276187889 crashed the test process on the second fulfill).
        delivered.assertForOverFulfill = false
        var receivedDirectoryNames: [String] = []
        watcher = FileWatchService(rootDir: tempRoot) { changedDirectoryName in
            receivedDirectoryNames.append(changedDirectoryName)
            if changedDirectoryName == directoryName {
                delivered.fulfill()
            }
        }

        XCTAssertTrue(watcher.start())

        try "# External Edit".write(
            toFile: skillDir + "/SKILL.md",
            atomically: true,
            encoding: .utf8
        )

        wait(for: [delivered], timeout: 5.0)
        XCTAssertTrue(receivedDirectoryNames.contains(directoryName))
    }

    func testStartIsQuietWithoutExternalWrites() {
        let quiet = expectation(description: "No change signal arrives")
        quiet.isInverted = true

        watcher = FileWatchService(rootDir: tempRoot) { _ in
            quiet.fulfill()
        }

        XCTAssertTrue(watcher.start())

        wait(for: [quiet], timeout: 1.0)
    }
}
