import SwiftData
import XCTest
@testable import Pensieve

extension CategorySaveUndoTests {
    func testRefusedMembershipChangesReverseRealLinksAndRules() async throws {
        for field in ["skill", "project", "delete"] {
            for adding in [true, false] where field != "delete" || !adding {
                let h = try ManifestSaveFixture()
                defer { h.cleanup() }
                let reconciler = try deployments(h)
                h.local.projectKeys = field == "project" && adding ? [] : ["local-key"]
                h.local.skillSlugs = field == "skill" && adding ? [] : ["alpha"]
                try h.context.save()
                try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
                XCTAssertFalse(reconciler.reconcile(context: h.context).hasFailures)
                let before = try h.manifestBytes()
                try assertArtifacts(h, present: !adding)
                h.recording.failingWrites = 1
                let result: BatchResult
                if field == "skill" {
                    result = h.categories.setSkill(h.alpha, inCategory: h.local, assigned: adding,
                        reconciler: reconciler, context: h.context)
                } else if field == "project" {
                    result = h.categories.setProject(h.project, inCategory: h.local, member: adding,
                        reconciler: reconciler, context: h.context)
                } else {
                    result = h.categories.delete(h.local, reconciler: reconciler, context: h.context)
                }
                XCTAssertFalse(result.hasFailures)
                try assertArtifacts(h, present: adding)
                await h.saves.waitUntilIdle()
                try assertArtifacts(h, present: !adding)
                XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), adding ? 0 : 2)
                XCTAssertEqual(try h.manifestBytes(), before)
            }
        }
        try await checkRefusalAfterPulledDeletion(fields: ["skill", "project"])
        try await checkRefusalAcrossSync(["skill-schema", "project-schema"])
    }

    func testUndoRetainsCleanupWhileProjectIsMissingAndRemovesWhenItReturns() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        let reconciler = try deployments(h)
        h.local.projectKeys = ["local-key"]
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
        defer { lock.release() }
        let before = try h.manifestBytes()
        let result = h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true,
            reconciler: reconciler, context: h.context)
        XCTAssertFalse(result.hasFailures)
        try assertArtifacts(h, present: true)
        await h.assertWaitingBehindHeldLock(pending: 1, before: before)
        let away = h.project.path + "-away"
        try FileManager.default.moveItem(atPath: h.project.path, toPath: away)
        h.recording.failingWrites = 1
        lock.release()
        await h.saves.waitUntilIdle()
        XCTAssertTrue(h.local.skillSlugs.isEmpty)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 2)
        XCTAssertFalse(h.files.directoryExists(at: h.project.path), "Undo must not recreate the missing project")
        try FileManager.default.moveItem(atPath: away, toPath: h.project.path)
        try assertArtifacts(h, present: true)
        XCTAssertFalse(reconciler.reconcile(context: h.context).hasFailures)
        try assertArtifacts(h, present: false)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<SkillProjectAssignment>()), 0)
    }

    private func deployments(_ h: ManifestSaveFixture) throws -> CategoryReconciler {
        try h.files.createDirectory(at: h.project.path)
        let paths = DeployPaths(skillsDirectory: h.root + "/skills", userSkillsDirectories: [:],
                                cursorUserRulesDirectory: h.root + "/cursor")
        let store = SkillStore(fileService: h.files, baseDir: h.root + "/skills", storeRoot: h.root)
        return CategoryReconciler(platformVM: PlatformViewModel(fileService: h.files,
            linkService: LinkService(fileService: h.files, paths: paths),
            cursorCompiler: CursorCompiler(fileService: h.files, skillStore: store, userRulesDirectory: h.root + "/cursor"),
            agentDetection: CategoryFixtureStubDetection(installed: [.claudeCode, .cursor]),
            deployStateStore: .memoryBacked, skillsDirectory: h.root + "/skills"))
    }

    private func assertArtifacts(_ h: ManifestSaveFixture, present: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let link = h.project.path + "/.claude/skills/alpha"
        let rule = h.project.path + "/.cursor/rules/alpha.mdc"
        XCTAssertEqual(h.files.isSymlink(at: link), present, file: file, line: line)
        XCTAssertEqual(h.files.fileExists(at: rule), present, file: file, line: line)
        if present {
            XCTAssertEqual(try h.files.symlinkTarget(at: link), h.root + "/skills/alpha", file: file, line: line)
            XCTAssertTrue(try h.files.readFile(at: rule).contains("# pensieve: managed"), file: file, line: line)
        }
    }
}
