import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SyncNudgeTests: XCTestCase {
    private var tempDir = ""

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pensieve-sync-nudge-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty { try? FileManager.default.removeItem(atPath: tempDir) }
    }

    func testSkillCreateNudges() throws {
        let fixture = try libraryFixture()
        fixture.library.startWatching()
        fixture.library.createSkill(
            name: "Create", description: "Description", body: "Body", tags: [],
            context: fixture.context
        )
        let slug = try XCTUnwrap(fixture.store.bodies.keys.first)
        fixture.watcher.emit(slug)
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertFalse(fixture.library.externallyModified.contains(slug))
    }

    func testBodySaveNudges() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "body", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.noteEditorChanged(skill, body: "New")
        XCTAssertTrue(fixture.library.saveDraft(skill))
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testMetadataSaveNudges() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "metadata", store: fixture.store, context: fixture.context)
        fixture.library.updateMetadata(skill, tags: ["swift"], scope: .project, context: fixture.context)
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testSkillDeleteNudges() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "delete", store: fixture.store, context: fixture.context)
        XCTAssertTrue(SkillDeletionFlow.delete(
            skill: skill, library: fixture.library,
            platformVM: PlatformViewModel(agentDetection: DeployStubDetection(installed: []),
                                          deployStateStore: .memoryBacked),
            projects: [], context: fixture.context
        ))
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testExternalEditNudges() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "external", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "External"
        )
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, 1)
        XCTAssertTrue(fixture.library.externallyModified.contains(skill.directoryName))
    }

    func testCategoryRuleChangeNudges() throws {
        let context = try makeContext()
        let counter = Counter()
        let store = CategoryStore(notifier: counter.notify)
        let category = try XCTUnwrap(store.create(name: "Rules", context: context))
        let skill = Skill(name: "Skill", skillDescription: "Description", directoryName: "skill")
        context.insert(skill)
        counter.reset()
        store.setSkill(skill, inCategory: category, assigned: true, context: context)
        XCTAssertEqual(counter.value, 1)
    }

    func testProjectRegistrationNudges() throws {
        let context = try makeContext()
        let counter = Counter()
        _ = registerProject(
            Project(name: "App", path: tempDir + "/app"), context: context, notifier: counter.notify
        )
        XCTAssertEqual(counter.value, 1)
    }

    func testCategoryRenameNudges() throws {
        let context = try makeContext()
        let counter = Counter()
        let store = CategoryStore(notifier: counter.notify)
        let category = try XCTUnwrap(store.create(name: "Before", context: context))
        counter.reset()
        store.rename(category, to: "After", context: context)
        XCTAssertEqual(counter.value, 1)
    }

    func testImportCompletionNudges() throws {
        let fixture = try libraryFixture()
        let discovered = DiscoveredSkill(
            name: "Imported", body: "Body", sourcePlatform: "codex",
            sourcePath: "/fixture/imported/SKILL.md", skillDescription: "Description"
        )
        let model = ImportViewModel(
            scanner: FixedImportScanner(skills: [discovered]),
            skillStore: fixture.store,
            notifier: fixture.counter.notify,
            echoRegistrar: { fixture.library.noteAppAuthoredBodies(directoryNames: $0) }
        )
        fixture.library.startWatching()
        model.scan()
        model.importSelected(context: fixture.context)
        fixture.watcher.emit("imported")
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testUpdateApplyNudges() async throws {
        let fixture = try libraryFixture()
        let (skill, secondSkill) = try makeUpdateSkills(fixture: fixture)
        fixture.library.startWatching()
        let row = updateRow(id: skill.id)
        let secondRow = updateRow(id: secondSkill.id, name: secondSkill.name, slug: secondSkill.directoryName)
        let firstWriteFinished = expectation(description: "first body replacement finished")
        let releaseFirst = TestWait.Gate(owner: self)
        let model = UpdatesViewModel(
            rowLoader: { _ in [row, secondRow] },
            applyOperation: { id, _, _, _, registration, _ in
                let target = id == skill.id ? skill : secondSkill
                return try Self.applyBodyWrite(target: target, write: fixture.store.writeBody, registration: registration) {
                    if id == skill.id {
                        firstWriteFinished.fulfill()
                        try releaseFirst.wait()
                    }
                }
            },
            recheckOperation: { _, _ in throw SkillUpdateFlowError.skillNotFound },
            notifier: fixture.counter.notify,
            echoRegistrar: { fixture.library.noteAppAuthoredBodies(directoryNames: $0) },
            bodyWriteRegistration: SyncBodyWriteRegistration(
                begin: {
                    fixture.library.beginAppAuthoredBodyWrite(
                        directoryName: $0, expectedBody: $1
                    )
                },
                end: { fixture.library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) }
            )
        )
        await model.loadAndReport(context: fixture.context)
        let apply = Task { await model.applySelectedAndReport(context: fixture.context) }
        await fulfillment(of: [firstWriteFinished], timeout: 1)
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, 0)
        releaseFirst.open()
        await apply.value
        fixture.watcher.emit(secondSkill.directoryName)
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testHistoryRestoreNudgesExactlyOnce() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "history", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        let restored = SkillSerializer.serialize(
            name: skill.name, description: skill.skillDescription, body: "Restored"
        )
        try restoreSkillHistoryVersion(
            skill: skill, body: restored, store: fixture.store,
            library: fixture.library, notifier: fixture.counter.notify
        )
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, 1)
    }

    func testCompoundProjectRemovalNudgesExactlyOnce() throws {
        let context = try makeContext()
        let counter = Counter()
        let store = CategoryStore(notifier: counter.notify)
        let project = Project(name: "App", path: tempDir + "/app")
        project.identityKey = "github.com/example/app"
        registerProject(project, context: context, notifier: counter.notify)
        let category = try XCTUnwrap(store.create(name: "Rules", context: context))
        store.setProject(project, inCategory: category, member: true, context: context)
        counter.reset()

        _ = removeRegisteredProject(
            project, categoryStore: store, reconciler: ResultReconciler(),
            context: context, notifier: counter.notify
        )
        XCTAssertEqual(counter.value, 1)
    }

    func testCompoundSkillRemovalNudgesExactlyOnce() throws {
        let context = try makeContext()
        let counter = Counter()
        let categoryStore = CategoryStore(notifier: counter.notify)
        let memoryStore = MemorySkillStore()
        let library = SkillLibraryViewModel(
            skillStore: memoryStore, fileService: FileService(),
            fileWatchService: RecordingWatcher(), notifier: counter.notify
        )
        let skill = try insertSkill(slug: "compound", store: memoryStore, context: context)
        let category = try XCTUnwrap(categoryStore.create(name: "Rules", context: context))
        categoryStore.setSkill(skill, inCategory: category, assigned: true, context: context)
        counter.reset()

        XCTAssertTrue(SkillDeletionFlow.delete(
            skill: skill, library: library,
            platformVM: PlatformViewModel(agentDetection: DeployStubDetection(installed: []),
                                          deployStateStore: .memoryBacked),
            projects: [], context: context
        ))
        XCTAssertEqual(counter.value, 1)
    }

    func testReconcileFailedRemovalStillNudgesOnce() throws {
        let context = try makeContext()
        let counter = Counter()
        let store = CategoryStore(notifier: counter.notify)
        let project = Project(name: "App", path: tempDir + "/app")
        project.identityKey = "github.com/example/app"
        registerProject(project, context: context, notifier: counter.notify)
        let category = try XCTUnwrap(store.create(name: "Rules", context: context))
        store.setProject(project, inCategory: category, member: true, context: context)
        counter.reset()

        let result = removeRegisteredProject(
            project, categoryStore: store, reconciler: ResultReconciler(fails: true),
            context: context, notifier: counter.notify
        )
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Project>()).count, 1)
        XCTAssertFalse(category.projectKeys.contains("github.com/example/app"), "the synced rule mutated before deploy failed")
    }

    func testAppAuthoredSaveDoesNotDoubleFire() throws {
        let fixture = try libraryFixture()
        let skill = try insertSkill(slug: "echo", store: fixture.store, context: fixture.context)
        _ = fixture.library.editorBody(for: skill)
        fixture.library.startWatching()
        fixture.library.noteEditorChanged(skill, body: "New")
        XCTAssertTrue(fixture.library.saveDraft(skill))
        fixture.watcher.emit(skill.directoryName)
        XCTAssertEqual(fixture.counter.value, 1)
    }
}

