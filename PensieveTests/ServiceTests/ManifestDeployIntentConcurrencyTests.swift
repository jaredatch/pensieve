import SwiftData
import XCTest
@testable import Pensieve

extension ManifestDeployIntentTests {
    func testConcurrentRetractVsAddConverges() throws {
        let git = TestPaths.git
        let remote = try seedRemote(git: git, intents: [record(slug: "alpha")])
        let cloneA = tempDir + "/retract-a"
        let cloneB = tempDir + "/retract-b"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)

        try service.write(snapshot([]), toRoot: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "retract alpha"))
        try git.push(at: cloneA, credential: nil)

        try service.write(snapshot([record(slug: "alpha"), record(slug: "beta")]), toRoot: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "add beta"))
        XCTAssertEqual(try git.pullRebase(at: cloneB, credential: nil), .merged)
        try git.push(at: cloneB, credential: nil)
        XCTAssertEqual(try git.pullRebase(at: cloneA, credential: nil), .merged)

        XCTAssertEqual(try service.read(fromRoot: cloneA).deployIntents.map(\.skillSlug), ["beta"])
        XCTAssertEqual(try service.read(fromRoot: cloneB).deployIntents.map(\.skillSlug), ["beta"])
    }

    func testSameEntryRetractVsModifyConflicts() throws {
        let git = TestPaths.git
        let remote = try seedRemote(git: git, intents: [record()])
        let cloneA = tempDir + "/delete-a"
        let cloneB = tempDir + "/modify-b"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)
        try service.write(snapshot([]), toRoot: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "delete"))
        try git.push(at: cloneA, credential: nil)
        try service.write(snapshot([record(platform: "grok")]), toRoot: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "modify"))

        assertIntentConflict(try git.pullRebase(at: cloneB, credential: nil))
        try git.abortRebase(at: cloneB)
    }

    func testSameEntryConcurrentEditConflicts() throws {
        let git = TestPaths.git
        let remote = try seedRemote(git: git, intents: [record()])
        let cloneA = tempDir + "/edit-a"
        let cloneB = tempDir + "/edit-b"
        try git.clone(remote: remote, into: cloneA, credential: nil)
        try git.clone(remote: remote, into: cloneB, credential: nil)
        try service.write(snapshot([record(platform: "grok")]), toRoot: cloneA)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneA, message: "edit grok"))
        try git.push(at: cloneA, credential: nil)
        try service.write(snapshot([record(platform: "cursor")]), toRoot: cloneB)
        XCTAssertTrue(try git.stageAllAndCommit(at: cloneB, message: "edit cursor"))

        assertIntentConflict(try git.pullRebase(at: cloneB, credential: nil))
        try git.abortRebase(at: cloneB)
    }

    func testDeploysTreeExcludedFromUnionAttributes() throws {
        let git = TestPaths.git
        let remote = try seedRemote(git: git, intents: [])
        let clone = tempDir + "/attributes"
        try git.clone(remote: remote, into: clone, credential: nil)
        let engine = SyncEngine(
            gitService: AllowlistedRemoteGit(wrapping: git),
            manifestService: service,
            storeRebuildService: StoreRebuildService(),
            fileService: fileService,
            lockPath: tempDir + "/attributes.lock"
        )
        _ = try engine.sync(root: clone, message: "install controls", credential: nil, context: try makeContext())
        let attributes = try fileService.readFile(at: clone + "/.gitattributes")
        XCTAssertFalse(attributes.contains("deploys"))
        XCTAssertTrue(attributes.contains("manifest/categories/*.yaml merge=union"))
    }

    private func assertIntentConflict(
        _ result: PullResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .conflicted(paths) = result else {
            return XCTFail("expected conflict, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(paths, ["manifest/deploys/" + Self.machineA + "/alpha.yaml"], file: file, line: line)
    }

    private func seedRemote(git: GitService, intents: [DeployIntentRecord]) throws -> String {
        let remotePath = tempDir + "/remote-" + UUID().uuidString + ".git"
        XCTAssertEqual(try runGit(["init", "--bare", remotePath]), 0)
        let remote = "file://" + remotePath
        let seed = tempDir + "/seed-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try git.initRepository(at: seed)
        try git.setRemote(remote, at: seed)
        try service.write(snapshot(intents), toRoot: seed)
        XCTAssertTrue(try git.stageAllAndCommit(at: seed, message: "seed"))
        try git.push(at: seed, credential: nil)
        return remote
    }

    private func runGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
