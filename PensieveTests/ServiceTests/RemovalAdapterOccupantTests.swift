import Foundation
import XCTest
@testable import Pensieve

@MainActor
final class RemovalAdapterOccupantTests: XCTestCase {
    func testForeignReplacementNeverReportsAbsentDuplicateThroughSharedAdapters() throws {
        for platform in [PlatformTarget.codex, .cursor] {
            let h = try WaitingRemovalHarness(platforms: [platform])
            defer { h.base.cleanup() }
            h.vm.deploy(skill: h.base.skill, platform: platform, context: h.base.context)
            let adapter = ReplacementRemovalAdapter(files: h.mapped)
            let vm = PlatformViewModel(
                fileService: h.mapped,
                linkService: adapter,
                cursorCompiler: adapter,
                agentDetection: DeployStubDetection(installed: [platform]),
                deployStateStore: h.base.deployState, skillsDirectory: TestPaths.skillsDir
            )
            let pair = DeployRemovalPair(skill: h.base.skill, platform: platform)
            let result = vm.removeOwnedBatch(pairs: [pair, pair], target: .userWide)
            XCTAssertFalse(result.hasFailures)
            XCTAssertEqual(result.successes.count, 1, "A foreign replacement must not count as an absent duplicate")
            let path = vm.artifactPath(skill: h.base.skill, platform: platform, target: .userWide)
            XCTAssertEqual(try h.mapped.readFile(at: path + "/user-file"), "Keep my folder")
            XCTAssertTrue(try h.base.deployState.read().records.isEmpty)
        }
    }
}

/// Uses the shared fixture operations around real leaf owners. After a successful removal,
/// a foreign directory replaces the leaf; metadata-only Cursor presence intentionally says false.
private final class ReplacementRemovalAdapter: LinkServiceProtocol, CursorCompilerProtocol {
    let files: FileServiceProtocol
    let links: LinkService
    let cursor: CursorCompiler

    init(files: FileServiceProtocol) {
        self.files = files
        links = TestPaths.linkService(fileService: files)
        cursor = CursorCompiler(
            fileService: files,
            skillStore: SkillStore(fileService: files, baseDir: TestPaths.skillsDir),
            userRulesDirectory: TestPaths.deployPaths.cursorUserRulesDirectory
        )
    }

    func removalOperation(skill: Skill, platform: PlatformTarget, projectPath: String?) -> DeployRemovalOperation {
        platform.usesSymlinks ? adapterRemovalOperation(skill: skill, platform: platform, projectPath: projectPath)
            : adapterRemovalOperation(skill: skill, projectPath: projectPath)
    }

    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        try links.link(skill: skill, platform: platform, projectPath: projectPath)
    }
    func compile(skill: Skill, projectPath: String?) throws { try cursor.compile(skill: skill, projectPath: projectPath) }
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        let removed = try links.unlink(skill: skill, platform: platform, projectPath: projectPath)
        if removed { try replace(linkPath(skill: skill, platform: platform, projectPath: projectPath)) }
        return removed
    }
    func remove(skill: Skill, projectPath: String?) throws -> Bool {
        let removed = try cursor.remove(skill: skill, projectPath: projectPath)
        if removed { try replace(outputPath(skill: skill, projectPath: projectPath)) }
        return removed
    }
    private func replace(_ path: String) throws {
        try files.createDirectory(at: path)
        try files.writeFile(at: path + "/user-file", content: "Keep my folder")
    }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try links.ownsArtifact(skill: skill, platform: platform, projectPath: projectPath)
    }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool {
        try cursor.ownsArtifact(skill: skill, projectPath: projectPath)
    }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        try cursor.probeRulePresence(skill: skill, projectPath: projectPath)
    }
    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        links.isLinked(skill: skill, platform: platform, projectPath: projectPath)
    }
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { cursor.isUpToDate(skill: skill, projectPath: projectPath) }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool {
        try cursor.hasOwnershipMark(skill: skill, projectPath: projectPath)
    }
    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        links.linkPath(skill: skill, platform: platform, projectPath: projectPath)
    }
    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        links.targetPath(skill: skill, platform: platform, projectPath: projectPath)
    }
    func outputPath(skill: Skill, projectPath: String?) -> String { cursor.outputPath(skill: skill, projectPath: projectPath) }
    func validateAll(skills: [Skill]) -> [BrokenLink] { links.validateAll(skills: skills) }
}