extension SyncNudgeTests {
    func libraryFixture() throws -> LibraryFixture {
        let counter = Counter()
        let store = MemorySkillStore()
        let watcher = RecordingWatcher()
        let context = try makeContext()
        let library = SkillLibraryViewModel(
            skillStore: store,
            fileService: FileService(),
            fileWatchService: watcher,
            notifier: counter.notify
        )
        return LibraryFixture(library: library, store: store, watcher: watcher,
                              context: context, counter: counter)
    }

    func insertSkill(slug: String, store: MemorySkillStore, context: ModelContext) throws -> Skill {
        store.bodies[slug] = SkillSerializer.serialize(name: slug, description: "Description", body: "Old")
        let skill = Skill(name: slug, skillDescription: "Description", directoryName: slug)
        context.insert(skill)
        try context.save()
        return skill
    }

    private func makeContext() throws -> ModelContext {
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func updateRow(id: UUID, name: String = "Updated", slug: String = "updated") -> UpdatesRow {
        UpdatesRow(
            id: id, skillName: name, slug: slug,
            installedCommit: "1111111",
            updateDate: Date(timeIntervalSince1970: 2), upstreamCommit: "2222222",
            upstreamTree: "tree", repositoryDisplay: "example/repo",
            repositoryPath: "skills/updated", driftedLocally: false, compareURL: nil
        )
    }

    private func makeUpdateSkills(fixture: LibraryFixture) throws -> (Skill, Skill) {
        let first = Skill(name: "Updated", skillDescription: "Description", directoryName: "updated")
        let second = Skill(
            name: "Updated Again", skillDescription: "Description", directoryName: "updated-again"
        )
        for (skill, origin) in [(first, "origin"), (second, "origin-2")] {
            skill.installedOriginData = Data(origin.utf8)
            fixture.context.insert(skill)
            fixture.store.bodies[skill.directoryName] = SkillSerializer.serialize(
                name: skill.name, description: skill.skillDescription, body: "Old"
            )
            _ = fixture.library.editorBody(for: skill)
        }
        try fixture.context.save()
        return (first, second)
    }
}

struct LibraryFixture {
    let library: SkillLibraryViewModel
    let store: MemorySkillStore
    let watcher: RecordingWatcher
    let context: ModelContext
    let counter: Counter
}

final class Counter {
    private(set) var value = 0
    lazy var notify: SyncStateNotifying = { [weak self] in self?.value += 1 }
    func reset() { value = 0 }
}

final class MemorySkillStore: SkillStoreProtocol {
    var bodies: [String: String] = [:]

