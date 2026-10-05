import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDeletionFlowTests: XCTestCase {
    struct Fixture {
        let context: ModelContext
        let skill: Skill
        let store: RecordingDeletionSkillStore
        let manifest: RecordingDeletionManifest
        let links: DeletionTestLinkService
        let cursor: DeletionTestCursorCompiler
        let state: DeployStateStore
        let library: SkillLibraryViewModel
        let platform: PlatformViewModel
        let watcher: RecordingWatcher
        let counter: DeletionCounter
        let project: Project
    }

    private func fixture(slug: String = "alpha") throws -> Fixture {
        let context = ModelContext(try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)))
        let skill = Skill(name: "Alpha", directoryName: slug)
        let project = Project(name: "Project", path: "/project")
        context.insert(skill)
        context.insert(project)
        try context.save()
        let store = RecordingDeletionSkillStore()
        store.bodies[slug] = "body"
        store.entries.insert(slug)
        let manifest = RecordingDeletionManifest()
        let links = DeletionTestLinkService()
        let cursor = DeletionTestCursorCompiler()
        let watcher = RecordingWatcher()
        let counter = DeletionCounter()
        let stateFS = MemoryDeployFileService()
        let stateRoot = TestTemporaryDirectory.path + "PensieveDeletionState-\(UUID().uuidString)"
        let state = DeployStateStore(fileService: stateFS, appSupportDir: stateRoot)
        let library = SkillLibraryViewModel(
            skillStore: store, fileService: stateFS,
            fileWatchService: watcher, manifestService: manifest, manifestRoot: "/manifest",
            notifier: counter.notify)
        library.startWatching()
        let platform = PlatformViewModel(
            fileService: stateFS, linkService: links, cursorCompiler: cursor,
            agentDetection: DeletionTestDetection(installed: [.claudeCode, .cursor]),
            deployStateStore: state)
        return Fixture(context: context, skill: skill, store: store, manifest: manifest,
                       links: links, cursor: cursor, state: state, library: library,
                       platform: platform, watcher: watcher, counter: counter, project: project)
    }

    private func seedAllState(_ f: Fixture) throws {
        f.context.insert(MachineDeployIntent(machineID: UUID().uuidString,
                                             skillSlug: f.skill.directoryName, platformRaw: "codex"))
        f.context.insert(MachineDeployIntent(
            machineID: UUID().uuidString,
            skillSlug: f.skill.directoryName,
            platformRaw: "cursor",
            projectKey: "github.com/owner/project"
        ))
        f.context.insert(IntentAssignment(skillID: f.skill.id, platformRaw: "codex"))
        f.context.insert(SkillProjectAssignment(skillID: f.skill.id, projectID: f.project.id,
                                                platform: .claudeCode))
        f.context.insert(ScenarioAssignment(skillID: f.skill.id, platform: .cursor))
        let category = Category(name: "Category")
        category.skillSlugs = [f.skill.directoryName]
        let scenario = Scenario(name: "Scenario")
        scenario.skillSlugs = [f.skill.directoryName]
        f.context.insert(category)
        f.context.insert(scenario)
        try f.context.save()
    }

    private func delete(_ f: Fixture, persist: ((ModelContext) throws -> Void)? = nil) -> Bool {
        SkillDeletionFlow.delete(
            skill: f.skill, library: f.library, platformVM: f.platform, projects: [f.project],
            context: f.context, persist: persist ?? { try $0.save() })
    }

    func testDeleteRetainsSkillWhenAnyRemovalFails() throws {
        let f = try fixture(); try seedAllState(f)
        let path = f.links.path(f.skill, .claudeCode, nil)
        f.links.linkedPaths.insert(path); f.links.failingUnlinkPaths.insert(path)
        try f.state.upsert(record(f, path: path, platform: .claudeCode))
        XCTAssertFalse(delete(f)); XCTAssertNotNil(f.library.deletionNotice)
        XCTAssertTrue(f.library.deletionNotice?.message.contains("injected failure") == true)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Skill>()).count, 1)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).count, 2)
        XCTAssertTrue(f.store.entries.contains(f.skill.directoryName))
        XCTAssertTrue(f.manifest.snapshots.isEmpty); XCTAssertEqual(f.counter.value, 0)
    }

    func testDeleteRetiresEveryStateClassThenDeletesSkill() throws {
        let f = try fixture(); try seedAllState(f)
        f.context.insert(MachineDeployIntent(machineID: UUID().uuidString,
                                             skillSlug: "other", platformRaw: "cursor")); try f.context.save()
        XCTAssertTrue(delete(f)); XCTAssertEqual(f.counter.value, 1)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Skill>()).count, 0)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.skillSlug), ["other"])
        XCTAssertTrue(try f.context.fetch(FetchDescriptor<Pensieve.Category>()).allSatisfy { $0.skillSlugs.isEmpty })
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Scenario>()).map(\.skillSlugs), [["alpha"]])
        XCTAssertEqual(try f.context.fetchCount(FetchDescriptor<ScenarioAssignment>()), 0)
        XCTAssertEqual(f.store.deleteCalls, ["alpha"]); XCTAssertNil(f.library.deletionNotice)
        XCTAssertTrue(f.manifest.snapshots.last?.skills.isEmpty == true)
        XCTAssertFalse(f.manifest.snapshots.last?.deployIntents.contains { $0.skillSlug == "alpha" } == true)
    }

    func testDeleteRollsBackEveryStateClassWhenRetirementSaveFails() throws {
        let f = try fixture(); try seedAllState(f)
        XCTAssertFalse(delete(f, persist: { _ in throw DeletionTestError() }))
        XCTAssertFalse(f.context.hasChanges); XCTAssertEqual(f.counter.value, 0)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<MachineDeployIntent>()).count, 2)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<IntentAssignment>()).count, 1)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<SkillProjectAssignment>()).count, 1)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ScenarioAssignment>()).count, 1)
        XCTAssertTrue(f.manifest.snapshots.isEmpty); XCTAssertTrue(f.store.entries.contains("alpha"))
    }

    func testDeleteReportsDirectoryDeleteFailure() throws {
        let f = try fixture(); try seedAllState(f); f.store.deleteFailures.insert("alpha")
        XCTAssertFalse(delete(f)); XCTAssertEqual(f.counter.value, 1)
        XCTAssertNotNil(try f.context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<IntentAssignment>()).count, 0)
        XCTAssertEqual(f.manifest.snapshots.count, 1)
    }

    func testDeleteWarnsWhenFinalManifestWriteFails() throws {
        let f = try fixture(); f.manifest.failingWrites = [1, 2]
        XCTAssertTrue(delete(f)); XCTAssertEqual(f.counter.value, 0)
        guard case .warning(let message) = f.library.deletionNotice else { return XCTFail("warning") }
        XCTAssertTrue(message.contains("manifest"))
    }

    func testDeleteIsQuietWhenFinalManifestWriteSucceedsAfterEarlierFailure() throws {
        let f = try fixture(); f.manifest.failingWrites = [1]
        XCTAssertTrue(delete(f)); XCTAssertNil(f.library.deletionNotice); XCTAssertNil(f.library.error)
        XCTAssertEqual(f.counter.value, 1); XCTAssertEqual(f.manifest.snapshots.count, 1)
    }

    func testDeleteReportsRowRetainedWhenRowSaveFails() throws {
        let f = try fixture(); var calls = 0; let before = f.library.reloadToken
        XCTAssertFalse(delete(f, persist: { context in
            calls += 1; if calls == 2 { throw DeletionTestError() }; try context.save()
        }))
        XCTAssertFalse(f.context.hasChanges); XCTAssertEqual(f.library.pendingRowCleanup, [f.skill.id])
        XCTAssertEqual(f.library.reloadToken, before + 1); XCTAssertEqual(f.counter.value, 1)
        f.context.rollback(); try f.context.save()
        XCTAssertNotNil(try f.context.fetch(FetchDescriptor<Skill>()).first)
    }

    func testQuarantinedRowRefusesEveryWrite() throws {
        let f = try quarantinedFixture()
        XCTAssertFalse(f.library.updateBody(f.skill, body: "resurrect").succeeded)
        f.library.noteEditorChanged(f.skill, body: "resurrect"); XCTAssertFalse(f.library.saveDraft(f.skill))
        XCTAssertThrowsError(try restoreSkillHistoryVersion(
            skill: f.skill, body: "resurrect", store: f.store, library: f.library, notifier: {}))
        XCTAssertTrue(f.store.writeSkillCalls.isEmpty); XCTAssertTrue(f.store.writeBodyCalls.isEmpty)
        XCTAssertEqual(f.counter.value, 1)
    }

    func testDeleteRetryCompletesForQuarantinedRow() throws {
        let f = try quarantinedFixture(); f.counter.reset()
        XCTAssertTrue(delete(f)); XCTAssertEqual(f.counter.value, 1)
        XCTAssertTrue(f.library.pendingRowCleanup.isEmpty)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Skill>()).count, 0)
    }

    func testDeleteRetryRetainsRowWhoseFilesCameBack() throws {
        for arm in 0..<7 {
            let f = try quarantinedFixture(); f.counter.reset()
            f.store.deleteFailures.insert("alpha")
            switch arm {
            case 0: f.store.bodies["alpha"] = "restored"; f.store.entries.insert("alpha")
            case 1: f.store.entries.insert("alpha")
            case 2: f.store.entries.insert("alpha"); f.store.unsafeLeaves.insert("alpha")
            case 3: f.store.entryProbeError = true
            case 4: f.store.bodies["alpha"] = "restored"; f.store.entries.remove("alpha")
            case 5: f.store.entryAnswers = [false, true]
            default: f.store.readAnswers = [false, true]; f.store.bodies["alpha"] = "restored"
            }
            XCTAssertFalse(delete(f), "arm \(arm)")
            XCTAssertNotNil(try f.context.fetch(FetchDescriptor<Skill>()).first)
            XCTAssertEqual(f.counter.value, 1)
            if arm == 0 || arm == 4 || arm == 6 { XCTAssertTrue(f.library.pendingRowCleanup.isEmpty) }
        }
    }

    func testDeleteRetryRetainsRowWhoseEntryStillExists() throws {
        // Quarantined, but the slug directory is back with an unreadable (unsafe) leaf and the store's
        // delete would succeed: the retry must probe first and retain — the directory is never deleted.
        let f = try quarantinedFixture(); f.counter.reset()
        f.store.bodies["alpha"] = "present"; f.store.entries.insert("alpha"); f.store.unsafeLeaves.insert("alpha")
        let deletesBefore = f.store.deleteCalls.count
        XCTAssertFalse(delete(f))
        XCTAssertEqual(f.store.deleteCalls.count, deletesBefore, "the directory must not be deleted")
        XCTAssertNotNil(try f.context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertTrue(f.library.pendingRowCleanup.contains(f.skill.id))
        XCTAssertEqual(f.counter.value, 1)   // the flow's final manifest write still nudges once, as on every retained arm
        XCTAssertEqual(f.library.deletionNotice?.title, "Couldn't delete skill")
    }

}

