import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillRenameWaitingWriteTests: XCTestCase {
    func testAnImportWhileARenameWaitsLeavesTheOtherMacsSkillAlone() async throws {
        let h = try fixture()
        XCTAssertTrue(h.rename())
        try h.arrivePeer()
        let before = try h.manifest.read(fromRoot: h.root)
        let peerBytes = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        let importer = h.waitingWriteImport(named: "Imported")
        _ = importer.importSelected(context: h.context)
        XCTAssertNil(importer.error)
        XCTAssertEqual(importer.importedSkillCount, 1)
        let immediate = try h.manifest.read(fromRoot: h.root)
        try assertProtectedNames(h, before: before, peerBytes: peerBytes)
        XCTAssertEqual(immediate.skills.first { $0.slug == "alpha" }, h.own)
        XCTAssertTrue(immediate.skills.contains { $0.slug == "imported" })
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertEqual(h.skill.directoryName, "alpha")
        XCTAssertTrue(try h.manifest.read(fromRoot: h.root).skills.contains { $0.slug == "imported" })
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peerBytes)
    }

    func testAnImportWhileARenameWaitsDoesNotTakeTheSkillsOldName() async throws {
        let h = try fixture()
        XCTAssertTrue(h.rename())
        try h.arrivePeer()
        let importer = h.waitingWriteImport(named: "Alpha")
        _ = importer.importSelected(context: h.context)
        XCTAssertNil(importer.error)
        XCTAssertEqual(importer.importedSkillCount, 1)
        let imported = try XCTUnwrap(h.context.fetch(FetchDescriptor<Skill>()).first {
            $0.id != h.skill.id && $0.name == "Alpha"
        })
        XCTAssertNotEqual(imported.directoryName, "alpha")
        XCTAssertTrue(try h.store.slugEntryExists(imported.directoryName))
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertEqual(h.skill.directoryName, "alpha")
        XCTAssertTrue(try h.store.slugEntryExists("alpha"))
        XCTAssertTrue(try h.store.slugEntryExists(imported.directoryName))
        let disk = try h.manifest.read(fromRoot: h.root)
        XCTAssertEqual(disk.skills.first { $0.slug == "alpha" }, h.own)
        XCTAssertTrue(disk.skills.contains { $0.slug == imported.directoryName })
        let ids = Set(try h.context.fetch(FetchDescriptor<Skill>()).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [h.skill.id, imported.id]))
    }

    func testADeploymentChangeToAnotherSkillWhileARenameWaitsLeavesTheOtherMacsSkillAlone() async throws {
        let h = try fixture()
        let service = h.waitingWriteDeployments()
        XCTAssertTrue(h.rename())
        try h.arrivePeer()
        try h.refreshWaitingWriteWindow()
        let before = try h.manifest.read(fromRoot: h.root)
        let peerBytes = try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml")
        let result = try service.set(true, skill: h.other, platform: .claudeCode,
            target: .project(h.projects[0]), context: h.context)
        XCTAssertFalse(result.hasFailures)
        try assertProtectedNames(h, before: before, peerBytes: peerBytes)
        try service.setRemote(true, machineID: h.peer, projectKey: nil, skill: h.other,
            platform: .claudeCode, context: h.context)
        let disk = try h.manifest.read(fromRoot: h.root)
        XCTAssertTrue(disk.deployIntents.contains(request(h, slug: "other", project: h.projects[0].identityKey)))
        XCTAssertTrue(disk.deployIntents.contains(request(h, slug: "other", machine: h.peer)))
        try assertProtectedNames(h, before: before, peerBytes: peerBytes)
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertEqual(h.skill.directoryName, "alpha")
    }

    func testADeploymentChangeToTheWaitingSkillIsRefusedAndWorksOnceTheRenameIsMovedBack() async throws {
        let h = try fixture()
        let service = h.waitingWriteDeployments()
        let initial = try service.setSelected(true, machineID: h.local, skill: h.skill,
            platform: .claudeCode, context: h.context)
        XCTAssertFalse(try XCTUnwrap(initial).hasFailures)
        let parent = (h.root as NSString).deletingLastPathComponent
        XCTAssertEqual(try h.files.symlinkTarget(at: parent + "/agent/alpha"), h.store.baseDir + "/alpha")
        XCTAssertTrue(h.rename())
        try h.arrivePeer()
        try h.refreshWaitingWriteWindow()
        let bytes = try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files)
        let window = try h.manifest.snapshot(from: h.context).deployIntents
        let artifacts = try h.waitingWriteArtifacts()
        let operations: [() throws -> Void] = [
            { _ = try service.setSelected(false, machineID: h.local, skill: h.skill,
                platform: .claudeCode, context: h.context) },
            { _ = try service.set(false, skill: h.skill, platform: .claudeCode,
                target: .project(h.projects[0]), context: h.context) },
            { try service.setRemote(true, machineID: h.peer, projectKey: h.projects[1].identityKey,
                skill: h.skill, platform: .claudeCode, context: h.context) }
        ]
        for operation in operations {
            assertWaitingRefusal(operation)
            XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files), bytes)
            XCTAssertEqual(try h.manifest.snapshot(from: h.context).deployIntents, window)
            XCTAssertEqual(try h.waitingWriteArtifacts(), artifacts)
        }
        await h.saves.waitUntilIdle()
        XCTAssertEqual(h.library.error, h.takenMessage())
        XCTAssertEqual(h.skill.directoryName, "alpha")
        XCTAssertTrue(try h.files.entryExistsWithoutFollowingLinks(at: parent + "/agent/alpha"))
        let result = try service.setSelected(false, machineID: h.local, skill: h.skill,
            platform: .claudeCode, context: h.context)
        XCTAssertFalse(try XCTUnwrap(result).hasFailures)
        let disk = try h.manifest.read(fromRoot: h.root)
        XCTAssertFalse(disk.deployIntents.contains(request(h, slug: "alpha")))
        XCTAssertFalse(try h.files.entryExistsWithoutFollowingLinks(at: parent + "/agent/alpha"))
        XCTAssertFalse(disk.skills.contains { $0.slug == "zulu" && ManifestService.sameCreation($0, h.own) })
    }

    func testASelectionWithTheWaitingSkillIsRefusedAndWorksOnceTheRenameGoesThrough() async throws {
        let h = try fixture()
        let service = h.waitingWriteDeployments()
        XCTAssertTrue(h.rename())
        try h.arrivePeer()
        try h.refreshWaitingWriteWindow()
        let bytes = try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files)
        let window = try h.manifest.snapshot(from: h.context).deployIntents
        let artifacts = try h.waitingWriteArtifacts()
        let skills = [h.other, h.skill]
        let pairs = skills.map { DeployMutationPair(skill: $0, platform: .claudeCode,
            machineID: h.local, target: .userWide, isLocal: true) }
        let operations: [() throws -> Void] = [
            { _ = try service.apply(skills: skills, platforms: [.claudeCode],
                selectedMachineIDs: [h.local], context: h.context) },
            { _ = try service.retract(skills: skills, platforms: [.claudeCode],
                machineIDs: [h.local], context: h.context) },
            { _ = try service.setProjectSelection(true, skills: skills, platforms: [.claudeCode],
                project: h.projects[0], context: h.context) },
            { _ = try service.change(true, pairs: pairs, dryRun: false, context: h.context) },
            { _ = try service.change(true, pairs: pairs, dryRun: true, context: h.context) }
        ]
        for operation in operations {
            assertWaitingRefusal(operation)
            XCTAssertEqual(try ManifestSaveFixture.manifestBytes(root: h.root, files: h.files), bytes)
            XCTAssertEqual(try h.manifest.snapshot(from: h.context).deployIntents, window)
            XCTAssertEqual(try h.waitingWriteArtifacts(), artifacts)
        }
        var pulled = try h.manifest.read(fromRoot: h.root)
        pulled.skills.removeAll { $0.slug == "zulu" }
        for index in pulled.categories.indices { pulled.categories[index].skillSlugs.removeAll { $0 == "zulu" } }
        pulled.deployIntents.removeAll { $0.skillSlug == "zulu" }
        try h.manifest.write(pulled, toRoot: h.root)
        try h.moveHead()
        await h.saves.waitUntilIdle()
        XCTAssertNil(h.library.error)
        XCTAssertEqual(h.skill.directoryName, "zulu")
        try h.assertOwn(h.manifest.read(fromRoot: h.root))
        _ = try service.apply(skills: skills, platforms: [.claudeCode], selectedMachineIDs: [h.local], context: h.context)
        let disk = try h.manifest.read(fromRoot: h.root)
        XCTAssertTrue(disk.deployIntents.contains(request(h, slug: "zulu")))
        XCTAssertTrue(disk.deployIntents.contains(request(h, slug: "other")))
        XCTAssertFalse(disk.deployIntents.contains { $0.skillSlug == "alpha" })
        XCTAssertFalse(disk.skills.contains { $0.slug == "alpha" })
    }

    private func fixture() throws -> SkillRenameTakeoverFixture {
        let h = try SkillRenameTakeoverFixture(record: false, leftovers: false)
        addTeardownBlock { @MainActor in
            await h.saves.waitUntilIdle()
            h.cleanup()
        }
        return h
    }

    private func request(_ h: SkillRenameTakeoverFixture, slug: String, machine: String? = nil,
                         project: String? = nil) -> DeployIntentRecord {
        DeployIntentRecord(machineID: machine ?? h.local, skillSlug: slug,
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: project)
    }

    private func assertWaitingRefusal(_ operation: () throws -> Void,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription,
                "Pensieve is still saving the rename of “Zulu”. Try again in a moment.", file: file, line: line)
        }
    }

    private func assertProtectedNames(_ h: SkillRenameTakeoverFixture, before: ManifestSnapshot, peerBytes: Data,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let disk = try h.manifest.read(fromRoot: h.root)
        let names: Set<String> = ["alpha", "zulu"]
        XCTAssertEqual(disk.skills.filter { names.contains($0.slug) }, before.skills.filter { names.contains($0.slug) },
            file: file, line: line)
        XCTAssertEqual(disk.categories, before.categories, file: file, line: line)
        XCTAssertEqual(disk.deployIntents.filter { names.contains($0.skillSlug) },
            before.deployIntents.filter { names.contains($0.skillSlug) }, file: file, line: line)
        XCTAssertEqual(try h.files.readData(at: h.root + "/manifest/skills/zulu.yaml"), peerBytes, file: file, line: line)
    }
}
