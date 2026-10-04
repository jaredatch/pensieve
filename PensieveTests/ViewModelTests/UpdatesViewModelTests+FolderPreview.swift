import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testFolderPreviewMatchesActualApplyAndDoesNotMutateStore() throws {
        let fixture = try prepareRealPinnedUpdate()
        let local = fixture.storeRoot + "/skills/vendor"
        let upstream = fixture.repository + "/skills/vendor"
        try fileService.writeFile(at: local + "/removed.txt", content: "old\n")
        try fileService.writeFile(at: local + "/.git/config", content: "local git\n")
        try fileService.writeFile(at: local + "/nested/changed.txt", content: "keep\nold\n")
        try fileService.writeFile(at: upstream + "/nested/changed.txt", content: "keep\nnew\nextra\n")
        try fileService.writeFile(at: upstream + "/added.txt", content: "new file\n")
        for side in [local, upstream] { try fileService.writeFile(at: side + "/same.txt", content: "same\n") }
        fixture.skill.upstreamCommit = try commit(fixture.repository, message: "whole folder update")
        fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
        try context.save()
        let before = try fileService.readData(at: local + "/SKILL.md")
        let update = try PinnedSkillUpdate(skill: fixture.skill)
        let preview = try fixture.service.previewUpdate(update)
        XCTAssertEqual(preview.files.map(\.path), [".git/config", "SKILL.md", "added.txt", "nested/changed.txt", "removed.txt"])
        XCTAssertEqual(preview.files.map(\.kind), [.removed, .modified, .added, .modified, .removed])
        let changed = try XCTUnwrap(preview.files.first(where: { $0.path == "nested/changed.txt" }))
        XCTAssertEqual(changed.linesAdded, 2)
        XCTAssertEqual(changed.linesRemoved, 1)
        XCTAssertEqual(try fileService.readData(at: local + "/SKILL.md"), before)
        XCTAssertTrue(fileService.fileExists(at: local + "/removed.txt"))
        XCTAssertTrue(fixture.skill.updateAvailable)
        XCTAssertFalse(preview.isIncomplete)
        try fixture.service.applyUpdate(update, allowLocalOverwrite: true, context: context)
        XCTAssertFalse(fileService.directoryExists(at: local + "/.git"))
        XCTAssertFalse(fileService.fileExists(at: local + "/removed.txt"))
        for file in preview.files where file.kind != .removed {
            XCTAssertEqual(try fileService.readData(at: local + "/" + file.path),
                           try fileService.readData(at: upstream + "/" + file.path))
        }
    }

    func testOversizedSkillMarkdownPreviewSkipsDiscoveryWholeFileRead() throws {
        let fixture = try prepareRealPinnedUpdate()
        let huge = "---\nname: Huge\ndescription: Huge skill\n---\n" + String(repeating: "a", count: 2 * 1_024 * 1_024)
        try fileService.writeFile(at: fixture.repository + "/skills/vendor/SKILL.md", content: huge)
        fixture.skill.upstreamCommit = try commit(fixture.repository, message: "oversized SKILL.md")
        fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
        let spy = ImportBoundedReadSpy()
        let service = makePreviewService(fixture: fixture, spy: spy)
        let preview = try service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))
        XCTAssertEqual(preview.files.map(\.path), ["SKILL.md"])
        XCTAssertEqual(preview.files.first?.content, .tooLarge)
        XCTAssertEqual(preview.bytesRead, 0, "different sizes establish oversized inequality")
        XCTAssertTrue(spy.textReads.isEmpty, "preview admission must not parse SKILL.md through an unbounded read")
    }

    func testPreviewAndDiffRunOffMainThreadThroughExistingWorker() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let spy = ImportBoundedReadSpy()
        let service = makePreviewService(fixture: fixture, spy: spy)
        let operations = UpdatesViewModel.DefaultOperations(
            updateCheckService: UpdateCheckService(fileService: fileService, contentHasher: service,
                                                   scratchRoot: tempDir + "/check-scratch", storeRoot: fixture.storeRoot),
            skillInstallService: service
        )
        let row = try UpdatesViewModel.makeRow(skill: fixture.skill, driftedLocally: false)
        let model = makeModel(rows: [row], diff: operations.diffOperation)
        await model.loadAndReport(context: context)
        model.viewChanges(for: row, context: context)
        await TestWait.until(failureMessage: "preview did not finish") { model.diffLoadingSkillID == nil }
        XCTAssertNotNil(model.presentedDiff)
        XCTAssertEqual(spy.comparisonThreads, [false])
    }

    func testPreviewRefusesBrokenUpstreamFrontmatterBeforeApply() throws {
        let fixture = try prepareRealPinnedUpdate()
        let local = fixture.storeRoot + "/skills/vendor/SKILL.md"
        let before = try fileService.readData(at: local)
        for body in ["---\nname: Vendor\ndescription: ''\n---\nbody\n",
                     "---\nname: [broken\n---\nbody\n",
                     "---\nname: Vendor\ndescription: ''\n---\n" + String(repeating: "a", count: 2 * 1_024 * 1_024)] {
            try fileService.writeFile(at: fixture.repository + "/skills/vendor/SKILL.md", content: body)
            fixture.skill.upstreamCommit = try commit(fixture.repository, message: "invalid frontmatter")
            fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
            XCTAssertThrowsError(try fixture.service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) { error in
                guard case SkillInstallError.unavailableCandidate = error else {
                    return XCTFail("Expected the same admission refusal as apply: \(error)")
                }
            }
            XCTAssertEqual(try fileService.readData(at: local), before)
        }
    }

    func testPreviewErrorsNameRelativePathsAndRemapUpstreamRoot() throws {
        let fixture = try prepareRealPinnedUpdate()
        for upstreamSide in [false, true] {
            for relative in ["", "nested/file"] {
                let spy = ImportBoundedReadSpy()
                spy.comparisonFailure = { local, upstream in
                    let directory = upstreamSide ? upstream : local
                    let path = relative.isEmpty ? directory : directory + "/" + relative
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [
                        NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "open(\(path)): No such file or directory"
                    ])
                }
                let service = makePreviewService(fixture: fixture, spy: spy)
                XCTAssertThrowsError(try service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) { error in
                    XCTAssertFalse(error.localizedDescription.contains(fixture.storeRoot))
                    XCTAssertFalse(error.localizedDescription.contains("preview-scratch"))
                    XCTAssertFalse(error.localizedDescription.contains("open("))
                    XCTAssertTrue(error.localizedDescription.contains(relative.isEmpty ? "." : relative))
                    if upstreamSide {
                        guard case SkillInstallError.unavailableCandidate = error else {
                            return XCTFail("The upstream root must be remapped too: \(error)")
                        }
                    }
                }
            }
        }
    }

    private func makePreviewService(fixture: RealFixture, spy: ImportBoundedReadSpy) -> SkillInstallService {
        SkillInstallService(gitService: GitService(fileService: fileService), credentialStore: InMemoryCredentialStore(),
                            fileService: spy, scratchRoot: tempDir + "/preview-scratch", storeRoot: fixture.storeRoot,
                            lockPath: tempDir + "/sync.lock",
                            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) })
    }
}
