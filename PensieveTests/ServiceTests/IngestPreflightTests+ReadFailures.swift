import SQLite3
import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testFailedLibraryReadsStopPushAndRetryBeforeSnapshot() async throws {
        for fault in LibraryReadFault.allCases { try await assertFailedLibraryRead(fault) }
    }

    private func assertReadFailure(_ cycle: SyncCycleResult, fault: LibraryReadFault, attempt: Int) {
            guard case .failed(let message) = cycle else { return XCTFail("A failed read must stop sync") }
            XCTAssertTrue(message.hasPrefix("Rebuilding the local store failed: "), "\(fault), attempt \(attempt)")
            let cause = fault == .skills ? "Couldn't read local skills" : fault == .intents
                ? "Couldn't read local deploy intents" : "Couldn't list the skills directory"
            XCTAssertTrue(message.contains(cause), message)
    }

    private func assertFailedLibraryRead(_ fault: LibraryReadFault) async throws {
        let fixture = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/read-\(fault)")
        }
        let store = fixture.base + "/library.store"
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(url: URL(fileURLWithPath: store)))
        try NativeTestWork.run(container: container) { context in
            _ = StoreRebuildService().rebuild(fromRoot: fixture.app, context: context)
            context.insert(MachineDeployIntent(machineID: InertMachineIdentity.value,
                skillSlug: "item", platformRaw: "codex"))
            try context.save()
            try fixture.manifest.write(fixture.manifest.snapshot(from: context), toRoot: fixture.peer)
            _ = try fixture.git.stageAllAndCommit(at: fixture.peer, message: "seed intent")
            try fixture.git.push(at: fixture.peer, credential: nil)
            _ = try fixture.git.fastForwardOnly(at: fixture.app, credential: nil)
            try fixture.files.deleteDirectory(at: fixture.peer + "/skills/item")
            try fixture.files.writeFile(at: fixture.peer + "/skills/new/SKILL.md",
                content: "---\nname: New\ndescription: New\n---\nnew body\n")
            try fixture.changePeer()
        }
        try fixture.files.writeFile(at: fixture.app + "/skills/item/local.txt", content: "local change")
        let head = GitHeadStamp().read(root: fixture.app)
        let remote = try NativeTestWork.run { try fixture.remoteHead() }
        let rebuild = LibraryReadFaultRebuild(fault: fault, store: store)
        let coordinator = await Task.detached { SyncCoordinator(modelContainer: container) }.value
        await coordinator.configure(engine: fixture.engine(rebuild: rebuild), git: fixture.git,
            credentials: IngestEmptyCredentials(), rebuildService: rebuild, root: fixture.app,
            audit: IngestNullAudit(), machine: (identity: InertMachineIdentity(), stateService: InertMachineStateService()))
        await coordinator.seedLastIngestedHeadStamp(head)
        for attempt in 0..<2 {
            let cycle = await coordinator.runCycle()
            assertReadFailure(cycle, fault: fault, attempt: attempt)
            XCTAssertTrue(StoreIngestState.shared(for: container).needsRebuild)
            XCTAssertEqual(try NativeTestWork.run { try fixture.remoteHead() }, remote, "failed reads must not push")
            XCTAssertEqual(try fixture.manifest.read(fromRoot: fixture.app).categories.map(\.name).sorted(),
                           ["Added", "Kept"])
        }
        XCTAssertTrue(rebuild.failedResults.allSatisfy(\.ingestIncomplete))
        XCTAssertEqual(rebuild.failedResults.count, 2)
        for result in rebuild.failedResults {
            XCTAssertEqual(result.skillReadFailed, fault == .skills)
            XCTAssertEqual(result.deployIntentReadFailed, fault == .intents)
            XCTAssertEqual(result.skillListFailed, fault == .listing)
            XCTAssertFalse(result.saveFailed, "the read signal must be independent of a save failure")
        }
        rebuild.fault = nil
        guard case .synced = await coordinator.runCycle() else { return XCTFail("read recovery did not sync") }
        try NativeTestWork.run { try fixture.assertRemoteCategories() }
        let rows = ModelContext(container)
        XCTAssertEqual(try rows.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["new"])
        XCTAssertEqual(try rows.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }
}

private enum LibraryReadFault: CaseIterable { case skills, intents, listing }

/// The real rebuild reads a temporary SQLite store with one renamed table, or a FileService
/// whose skill-directory listing refuses. It supplies no synthetic rebuild result.
private final class LibraryReadFaultRebuild: StoreRebuildServiceProtocol {
    var fault: LibraryReadFault?
    let store: String
    private(set) var failedResults: [RebuildResult] = []
    init(fault: LibraryReadFault, store: String) { self.fault = fault; self.store = store }
    func rebuild(fromRoot root: String, context: ModelContext) -> RebuildResult {
        guard let fault, (try? ManifestService().read(fromRoot: root).categories.contains { $0.name == "Added" }) == true else {
            return StoreRebuildService().rebuild(fromRoot: root, context: context)
        }
        let table = fault == .skills ? "ZSKILL" : "ZMACHINEDEPLOYINTENT"
        if fault != .listing { rename(table, broken: true) }
        var restored = fault == .listing
        defer { if !restored { rename(table, broken: false) } }
        let files = FaultyFileService(wrapped: FileService(), failListPath: fault == .listing ? root + "/skills" : nil)
        let result = StoreRebuildService(fileService: files, save: { context in
            // Only the read fails. Restore the real table before the save so a save error
            // cannot accidentally supply the incomplete-ingest signal under test.
            if !restored { self.rename(table, broken: false); restored = true }
            try context.save()
        }).rebuild(fromRoot: root, context: context)
        failedResults.append(result)
        return result
    }
    private func rename(_ table: String, broken: Bool) {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(store, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        guard let database else { return XCTFail("Could not open fixture store") }
        defer { sqlite3_close(database) }
        let from = table + (broken ? "" : "_BROKEN"), to = table + (broken ? "_BROKEN" : "")
        XCTAssertEqual(sqlite3_exec(database, "ALTER TABLE \(from) RENAME TO \(to);", nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(database)))
    }
}
