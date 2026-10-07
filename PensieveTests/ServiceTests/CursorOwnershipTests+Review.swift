import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testDuplicateSlugSelectionReportsEachInputSeparately() throws {
        let h = try contextAndVM()
        let project = reviewProject(h.context)
        let second = Skill(name: "Second row", directoryName: skill.directoryName)
        h.context.insert(second)
        let path = artifactPath(.claudeCode, project: project.path)
        try plant(owned: true, legacy: false, platform: .claudeCode, path: path, project: project.path)
        try reviewRecord(h.state, path: path, platform: .claudeCode, target: .project(project))
        let result = h.vm.removeOwnedBatch(pairs: [DeployRemovalPair(skill: skill, platform: .claudeCode),
            DeployRemovalPair(skill: second, platform: .claudeCode)], target: .project(project))
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.successes.map(\.skillID), [skill.id], "A duplicate input does not share the first success")
        XCTAssertEqual(result.retiredPairs, [BatchPairKey(skillID: second.id, platform: .claudeCode,
            target: .project(project.id))])
        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertTrue(try h.state.read().records.isEmpty)
    }

    @MainActor
    func testProtocolAdapterUsesPreparedClassifyOnceOperation() throws {
        let h = try contextAndVM()
        let project = reviewProject(h.context)
        let path = artifactPath(.claudeCode, project: project.path)
        try plant(owned: true, legacy: false, platform: .claudeCode, path: path, project: project.path)
        try reviewRecord(h.state, path: path, platform: .claudeCode, target: .project(project))
        let adapter = ReviewLinkAdapter(wrapped: LinkService(fileService: mapped))
        let vm = PlatformViewModel(fileService: mapped, linkService: adapter,
            agentDetection: DeployStubDetection(installed: [.claudeCode]), deployStateStore: h.state)
        var reads = 0
        mapped.beforeSymlinkRead = { _ in reads += 1 }
        let result = vm.removeOwnedBatch(pairs: [DeployRemovalPair(skill: skill, platform: .claudeCode)],
            target: .project(project))
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(reads, 1, "A non-concrete adapter uses its prepared operation")
        XCTAssertFalse(try mapped.entryExistsWithoutFollowingLinks(at: path))
        XCTAssertTrue(try h.state.read().records.isEmpty)
    }

    @MainActor
    func testAdmittedProbeFailureNeverPreparesArtifactOperation() throws {
        let h = try contextAndVM()
        let project = reviewProject(h.context)
        let path = artifactPath(.cursor, project: project.path)
        let bytes = "---\n# pensieve: managed\n---\nKeep"
        try mapped.writeFile(at: path, content: bytes)
        h.context.insert(DeployRecord(skillID: skill.id, platform: .cursor,
            targetPath: path, contentHash: "local", projectID: project.id))
        try h.context.save()
        let adapter = ReviewCursorAdapter(wrapped: compiler)
        let vm = PlatformViewModel(fileService: mapped, cursorCompiler: adapter,
            agentDetection: DeployStubDetection(installed: [.cursor]), deployStateStore: h.state)
        mapped.beforeEntryTypeProbe = { candidate in
            if candidate == path { throw DeletionTestError() }
        }
        let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
            manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
        XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: vm,
            projects: [project], context: h.context))
        XCTAssertFalse(adapter.preparedPaths.contains(path), "A failed admission has no artifact operation")
        XCTAssertTrue(library.deletionNotice?.message.contains("Could not check ownership") == true)
        XCTAssertEqual(try mapped.readFile(at: path), bytes)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<Skill>()), 1)
    }

    func testCursorRemovalOperationRefusesLinkAgents() throws {
        for project: String? in [nil, root + "/project"] {
            try compiler.compile(skill: skill, projectPath: project)
            let path = compiler.outputPath(skill: skill, projectPath: project)
            let bytes = try mapped.readFile(at: path)
            for platform in PlatformTarget.allCases where platform != .cursor {
                let operation = compiler.removalOperation(skill: skill, platform: platform, projectPath: project)
                XCTAssertFalse(try DeployRemovalService.removeArtifact(operation), "Cursor refuses \(platform)")
                XCTAssertEqual(try mapped.readFile(at: path), bytes)
            }
        }
    }
}

private struct ReviewLinkAdapter: LinkServiceProtocol {
    let wrapped: LinkService
    func removalOperation(skill: Skill, platform: PlatformTarget,
                          projectPath: String?) -> DeployRemovalOperation {
        wrapped.removalOperation(skill: skill, platform: platform, projectPath: projectPath)
    }
    func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {
        try wrapped.link(skill: skill, platform: platform, projectPath: projectPath)
    }
    func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try wrapped.unlink(skill: skill, platform: platform, projectPath: projectPath)
    }
    func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool {
        try wrapped.ownsArtifact(skill: skill, platform: platform, projectPath: projectPath)
    }
    func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool {
        wrapped.isLinked(skill: skill, platform: platform, projectPath: projectPath)
    }
    func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        wrapped.linkPath(skill: skill, platform: platform, projectPath: projectPath)
    }
    func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String {
        wrapped.targetPath(skill: skill, platform: platform, projectPath: projectPath)
    }
    func validateAll(skills: [Skill]) -> [BrokenLink] { wrapped.validateAll(skills: skills) }
}

private final class ReviewCursorAdapter: CursorCompilerProtocol {
    let wrapped: CursorCompiler
    var preparedPaths: [String] = []
    init(wrapped: CursorCompiler) { self.wrapped = wrapped }
    func removalOperation(skill: Skill, platform: PlatformTarget,
                          projectPath: String?) -> DeployRemovalOperation {
        preparedPaths.append(outputPath(skill: skill, projectPath: projectPath))
        return wrapped.removalOperation(skill: skill, platform: platform, projectPath: projectPath)
    }
    func compile(skill: Skill, projectPath: String?) throws { try wrapped.compile(skill: skill, projectPath: projectPath) }
    func remove(skill: Skill, projectPath: String?) throws -> Bool { try wrapped.remove(skill: skill, projectPath: projectPath) }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool {
        try wrapped.ownsArtifact(skill: skill, projectPath: projectPath)
    }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        try wrapped.probeRulePresence(skill: skill, projectPath: projectPath)
    }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool {
        try wrapped.hasOwnershipMark(skill: skill, projectPath: projectPath)
    }
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { wrapped.isUpToDate(skill: skill, projectPath: projectPath) }
    func outputPath(skill: Skill, projectPath: String?) -> String { wrapped.outputPath(skill: skill, projectPath: projectPath) }
}
