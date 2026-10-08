import Foundation
import XCTest
@testable import Pensieve

extension UpdateCheckServiceTests {
    func testRemoteHeadPrefersBranchThenPeeledThenPlainTag() throws {
        let root = TestTemporaryDirectory.path + "PensieveRemoteHeadTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch=main", root])
        try "one".write(toFile: root + "/value", atomically: true, encoding: .utf8)
        try runGit(["-C", root, "add", "-A"])
        try runGit(["-C", root, "commit", "-m", "one"])
        let first = try gitRevision("HEAD", repository: root)

        try "two".write(toFile: root + "/value", atomically: true, encoding: .utf8)
        try runGit(["-C", root, "commit", "-am", "two"])
        let second = try gitRevision("HEAD", repository: root)
        try runGit(["-C", root, "branch", "same", second])
        try runGit(["-C", root, "tag", "-a", "same", first, "-m", "same tag"])
        try runGit(["-C", root, "tag", "-a", "annotated", first, "-m", "annotated"])
        try runGit(["-C", root, "tag", "lightweight", second])

        let service = TestPaths.git
        XCTAssertEqual(try service.remoteHead(remote: root, ref: "same", credential: nil), second)
        XCTAssertEqual(try service.remoteHead(remote: root, ref: "annotated", credential: nil), first)
        XCTAssertEqual(try service.remoteHead(remote: root, ref: "lightweight", credential: nil), second)
    }

    private func gitRevision(_ revision: String, repository: String) throws -> String {
        try runGit(["-C", repository, "rev-parse", revision])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@pensieve.local"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@pensieve.local"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(bytes: errorData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        return String(bytes: outputData, encoding: .utf8) ?? ""
    }
}
