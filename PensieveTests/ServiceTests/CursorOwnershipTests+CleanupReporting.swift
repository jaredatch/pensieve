import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    @MainActor
    func testRecordOnlyCleanupDoesNotReportArtifactDeletion() throws {
        let harness = try contextAndVM()
        let path = artifactPath(.cursor, project: nil)
        try reviewRecord(harness.state, path: path, target: .userWide)
        let before = harness.vm.refreshCounter
        let result = harness.vm.removeAllDeploys(skill: skill, projects: [], localProjectEvidence:
            localProjectDeployEvidence(harness.vm, skill: skill, projects: [], context: harness.context))
        XCTAssertFalse(result.batch.hasFailures)
        XCTAssertFalse(result.didChangeDeploys, "Retiring a stale record did not delete an artifact")
        XCTAssertTrue(try harness.state.read().records.isEmpty)
        XCTAssertEqual(harness.vm.refreshCounter, before + 1, "Record retirement still refreshes the index")
    }

    @MainActor
    func testRemovalRecheckPreservesReplacementWithoutReportingDeletion() throws {
        let harness = try contextAndVM()
        let path = artifactPath(.cursor, project: nil)
        try compiler.compile(skill: skill, projectPath: nil)
        let replacement = "User replacement"
        let targeted = CleanupRemovalCompiler(wrapped: compiler) {
            try self.mapped.writeFile(at: path, content: replacement)
        }
        let vm = PlatformViewModel(fileService: mapped, cursorCompiler: targeted,
            agentDetection: DeployStubDetection(installed: [.cursor]), deployStateStore: harness.state)
        let before = vm.refreshCounter
        let result = vm.removeAllDeploys(skill: skill, projects: [], localProjectEvidence:
            localProjectDeployEvidence(vm, skill: skill, projects: [], context: harness.context))
        XCTAssertFalse(result.batch.hasFailures)
        XCTAssertFalse(result.didChangeDeploys, "The leaf recheck preserved the replacement")
        XCTAssertEqual(vm.refreshCounter, before, "No artifact or record changed")
        XCTAssertEqual(try mapped.readFile(at: path), replacement)
    }

    @MainActor
    func testFailureOnlyCleanupDoesNotRefreshDeployState() throws {
        let harness = try contextAndVM()
        let path = artifactPath(.cursor, project: nil)
        try compiler.compile(skill: skill, projectPath: nil)
        mapped.beforeRuleRead = { candidate in
            if candidate == self.root + "/user/rules/" + self.skill.directoryName + ".mdc" {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
        }
        defer { mapped.beforeRuleRead = nil }
        let before = harness.vm.refreshCounter
        let result = harness.vm.removeAllDeploys(skill: skill, projects: [], localProjectEvidence:
            localProjectDeployEvidence(harness.vm, skill: skill, projects: [], context: harness.context))
        XCTAssertEqual(result.batch.failureCount, 1)
        XCTAssertFalse(result.didChangeDeploys)
        XCTAssertEqual(harness.vm.refreshCounter, before)
        XCTAssertTrue(try mapped.entryExistsWithoutFollowingLinks(at: path))
    }

    @MainActor
    func testRetirementSaveFailureNoticeReportsOnlyDeletedArtifacts() throws {
        for deployed in [false, true] {
            let harness = try contextAndVM()
            if deployed { try compiler.compile(skill: skill, projectPath: nil) }
            let library = SkillLibraryViewModel(skillStore: store, fileService: mapped,
                manifestService: RecordingDeletionManifest(), manifestRoot: root + "/manifest")
            XCTAssertFalse(SkillDeletionFlow.delete(skill: skill, library: library, platformVM: harness.vm,
                projects: [], context: harness.context, persist: { _ in throw DeletionTestError() }))
            XCTAssertEqual(library.deletionNotice?.message.contains("already removed"), deployed)
            XCTAssertFalse(library.deletionNotice?.message.contains("Removed agent links and rules") == true)
            XCTAssertTrue(library.deletionNotice?.message.contains("skill was kept") == true)
            XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<Skill>()), 1)
        }
    }
}

private struct CleanupRemovalCompiler: CursorCompilerProtocol {
    let wrapped: CursorCompilerProtocol
    let beforeRemoval: () throws -> Void
    func removalOperation(skill: Skill, platform: PlatformTarget,
                          projectPath: String?) -> DeployRemovalOperation {
        let operation = wrapped.removalOperation(skill: skill, platform: platform, projectPath: projectPath)
        return DeployRemovalOperation(classify: {
            try beforeRemoval()
            return try operation.classify()
        }, delete: operation.delete)
    }
    func compile(skill: Skill, projectPath: String?) throws { try wrapped.compile(skill: skill, projectPath: projectPath) }
    func remove(skill: Skill, projectPath: String?) throws -> Bool {
        try beforeRemoval()
        return try wrapped.remove(skill: skill, projectPath: projectPath)
    }
    func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool {
        try wrapped.ownsArtifact(skill: skill, projectPath: projectPath)
    }
    func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool {
        try wrapped.ruleMayExist(skill: skill, projectPath: projectPath)
    }
    func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool {
        try wrapped.hasOwnershipMark(skill: skill, projectPath: projectPath)
    }
    func isUpToDate(skill: Skill, projectPath: String?) -> Bool { wrapped.isUpToDate(skill: skill, projectPath: projectPath) }
    func outputPath(skill: Skill, projectPath: String?) -> String { wrapped.outputPath(skill: skill, projectPath: projectPath) }
}
