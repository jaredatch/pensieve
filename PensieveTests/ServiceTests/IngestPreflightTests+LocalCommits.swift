import SwiftData
import XCTest
@testable import Pensieve

extension IngestPreflightTests {
    func testOutsideSkillChangesCommittedOfflineRebuildBeforeEachWriter() async throws {
        for operation in ["sync", "inspect", "resolve"] {
            for writer in ["import", "deploy", "queue"] {
                try await assertLocalCommitWriter(writer, edit: "outside", operation: operation)
            }
        }
    }

    func testEditorSaveCommittedOfflineRebuildsWithoutChangingBody() async throws {
        try await assertLocalCommitWriter("import", edit: "editor")
    }

    func testQueuedManifestChangesCommittedOfflineKeepHeadAdmitted() async throws {
        for operation in ["sync", "inspect", "resolve"] {
            try await assertLocalCommitWriter("import", edit: "manifest", operation: operation)
        }
    }

    func testQueuedCursorSettingsSurviveOutsideCommitRebuildAndConflictFinish() async throws {
        for conflict in [false, true] {
            let f = try NativeTestWork.run { try IncompleteIngestFixture(base: self.tempDir + "/cursor-\(conflict)") }
            let context = try damageContext(f)
            try f.manifest.write(f.manifest.snapshot(from: context), toRoot: f.app)
            let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
            let saves = ManifestSaveModel(manifest: f.manifest, root: f.app, lockPath: f.base + "/sync.lock")
            let cursor = CursorAdapterConfig(globs: ["*.swift"], alwaysApply: false)
            skill.cursorConfig = cursor
            skill.importedFrom = "cursor"
            try context.save()
            saves.submit(.skillMetadata("item", nil, nil, cursor: .some(cursor), origin: .imported(from: "cursor")),
                         context: context) { XCTAssertNil($0) }
            // No suspension: sync gets the lock while the metadata is still queued.
            try NativeTestWork.run(container: context.container) { worker in
                if conflict { try f.changePeer(conflict: true) }
                try f.files.writeFile(at: f.app + "/skills/item/SKILL.md",
                    content: "---\nname: Item\ndescription: Outside description\n---\nthis body\n")
                _ = try f.git.stageAllAndCommit(at: f.app, message: "outside body")
                try f.files.writeFile(at: f.app + "/skills/item/asset.txt", content: "uncommitted outside asset")
                let rebuild = IncompleteIngestRebuild()
                let engine = f.engine(rebuild: rebuild)
                let result = try engine.sync(root: f.app, message: "outside change", credential: nil, context: worker)
                XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild)
                if conflict {
                    guard case .conflicted = result else { return XCTFail("Expected body conflict") }
                    guard case .conflicts(let set) = try engine.inspectConflicts(root: f.app, credential: nil,
                        context: worker) else { return XCTFail("Inspection was refused") }
                    let picks = Dictionary(uniqueKeysWithValues: set.items.map {
                        ($0.path, ResolutionPick(side: .thisMachine, expectedThis: $0.thisMachine,
                            expectedOther: $0.otherMachine, expectedThisMode: $0.thisMode, expectedOtherMode: $0.otherMode))
                    })
                    guard case .synced = try engine.resolveConflicts(root: f.app, picks: picks,
                        credential: nil, context: worker) else { return XCTFail("Conflict finish was refused") }
                } else if case .synced = result {} else { XCTFail("Push was refused") }
                XCTAssertGreaterThan(rebuild.calls, 0, "The outside commit must be ingested")
                let published = f.base + "/published"
                try f.git.clone(remote: f.remote, into: published, credential: nil)
                let overlay = try XCTUnwrap(f.manifest.read(fromRoot: published).skills.first)
                XCTAssertEqual(overlay.cursor, cursor)
                XCTAssertEqual(overlay.origin, .imported(from: "cursor"))
                XCTAssertEqual(try f.files.readFile(at: published + "/skills/item/asset.txt"), "uncommitted outside asset")
            }
            XCTAssertEqual(saves.pendingCount, 1)
            XCTAssertEqual(skill.cursorConfig, cursor)
            await saves.waitUntilIdle()
            XCTAssertTrue(saves.refused.isEmpty)
        }
    }

    func testUnknownPathsAndChangedCycleOutputsDoNotAdvanceAdmission() async throws {
        for operation in ["sync", "inspect"] {
            for edit in ["asset", "unknown", "delete", "rename", "mode", "manifest", "control"] {
                let f = try NativeTestWork.run {
                    try IncompleteIngestFixture(base: self.tempDir + "/shape-\(operation)-\(edit)")
                }
                let context = try damageContext(f)
                try NativeTestWork.run(container: context.container) { worker in
                    try f.git.setRemote("file://" + f.base + "/offline.git", at: f.app)
                    let git = AllowlistedRemoteGit(wrapping: f.git)
                    git.beforeLocalCommit = { root in try self.changeBeforeCommit(edit, root: root, fixture: f) }
                    let engine = SyncEngine(gitService: git, lockPath: f.base + "/sync.lock")
                    let before = GitHeadStamp().read(root: f.app)
                    XCTAssertThrowsError(try {
                        if operation == "sync" {
                            _ = try engine.sync(root: f.app, message: "changed output", credential: nil, context: worker)
                        } else {
                            _ = try engine.inspectConflicts(root: f.app, credential: nil, context: worker)
                        }
                    }())
                    XCTAssertNotEqual(GitHeadStamp().read(root: f.app), before, edit)
                }
                XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild)
                try await runFollowingWriter("import", fixture: f, context: context, expectsRebuild: true)
            }
        }
    }

    private func changeBeforeCommit(_ edit: String, root: String, fixture f: IncompleteIngestFixture) throws {
        let document = root + "/skills/item/SKILL.md"
        switch edit {
        case "asset": try f.files.writeFile(at: root + "/skills/item/new\nasset", content: "asset")
        case "unknown": try f.files.writeFile(at: root + "/outside.txt", content: "outside")
        case "delete": try f.files.deleteFile(at: document)
        case "rename":
            try f.files.writeFile(at: root + "/skills/item/renamed.md", content: f.files.readFile(at: document))
            try f.files.deleteFile(at: document)
        case "mode":
            let path = root + "/.gitattributes"
            try f.files.writeExecutableFile(at: path, content: f.files.readFile(at: path))
        case "manifest":
            var changed = try f.manifest.read(fromRoot: root)
            changed.skills[0].tags = ["outside"]
            try f.manifest.write(changed, toRoot: root)
        default:
            let path = root + "/.gitattributes"
            try f.files.writeFile(at: path, content: f.files.readFile(at: path) + "\n# outside control edit\n")
        }
    }

    private func assertLocalCommitWriter(_ writer: String, edit: String, operation: String = "sync") async throws {
        let f = try NativeTestWork.run {
            try IncompleteIngestFixture(base: self.tempDir + "/local-\(writer)-\(edit)-\(operation)")
        }
        let context = try damageContext(f)
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first)
        let library = queuedLibrary(f, context: context)
        let saves = try XCTUnwrap(library.manifestSaves)
        let expectedName = edit == "editor" ? "Item" : "Changed"
        let body = "---\nname: \(expectedName)\ndescription: Outside description\n---\nchanged body\n"
        if edit == "manifest" {
            let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
            CategoryStore(manifestSaves: saves).rename(category, to: "Renamed", context: context)
            await saves.waitUntilIdle()
            let deploy = intentModel(fixture: f, manifest: f.manifest, saveContext: { try $0.save() })
            try deploy.setRemote(true, machineID: ProjectIntentHarness.remoteID, projectKey: "github.com/owner/project",
                skill: skill, platform: .codex, context: context)
            try f.files.writeFile(at: f.app + "/machines/fixture.yaml", content: "machine state\n")
        } else if edit == "editor" {
            let original = try f.files.readFile(at: f.app + "/skills/item/SKILL.md")
            XCTAssertEqual(library.updateDocument(skill, document: body, original: original), .written)
            try context.save()
        } else {
            try f.files.writeFile(at: f.app + "/skills/item/SKILL.md", content: body)
            try f.files.writeFile(at: f.app + "/skills/item/new\nasset.txt", content: "outside addition\n")
        }
        try commitOffline(f, container: context.container, operation: operation, edit: edit, body: body)
        XCTAssertFalse(StoreIngestState.shared(for: context.container).needsRebuild, "Unseen bytes are not a failed ingest")
        try await runFollowingWriter(writer, fixture: f, context: context, expectsRebuild: edit != "manifest")
        if edit != "manifest" {
            XCTAssertEqual(skill.name, expectedName, "Window identity must reflect the committed outside edit")
            XCTAssertEqual(library.editorBody(for: skill), body)
            XCTAssertEqual(try f.files.readFile(at: f.app + "/skills/item/SKILL.md"), body)
        } else {
            let snapshot = try f.manifest.read(fromRoot: f.app)
            XCTAssertTrue(snapshot.categories.contains { $0.name == "Renamed" })
            XCTAssertEqual(snapshot.deployIntents.count, 1)
        }
    }
    private func commitOffline(_ f: IncompleteIngestFixture, container: ModelContainer,
                               operation: String, edit: String, body: String) throws {
        let before = GitHeadStamp().read(root: f.app)
        try NativeTestWork.run(container: container) { worker in
            // A missing fixture remote fails the actual fetch, after the real local commit.
            try f.git.setRemote("file://" + f.base + "/offline.git", at: f.app)
            let engine = f.engine(rebuild: StoreRebuildService())
            XCTAssertThrowsError(try {
                switch operation {
                case "inspect": _ = try engine.inspectConflicts(root: f.app, credential: nil, context: worker)
                case "resolve": _ = try engine.resolveConflicts(root: f.app, picks: [:], credential: nil, context: worker)
                default: _ = try engine.sync(root: f.app, message: "offline", credential: nil, context: worker)
                }
            }()) { error in
                XCTAssertFalse(error is StoreIngestFailure)
                XCTAssertNotEqual(error as? SyncError, .ingestIncomplete)
            }
            XCTAssertNotEqual(GitHeadStamp().read(root: f.app), before)
            if edit != "manifest" {
                XCTAssertEqual(f.git.show(sha: "HEAD", path: "skills/item/SKILL.md", at: f.app), body)
            }
            if edit == "outside" {
                XCTAssertEqual(f.git.show(sha: "HEAD", path: "skills/item/new\nasset.txt", at: f.app), "outside addition\n")
            }
        }
    }

    private func runFollowingWriter(_ writer: String, fixture f: IncompleteIngestFixture,
                                    context: ModelContext, expectsRebuild: Bool) async throws {
        let skill = try XCTUnwrap(context.fetch(FetchDescriptor<Skill>()).first { $0.directoryName == "item" })
        let manifest = WriterIngestManifest()
        if writer == "queue" {
            let queued = ManifestSaveModel(manifest: manifest, root: f.app, lockPath: f.base + "/sync.lock")
            let category = try XCTUnwrap(context.fetch(FetchDescriptor<Pensieve.Category>()).first { $0.name == "Kept" })
            CategoryStore(manifestSaves: queued).rename(category, to: "Next", context: context)
            await queued.waitUntilIdle()
            XCTAssertNil(queued.categoryNotice)
            XCTAssertGreaterThan(manifest.snapshotsBeforeFirstWrite, 0, "Queue must rebuild before publishing")
        } else if writer == "import" {
            let model = importModel(fixture: f, manifest: manifest)
            _ = model.importSelected(context: context)
            XCTAssertNil(model.error)
        } else {
            let model = intentModel(fixture: f, manifest: manifest, saveContext: { try $0.save() })
            try model.setRemote(true, machineID: ProjectIntentHarness.remoteID, projectKey: "github.com/owner/project",
                skill: skill, platform: .codex, context: context)
        }
        if writer != "queue" {
            XCTAssertEqual(manifest.reads, expectsRebuild ? 1 : 0, "The next writer's ingest read")
        }
        XCTAssertEqual(manifest.writes, 1)
    }

}
