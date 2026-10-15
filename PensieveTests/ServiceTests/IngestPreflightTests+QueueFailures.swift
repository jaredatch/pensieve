import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testQueueRebuildFailuresKeepUnrelatedEditsAndRequireImportOrDeployIngest() async throws {
        for writer in ["import", "deploy"] {
            for failure in ["Skill", "Category", "MachineDeployIntent", "save", "scan"] {
                try await checkQueueFailure(failure, writer: writer)
            }
        }
    }

    private func checkQueueFailure(_ failure: String, writer: String) async throws {
        let f = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/queue-failure-" + writer + failure)
        }
        let context = try damageContext(f)
        let project = try savedProject(f, context: context)
        let recording = RecordingSaveManifest()
        let gate = TestWait.Gate(owner: self)
        defer { gate.open() }
        if failure != "scan" { recording.afterRebuildSnapshot = { try gate.wait() } }
        let files = RebuildReadFileService()
        files.refuseSkillListing = failure == "scan"
        var reports: [String] = []
        let saves = ManifestSaveModel(manifest: recording, root: f.app, lockPath: f.base + "/sync.lock",
            files: files, log: { reports.append($0) })
        let category = try XCTUnwrap(try context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
        CategoryStore(manifestSaves: saves).rename(category, to: "Saved", context: context)
        if failure != "scan" {
            await TestWait.until(failureMessage: "Queue scan must finish before acceptance fails") { gate.waiterCount == 1 }
        }
        // The edit is outside the manifest and is deliberately unsaved when acceptance fails.
        project.name = "Unsaved Project"
        context.processPendingChanges()
        XCTAssertTrue(context.hasChanges, "The unrelated edit must be unsaved when the rebuild fails")
        let readFault = ["save", "scan"].contains(failure) ? nil : try CategoryFetchFault(in: context, entityName: failure)
        let saveFault = failure == "save" ? try ContextSaveFault(in: context) : nil
        defer { readFault?.stop(); saveFault?.stop() }
        gate.open()
        await saves.waitUntilIdle()
        readFault?.stop()
        saveFault?.stop()
        XCTAssertEqual(readFault?.refusedReads ?? saveFault?.refusedSaves ?? files.skillListingRefusals, 1, failure)
        XCTAssertTrue(try XCTUnwrap(reports.last).contains("rebuilding the local store failed"), failure)
        let retainedProject = try XCTUnwrap(try context.fetch(FetchDescriptor<Project>()).first { $0.path == project.path })
        XCTAssertEqual(retainedProject.name, "Unsaved Project", "A failed rebuild must not roll back unrelated window changes")
        XCTAssertTrue(StoreIngestState.shared(for: context.container).needsRebuild, failure)
        // A disk change at the same HEAD proves the following real writer ingests, rather than
        // merely clearing the flag or publishing its stale context.
        var peer = try f.manifest.read(fromRoot: f.app)
        peer.categories.append(CategoryRecord(name: "Peer After Failure", projectKeys: [], skillSlugs: []))
        try f.manifest.write(peer, toRoot: f.app)
        if writer == "import" {
            let model = importModel(fixture: f, manifest: f.manifest)
            _ = model.importSelected(context: context)
            XCTAssertNil(model.error)
        } else {
            let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            let model = intentModel(fixture: f, manifest: f.manifest, saveContext: { try $0.save() })
            try model.setRemote(true, machineID: ProjectIntentHarness.remoteID, projectKey: "github.com/owner/project",
                skill: skill, platform: .codex, context: context)
        }
        XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild)
        XCTAssertTrue(try f.manifest.read(fromRoot: f.app).categories.contains { $0.name == "Peer After Failure" },
            "\(writer) must ingest after the queue's \(failure) failure before writing")
    }

    private func savedProject(_ f: IncompleteIngestFixture, context: ModelContext) throws -> Project {
        let project = Project(name: "Saved Project", path: f.base + "/project")
        context.insert(project)
        try context.save()
        try f.manifest.write(f.manifest.snapshot(from: context), toRoot: f.app)
        return project
    }

    func testLocalProjectDeployWithoutIdentityProceedsThroughAnotherProcessesSyncLock() throws {
        let h = try ProjectFolderCallerHarness(installed: [.codex])
        defer { h.cleanup() }
        try h.files.createDirectory(at: h.project.path)
        h.project.identityKey = nil
        try h.context.save()
        try h.files.createDirectory(at: h.root + "/support")
        let held = try ExternalSyncLockHolder(path: h.root + "/support/intent.lock")
        defer { held.release() }
        let result = try h.model().set(true, skill: h.skill, platform: .codex,
            target: .project(h.project), context: h.context)
        XCTAssertFalse(result.hasFailures)
        XCTAssertTrue(h.files.isSymlink(at: h.artifact(.codex)))
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }
}
