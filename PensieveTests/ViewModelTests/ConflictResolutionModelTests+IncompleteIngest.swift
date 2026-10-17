import SwiftData
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func testFailedConflictFinishReportsReasonAndRetryPreservesPeerCategories() async throws {
        let base = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString).path
        let fixture = try NativeTestWork.run { try IncompleteIngestFixture(base: base) }
        defer { try? fixture.files.deleteDirectory(at: base) }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let rebuild = IncompleteIngestRebuild()
        let engine = fixture.engine(rebuild: rebuild)
        try NativeTestWork.run(container: container) { context in
            _ = try StoreIngestState.rebuild(using: StoreRebuildService(), root: fixture.app, context: context)
            try fixture.changePeer(conflict: true)
            try fixture.files.writeFile(at: fixture.app + "/skills/item/SKILL.md",
                                        content: "---\nname: Item\ndescription: Item\n---\nthis body\n")
            guard case .conflicted = try engine.sync(root: fixture.app, message: "conflict", credential: nil,
                                                      context: context) else { return XCTFail("no real conflict") }
        }
        let sync = SyncModel(git: fixture.git, root: fixture.app)
        sync.apply(.conflicted(["skills/item/SKILL.md"]))
        let model = ConflictResolutionModel(engine: engine, git: fixture.git, credentials: IngestEmptyCredentials(),
            root: fixture.app, steps: SyncStepModel(), onResolutionStarted: { { sync.apply($0) } })
        // A saved window edit can outlive a failed manifest write. Healthy conflict inspection
        // must publish it before rebuilding from the merged files.
        try NativeTestWork.run(container: container) { context in
            let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            skill.cursorConfig = CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false)
            skill.importedFrom = "cursor"
            try context.save()
        }
        await model.loadAndReport(container: container)
        let groups = try readyGroups(from: model.phase)
        let inspected = try XCTUnwrap(try fixture.manifest.read(fromRoot: fixture.app).skills.first { $0.slug == "item" })
        XCTAssertEqual(inspected.cursor, CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))
        XCTAssertEqual(inspected.origin, .imported(from: "cursor"))
        XCTAssertEqual(groups.flatMap(\.items).map(\.path), ["skills/item/SKILL.md"])
        model.choose("skill:item", .thisMachine)
        rebuild.failWhenAddedCategoryExists = true
        let remoteBefore = try NativeTestWork.run { try fixture.remoteHead() }
        await model.applyAndReport(container: container)
        XCTAssertEqual(model.phase, .error(IncompleteIngestFixture.message))
        XCTAssertTrue(sync.isConflicted, "a failed finish must not report success to the sync model")
        XCTAssertEqual(try NativeTestWork.run { try fixture.remoteHead() }, remoteBefore)
        XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name).sorted(), ["Added", "Kept"])

        rebuild.failWhenAddedCategoryExists = false
        await model.loadAndReport(container: container)
        XCTAssertEqual(model.phase, .empty, "retry inspection finishes the already resolved rebase")
        XCTAssertFalse(sync.isConflicted)
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
        let retried = try XCTUnwrap(try fixture.manifest.read(fromRoot: fixture.app).skills.first { $0.slug == "item" })
        XCTAssertEqual(retried.cursor, CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false))
        XCTAssertEqual(retried.origin, .imported(from: "cursor"))
        try NativeTestWork.run(container: container) { context in
            guard case .synced = try engine.sync(root: fixture.app, message: "ordinary", credential: nil,
                                                 context: context) else { return XCTFail("ordinary sync stayed blocked") }
        }
    }
}
