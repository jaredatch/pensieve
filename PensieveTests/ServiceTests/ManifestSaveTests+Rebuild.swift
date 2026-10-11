import SwiftData
import XCTest
@testable import Pensieve

extension ManifestSaveTests {
    func testFallbackRefreshesRefusedMetadataBeforePublication() async throws {
        for corrupt in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            if corrupt {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
            } else { try h.files.deleteDirectory(at: h.root + "/manifest") }
            h.recording.failingWrites = 1
            h.library.updateMetadata(h.alpha, tags: ["a"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertNotNil(h.library.error)
            h.library.updateMetadata(h.alpha, tags: ["b"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertNil(h.library.error)
            XCTAssertEqual(h.recording.writes.count, 1)
            XCTAssertEqual(try h.manifest.read(fromRoot: h.root).skills.first { $0.slug == "alpha" }?.tags, ["b"])
            XCTAssertEqual(h.alpha.tags, ["b"], "A refused fallback edit must use the current context before publishing")
        }
    }

    func testFallbackKeepsUncomputedRefusedRetirement() async throws {
        for corrupt in [false, true] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            h.local.skillSlugs = ["alpha"]
            let intent = MachineDeployIntent(machineID: ProjectIntentHarness.localID, skillSlug: "alpha", platformRaw: "codex")
            h.context.insert(intent)
            try h.context.save()
            let pulled = try h.manifest.snapshot(from: h.context)
            h.local.skillSlugs = []
            h.context.delete(intent)
            try h.context.save()
            if corrupt {
                try h.files.writeFile(at: h.root + "/manifest/manifest.yaml", content: "not: [yaml\n")
            } else { try h.files.deleteDirectory(at: h.root + "/manifest") }
            h.recording.failingWrites = 1
            h.library.regenerateManifest(.retireSkill("alpha"), context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertNotNil(h.library.error)
            h.library.updateMetadata(h.beta, tags: ["healed"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            XCTAssertNil(h.library.error)
            try h.manifest.write(pulled, toRoot: h.root)
            h.library.updateMetadata(h.beta, tags: ["after-pull"], scope: .user, context: h.context)
            await h.saves.waitUntilIdle()
            let durable = try h.manifest.read(fromRoot: h.root)
            XCTAssertTrue(durable.categories.contains { $0.name == "Local" && $0.skillSlugs.contains("alpha") })
            XCTAssertTrue(durable.deployIntents.contains { $0.skillSlug == "alpha" })
            XCTAssertFalse(h.local.skillSlugs.contains("alpha"), "An uncomputed refusal must survive fallback acknowledgement")
            XCTAssertFalse(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).contains { $0.skillSlug == "alpha" })
        }
    }

    func testDeletingPulledCategoryRetiresItsRefusedMembership() async throws {
        let h = try ManifestSaveFixture()
        defer { h.cleanup() }
        h.recording.failingWrites = 1
        h.categories.setSkill(h.alpha, inCategory: h.local, assigned: true, context: h.context)
        await h.saves.waitUntilIdle()
        let reports = h.messages.lines.count
        var pulled = try h.manifest.read(fromRoot: h.root)
        pulled.categories.removeAll { $0.name == "Local" }
        try h.manifest.write(pulled, toRoot: h.root)
        h.categories.delete(h.local, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertFalse(try h.manifest.read(fromRoot: h.root).categories.contains { $0.name == "Local" })
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Pensieve.Category>()).contains { $0.name == "Local" })
        let messages = h.messages.lines.dropFirst(reports)
        XCTAssertFalse(messages.contains { $0.contains("could not be saved") || $0.contains("regeneration failed") })
        XCTAssertFalse(messages.contains { $0.contains("removed by sync") })
        XCTAssertEqual(h.recording.writes.count, 1, "The already-absent deletion still publishes")
    }

    func testHeldRebuildPreservesUnqueuedRowsAndNonAuthoritativeCategories() async throws {
        for authoritative in [true, false] {
            let h = try ManifestSaveFixture()
            defer { h.cleanup() }
            let completed = TestWait.Gate(owner: self)
            defer { completed.open() }
            h.recording.afterRebuildSnapshot = { try completed.wait() }
            if !authoritative {
                h.recording.afterWrite = { try? h.files.deleteDirectory(at: h.root + "/manifest") }
            }
            h.library.updateMetadata(h.alpha, tags: ["saved"], scope: .user, context: h.context)
            await TestWait.until(failureMessage: "The rebuild never held its completed snapshot") { completed.waiterCount == 1 }
            if !authoritative { XCTAssertFalse(h.files.directoryExists(at: h.root + "/manifest")) }
            let skill = Skill(name: "Unqueued", directoryName: "unqueued")
            let category = Pensieve.Category(name: "Unqueued")
            let skillID = skill.id, categoryID = category.id
            h.context.insert(skill)
            h.context.insert(category)
            try h.files.writeFile(at: skill.canonicalPath(skillsDirectory: h.root + "/skills"),
                content: SkillSerializer.serialize(name: skill.name, description: "description", body: "body"))
            try h.context.save()
            XCTAssertEqual(h.saves.pendingCount, 1, "These inserted rows submit no manifest change")
            if !authoritative {
                h.local.name = "Unpublished"
                try h.context.save()
            }
            completed.open()
            await h.saves.waitUntilIdle()
            XCTAssertTrue(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.id == skillID },
                "Acceptance must not delete a row that the scan never fetched")
            let categories = try h.context.fetch(FetchDescriptor<Pensieve.Category>())
            XCTAssertTrue(categories.contains { $0.id == categoryID })
            if !authoritative {
                XCTAssertEqual(h.local.name, "Unpublished")
                XCTAssertFalse(categories.contains { $0.name == "Local" }, "A non-authoritative scan cannot reconcile categories")
            }
        }
    }

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
        let reports = h.messages.lines.count
        h.recording.failingRebuildSnapshots = 1
        h.categories.rename(h.local, to: "Saved", context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.messages.lines.count, reports + 1)
        let message = try XCTUnwrap(h.messages.lines.last)
        XCTAssertEqual(message.components(separatedBy: "rebuild").count - 1, 1, message)
        XCTAssertTrue(message.contains(CocoaError(.fileReadCorruptFile).localizedDescription))
        try await checkSkippedRebuildFailure(h)
    }

    private func checkSkippedRebuildFailure(_ h: ManifestSaveFixture) async throws {
        var pulled = try h.manifest.read(fromRoot: h.root)
        pulled.skills.removeAll { $0.slug == "alpha" }
        try h.manifest.write(pulled, toRoot: h.root)
        let before = try h.manifestBytes(), writes = h.recording.writes.count
        h.recording.failingRebuildSnapshots = 1
        h.library.updateMetadata(h.alpha, tags: ["skipped"], scope: .project, context: h.context)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifestBytes(), before)
        XCTAssertEqual(h.recording.writes.count, writes)
        let message = try XCTUnwrap(h.library.error)
        XCTAssertTrue(message.localizedLowercase.contains("rebuild"), message)
        XCTAssertFalse(message.contains("manifest was saved"), "A skipped change never published: " + message)
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