    func createSkill(name: String, description: String, body: String) throws -> String {
        let slug = SkillStore.slugify(name)
        bodies[slug] = SkillSerializer.serialize(name: name, description: description, body: body)
        return slug
    }

    func readBody(directoryName: String) throws -> String { bodies[directoryName] ?? "" }

    func rewriteSkill(directoryName: String, body: String, preserving parsed: ParsedSkill,
                      fallbackName: String, fallbackDescription: String) throws -> SkillRewriteResult {
        bodies[directoryName] = SkillSerializer.rewrite(
            body: body,
            preserving: parsed,
            fallbackName: fallbackName,
            fallbackDescription: fallbackDescription
        ).content
        return SkillRewriteResult(content: bodies[directoryName] ?? body, didChange: true)
    }

    func writeBody(directoryName: String, body: String) throws { bodies[directoryName] = body }
    func deleteSkill(directoryName: String) throws { bodies[directoryName] = nil }
    func listSkills() throws -> [String] { Array(bodies.keys) }
}

final class RecordingWatcher: FileWatchServiceProtocol {
    var onChange: (String) -> Void = { _ in }
    func start() -> Bool { true }
    func stop() {}
    func emit(_ slug: String) { onChange(slug) }
}

private struct FixedImportScanner: ImportScannerProtocol {
    let skills: [DiscoveredSkill]
    func scan() -> [DiscoveredSkill] { skills }
    func scanFolder(_ path: String) -> [DiscoveredSkill] { [] }
    func isInsideStore(_ path: String) -> Bool { false }
}

private struct ResultReconciler: CategoryReconcilerProtocol {
    var fails = false

    func reconcile(context: ModelContext) -> BatchResult {
        guard fails else { return BatchResult() }
        return BatchResult(outcomes: [BatchPairOutcome(
            skillID: UUID(), skillName: "fixture", platform: .codex, error: "deploy failed"
        )])
    }
}
