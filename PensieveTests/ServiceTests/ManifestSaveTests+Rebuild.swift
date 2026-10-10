import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testHeldRebuildKeepsMainActorRunningAndNewerEditsWin() async throws {
        for firstEdit in ["category", "metadata"] {
            let files = RebuildReadFileService()
            let h = try ManifestSaveFixture(rebuildFiles: files)
            defer { h.cleanup() }
            let first = TestWait.Gate(owner: self), second = TestWait.Gate(owner: self)
            let completed = TestWait.Gate(owner: self)
            defer { first.open(); second.open(); completed.open() }
            files.hold([first, second])
            var snapshots = 0
            h.recording.afterRebuildSnapshot = {
                snapshots += 1
                if snapshots == 1 { try completed.wait() }
            }
            var pulled = try h.manifest.read(fromRoot: h.root)
            pulled.categories.append(CategoryRecord(name: "Remote", projectKeys: [], skillSlugs: []))
            try h.manifest.write(pulled, toRoot: h.root)
            if firstEdit == "category" {
                h.categories.rename(h.local, to: "First", context: h.context)
            } else {
                h.library.updateMetadata(h.alpha, tags: ["first"], scope: .user, context: h.context)
            }
            await TestWait.until(failureMessage: "The first rebuild never read its skill") {
                files.mainThreadReads > 0 || first.waiterCount == 1
            }
            XCTAssertEqual(files.mainThreadReads, 0, firstEdit)
            guard files.mainThreadReads == 0 else { await h.saves.waitUntilIdle(); continue }
            XCTAssertEqual(first.waiterCount, 1, firstEdit)
            XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.name == "Remote" })
            // A main-actor turn can submit and persist another edit while the old disk read is held.
            let created = try submitNewerEdits(h)
            first.open()
            await TestWait.until(failureMessage: "The first rebuild never produced its plain result") {
                completed.waiterCount == 1
            }
            try assertNewerEdits(h, created: created)
            completed.open()
            await TestWait.until(failureMessage: "The second save never began its rebuild") { second.waiterCount == 1 }
            try assertNewerEdits(h, created: created)
            XCTAssertTrue(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.name == "Remote" })
            second.open()
            await h.saves.waitUntilIdle()
            XCTAssertEqual(h.alpha.tags, ["newest"], firstEdit)
            XCTAssertEqual(h.local.name, "Newest", firstEdit)
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["newest"])
            XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name)),
                ["Newest", "Remote", "ZDelete"], firstEdit)
        }
    }

    private func submitNewerEdits(_ h: ManifestSaveFixture) throws -> Skill {
        h.library.updateMetadata(h.alpha, tags: ["newest"], scope: .project, context: h.context)
        h.categories.rename(h.local, to: "Newest", context: h.context)
        let created = try XCTUnwrap(h.library.createSkill(name: "Concurrent", description: "d", body: "body",
            tags: ["created"], context: h.context))
        XCTAssertEqual(h.library.deleteSkillEntry(h.beta, context: h.context), .deleted)
        return created
    }

    private func assertNewerEdits(_ h: ManifestSaveFixture, created: Skill,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(h.alpha.tags, ["newest"], file: file, line: line)
        XCTAssertEqual(h.alpha.scope, .project, file: file, line: line)
        XCTAssertEqual(h.local.name, "Newest", file: file, line: line)
        let persisted = ModelContext(h.context.container)
        XCTAssertEqual(try persisted.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "alpha" }?.tags,
            ["newest"], "A worker may not save an old projection over a newer edit", file: file, line: line)
        XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<Skill>()).map(\.directoryName)),
            ["alpha", created.directoryName], file: file, line: line)
    }

    func testRefusedCategoryDeletionSurvivesLocalSkillRetirement() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.local.skillSlugs = ["alpha"]
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        h.recording.failingWrites = 1
        h.categories.delete(h.local, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.name == "Local" })
        XCTAssertTrue(try h.manifest.read(fromRoot: h.root).categories.contains { $0.name == "Local" })
        let platform = PlatformViewModel(fileService: h.files,
            linkService: TestPaths.linkService(fileService: h.files),
            cursorCompiler: TestPaths.cursorCompiler(fileService: h.files),
            agentDetection: DeployStubDetection(installed: []), deployStateStore: .memoryBacked,
            skillsDirectory: h.root + "/skills")
        XCTAssertTrue(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: platform,
            projects: [], context: h.context))
        await h.saves.waitUntilIdle()
        let durable = try XCTUnwrap(try h.manifest.read(fromRoot: h.root).categories.first { $0.name == "Local" })
        XCTAssertTrue(durable.skillSlugs.isEmpty, "The later save must really rewrite the refused category's record")
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.name == "Local" },
            "A successful local retirement must not look like a pulled recreation")
    }

    func testRebuildFailureAfterManifestSuccessNamesTheRebuild() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.recording.failingRebuildSnapshots = 1
        h.library.updateMetadata(h.alpha, tags: ["saved"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["saved"])
        let error = try XCTUnwrap(h.library.error)
        XCTAssertTrue(error.localizedLowercase.contains("rebuild"), error)
        XCTAssertFalse(error.contains("updating the sync manifest failed"), error)
        h.library.updateMetadata(h.alpha, tags: ["recovered"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error)
        XCTAssertEqual(h.alpha.tags, ["recovered"])
    }

    func testDeletingRefusedRenamePublishesOriginalRemovalOrReportsRefusal() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.recording.failingWrites = 1
        h.categories.rename(h.local, to: "Refused", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.local.name, "Refused")
        let reports = h.messages.lines.count
        h.categories.delete(h.local, context: h.context)
        await h.saves.waitUntilIdle()
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertTrue(!durable.categories.contains { $0.name == "Local" }
            || h.messages.lines.dropFirst(reports).contains { $0.contains("could not be saved") },
            "Deleting a refused rename cannot silently leave its original record on other Macs")
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.name == "Refused" })
    }
}
