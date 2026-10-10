import SwiftData
import XCTest
@testable import Pensieve
private typealias PensieveCategory = Pensieve.Category

// MARK: - Shared helpers
extension SyncConflictResolutionTests {
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, PensieveCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    func rawGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(bytes: outData, encoding: .utf8) ?? ""
        let stderr = String(bytes: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw TestFailure("git \(args.joined(separator: " ")) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteHead(_ remotePath: String) throws -> String {
        try rawGit(["--git-dir", remotePath, "rev-parse", "refs/heads/main"])
    }

    @discardableResult
    func writeSkillFile(root: String, body: String) throws -> String {
        let dir = root + "/skills/" + Self.slug
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(Self.slug)
        description: Conflict description
        ---

        \(body)
        """
        try (markdown + "\n").write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
        return markdown + "\n"
    }

    func readSkill(root: String) throws -> String {
        try String(contentsOfFile: root + "/" + Self.skillPath, encoding: .utf8)
    }
}