extension SkillDeletionFlowTests {

    func testCreateAbortsWhenRowsCannotBeFetched() throws {
        let f = try fixture()
        f.library.createSkill(name: "New", description: "", body: "", tags: [],
                              context: f.context, takenSlugs: { _ in throw DeletionTestError() })
        XCTAssertTrue(f.store.createAvoiding.isEmpty); XCTAssertNotNil(f.library.error)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<Skill>()).count, 1)
        XCTAssertEqual(f.counter.value, 0)
    }

    func testDeleteRefusesWhenLibraryUnavailable() throws {
        let f = try fixture(); try seedAllState(f)
        let path = f.links.path(f.skill, .claudeCode, nil); f.links.linkedPaths.insert(path)
        f.library.refreshQuarantine(context: f.context, fetch: { _ in throw DeletionTestError() })
        XCTAssertFalse(delete(f)); XCTAssertTrue(f.links.unlinkCalls.isEmpty); XCTAssertEqual(f.counter.value, 0)
        XCTAssertFalse(f.library.updateBody(f.skill, body: "x").succeeded)
        f.library.createSkill(name: "Blocked", description: "", body: "x", tags: [],
                              context: f.context)
        XCTAssertTrue(f.store.createAvoiding.isEmpty)
        f.library.refreshQuarantine(context: f.context); XCTAssertFalse(f.library.libraryUnavailable)
        XCTAssertTrue(delete(f)); XCTAssertEqual(f.counter.value, 1)
    }

    func testDeleteWatcherEchoIsNotASecondNudge() throws {
        let f = try fixture(); XCTAssertTrue(delete(f)); let token = f.library.reloadToken
        f.watcher.emit("alpha")
        XCTAssertEqual(f.counter.value, 1); XCTAssertTrue(f.library.externallyModified.isEmpty)
        XCTAssertEqual(f.library.reloadToken, token)
    }

    func testRefreshQuarantineIsRebuiltFromMissingFiles() throws {
        let f = try fixture(); let missing = Skill(name: "Missing", directoryName: "missing")
        let unsafe = Skill(name: "Unsafe", directoryName: "unsafe")
        f.context.insert(missing); f.context.insert(unsafe); try f.context.save()
        f.store.entries.insert("unsafe"); f.store.unsafeLeaves.insert("unsafe")
        f.library.refreshQuarantine(context: f.context)
        XCTAssertEqual(f.library.pendingRowCleanup, [missing.id, unsafe.id])
        f.store.bodies["missing"] = "restored"; f.store.entries.insert("missing")
        f.library.refreshQuarantine(context: f.context); XCTAssertEqual(f.library.pendingRowCleanup, [unsafe.id])
        f.library.refreshQuarantine(context: f.context, fetch: { _ in throw DeletionTestError() })
        XCTAssertTrue(f.library.libraryUnavailable); XCTAssertEqual(f.counter.value, 0)
        f.library.refreshQuarantine(context: f.context); XCTAssertFalse(f.library.libraryUnavailable)
    }

    func testCreateAvoidsEveryRowSlug() throws {
        let f = try fixture(slug: "PDF-Tools")
        f.library.createSkill(name: "PDF Tools", description: "", body: "body", tags: [],
                              context: f.context)
        XCTAssertTrue(f.store.createAvoiding[0].contains("PDF-Tools"))
        let slugs = try f.context.fetch(FetchDescriptor<Skill>()).map(\.directoryName)
        XCTAssertEqual(Set(slugs.map { $0.lowercased() }), ["pdf-tools", "pdf-tools-2"])
        XCTAssertEqual(f.counter.value, 1)
    }

    func testDeleteNeverRedeploysTheDeletedSkill() throws {
        let f = try fixture(); try seedAllState(f); XCTAssertTrue(delete(f))
        XCTAssertTrue(f.links.linkCalls.isEmpty)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<DeployRecord>()).filter { $0.skillID == f.skill.id }.count, 0)
        XCTAssertEqual(f.counter.value, 1)
    }

    func testDeleteLeavesOtherSkillsStaleLedgerRowsAlone() throws {
        let f = try fixture(); let other = Skill(name: "Other", directoryName: "other")
        f.context.insert(other); f.context.insert(ScenarioAssignment(skillID: other.id, platform: .claudeCode))
        f.context.insert(SkillProjectAssignment(
            skillID: other.id, projectID: f.project.id, platform: .cursor))
        try f.context.save()
        XCTAssertTrue(delete(f)); XCTAssertEqual(try f.context.fetch(FetchDescriptor<ScenarioAssignment>()).count, 1)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<SkillProjectAssignment>()).count, 1)
        XCTAssertTrue(f.cursor.removeProjectPaths.isEmpty); XCTAssertTrue(f.links.unlinkCalls.isEmpty)
        XCTAssertEqual(f.counter.value, 1)
    }

    func testDeleteLeavesOwnCursorArtifactAlone() throws {
        let f = try fixture(); f.context.insert(ScenarioAssignment(skillID: f.skill.id, platform: .cursor)); try f.context.save()
        XCTAssertTrue(delete(f)); XCTAssertTrue(f.cursor.removeProjectPaths.isEmpty)
        XCTAssertEqual(try f.context.fetch(FetchDescriptor<ScenarioAssignment>()).count, 0)
        XCTAssertEqual(f.counter.value, 1)
    }

    func testDeleteRemovesOwnedSymlinkExactlyOnce() throws {
        let f = try fixture(); let path = f.links.path(f.skill, .claudeCode, f.project.path)
        f.links.linkedPaths.insert(path); try f.state.upsert(record(f, path: path, platform: .claudeCode))
        f.context.insert(SkillProjectAssignment(skillID: f.skill.id, projectID: f.project.id,
                                                platform: .claudeCode)); try f.context.save()
        XCTAssertTrue(delete(f)); XCTAssertEqual(f.links.unlinkCalls.count, 1)
        XCTAssertEqual(f.links.unlinkCalls.first?.1, f.project.path); XCTAssertEqual(f.counter.value, 1)
    }

    private func quarantinedFixture() throws -> Fixture {
        let f = try fixture(); var calls = 0
        _ = delete(f, persist: { context in calls += 1; if calls == 2 { throw DeletionTestError() }; try context.save() })
        return f
    }

    private func record(_ f: Fixture, path: String, platform: PlatformTarget) -> DeployStateRecord {
        DeployStateRecord(slug: f.skill.directoryName, platform: platform.rawValue, scope: "project",
                          projectIdentityKey: nil, artifactPath: path, recordedAt: "2026-01-01T00:00:00Z")
    }

    func testDeleteRefusedAtTheDirectoryKeepsTheDraft() throws {
        // The sheet was answered before the confirmation, but a retained entry can turn dirty while the
        // confirmation is up (a sync pull moved the file): a delete refused at the directory retains the skill
        // WITH its draft — the discard belongs after the files are provably gone (PLAN-33 batch Layer-2).
        let f = try fixture(); try seedAllState(f)
        XCTAssertEqual(f.library.editorBody(for: f.skill), "body")
        f.library.noteEditorChanged(f.skill, body: "edited")
        f.store.deleteFailures.insert("alpha")
        XCTAssertFalse(delete(f))
        XCTAssertNotNil(try f.context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertTrue(f.library.hasUnsavedChanges(for: f.skill))
        XCTAssertEqual(f.library.drafts[f.skill.directoryName]?.body, "edited")
    }
}
