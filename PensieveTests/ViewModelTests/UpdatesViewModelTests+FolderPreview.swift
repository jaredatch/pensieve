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

    func testWholePreviewIncludesAdmissionInTheThirtyTwoMiBReadBound() throws {
        let fixture = try prepareRealPinnedUpdate()
        let data = Data(repeating: 65, count: 1_024 * 1_024)
        for index in 0..<17 {
            for directory in [fixture.repository + "/skills/vendor", fixture.storeRoot + "/skills/vendor"] {
                try fileService.writeData(at: directory + "/file\(index)", data: data)
            }
        }
        fixture.skill.upstreamCommit = try commit(fixture.repository, message: "whole-preview budget")
        fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
        let spy = ImportBoundedReadSpy()
        let preview = try makePreviewService(fixture: fixture, spy: spy).previewUpdate(PinnedSkillUpdate(skill: fixture.skill))
        let actual = spy.prefixReadBytes + spy.comparisonReadBytes
        XCTAssertGreaterThan(spy.prefixReadBytes, 0)
        XCTAssertLessThanOrEqual(actual, 32 * 1_024 * 1_024, "The whole preview, admission included, must obey 32 MiB")
        XCTAssertEqual(preview.bytesRead, actual, "Reported bytes must include the admission read")
        XCTAssertTrue(preview.isIncomplete)
        XCTAssertEqual(preview.unreadFileCount, 2)
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
        XCTAssertEqual(preview.bytesRead, spy.prefixReadBytes, "Different sizes need only the counted admission read")
        XCTAssertTrue(spy.textReads.isEmpty, "preview admission must not parse SKILL.md through an unbounded read")
    }

    func testPreviewAndDiffRunOffMainThreadThroughExistingWorker() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let spy = ImportBoundedReadSpy()
        let service = makePreviewService(fixture: fixture, spy: spy)
        let operations = UpdatesViewModel.DefaultOperations(
            updateCheckService: UpdateCheckService(
                gitService: GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass"),
                credentialStore: InMemoryCredentialStore(),
                fileService: fileService,
                contentHasher: service,
                scratchRoot: tempDir + "/check-scratch",
                storeRoot: fixture.storeRoot
            ),
            skillInstallService: service
        )
        let row = try UpdatesViewModel.makeRow(skill: fixture.skill, driftedLocally: false)
        let review = UpdateReviewOperations(diffOperation: operations.diffOperation,
            recheckOperation: operations.recheckOperation)
        let (_, library) = makeRealReviewOperations(fixture: fixture, service: service)
        let window = ViewChangesViewModel(library: library, operations: review)
        window.open(skillID: row.id, context: context)
        await TestWait.until(failureMessage: "preview did not finish") { window.state != .loading }
        XCTAssertNotNil(window.selectedFile)
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

    func testPreviewReadErrorsRespectDomainsAndHandleWideCodes() throws {
        let fixture = try prepareRealPinnedUpdate()
        let cases: [(NSError, String)] = [
            (NSError(domain: NSCocoaErrorDomain, code: Int(ELOOP)), "could not be read"),
            (CocoaError(.fileReadNoPermission) as NSError, "permission denied"),
            (NSError(domain: NSPOSIXErrorDomain, code: Int.max), "could not be read"),
            (NSError(domain: NSPOSIXErrorDomain, code: Int.min), "could not be read"),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)), "symbolic links")
        ]
        for (failure, reason) in cases {
            let spy = ImportBoundedReadSpy()
            spy.comparisonFailure = { _, upstream in
                throw NSError(domain: failure.domain, code: failure.code,
                              userInfo: [NSFilePathErrorKey: upstream + "/nested/file"])
            }
            let service = makePreviewService(fixture: fixture, spy: spy)
            var message = ""
            XCTAssertThrowsError(try service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) {
                message = $0.localizedDescription
            }
            // Keep the old implementation's readable domain regression before its trapping case.
            guard message.contains(reason) else { return XCTFail("Expected \(reason), got \(message)") }
            XCTAssertTrue(message.contains("nested/file"))
            XCTAssertFalse(message.contains("preview-scratch"))
        }
    }

    func testPreviewChecksInstallabilityBeforeComparison() throws {
        let fixture = try prepareRealPinnedUpdate()
        try fileService.writeFile(at: fixture.repository + "/skills/vendor/SKILL.md",
                                  content: "---\nname: Broken\ndescription: ''\n---\nbody\n")
        fixture.skill.upstreamCommit = try commit(fixture.repository, message: "invalid before comparison")
        fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
        let spy = ImportBoundedReadSpy()
        XCTAssertThrowsError(try makePreviewService(fixture: fixture, spy: spy)
            .previewUpdate(PinnedSkillUpdate(skill: fixture.skill)))
        XCTAssertEqual(spy.comparisonThreads.count, 1, "Both inventories precede frontmatter admission")
        XCTAssertEqual(spy.comparisonReadBytes, 0, "Invalid frontmatter must refuse before any compared content read")
        XCTAssertEqual(spy.readAttempts.count, 1)
    }

    func testPreviewInstallabilityReadsSkillMarkdownOnceWithinBoundPlusOne() throws {
        let fixture = try prepareRealPinnedUpdate()
        let maximum = FileTreeComparisonLimits.updatePreview.maximumFileBytes
        let header = "---\nname: Huge\ndescription: Huge skill\n---\n"
        for size in [maximum, maximum + 1, maximum * 2] {
            try fileService.writeFile(at: fixture.repository + "/skills/vendor/SKILL.md",
                                      content: header + String(repeating: "a", count: size - header.utf8.count))
            fixture.skill.upstreamCommit = try commit(fixture.repository, message: "bounded admission \(size)")
            fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
            let spy = ImportBoundedReadSpy()
            _ = try makePreviewService(fixture: fixture, spy: spy).previewUpdate(PinnedSkillUpdate(skill: fixture.skill))
            XCTAssertEqual(spy.readAttempts.count, 1, "One bounded admission read, including oversized bodies")
            XCTAssertEqual(Array(spy.limits.values), [maximum])
        }
    }

    func testUnsafeUpstreamDirectoryNamesFailingRelativeComponent() throws {
        let fixture = try prepareRealPinnedUpdate()
        for relative in ["skills/vendor", "skills"] {
            try fileService.deleteDirectory(at: fixture.repository + "/" + relative)
            try fileService.createSymlink(at: fixture.repository + "/" + relative, pointingTo: "/etc")
            fixture.skill.upstreamCommit = try commit(fixture.repository, message: "unsafe parent \(relative)")
            XCTAssertThrowsError(try fixture.service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsafe upstream directory: \(relative)"))
                XCTAssertFalse(error.localizedDescription.contains("install-scratch"))
            }
        }
    }

    func testBothInventoriesRefuseLinksBeforeFrontmatterRead() throws {
        let fixture = try prepareRealPinnedUpdate()
        try fileService.writeFile(at: fixture.repository + "/skills/vendor/SKILL.md",
                                  content: "---\nname: Broken\ndescription: ''\n---\nbody\n")
        for upstreamSide in [false, true] {
            let directory = upstreamSide ? fixture.repository + "/skills/vendor" : fixture.storeRoot + "/skills/vendor"
            try fileService.createSymlink(at: directory + "/unsafe", pointingTo: "/etc")
            fixture.skill.upstreamCommit = try commit(fixture.repository, message: "link before frontmatter \(upstreamSide)")
            fixture.skill.upstreamTree = try GitService().treeHash(at: fixture.repository, path: "skills/vendor")
            let spy = ImportBoundedReadSpy()
            XCTAssertThrowsError(try makePreviewService(fixture: fixture, spy: spy)
                .previewUpdate(PinnedSkillUpdate(skill: fixture.skill))) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsafe"), "Tree admission must precede frontmatter: \(error)")
            }
            XCTAssertTrue(spy.readAttempts.isEmpty, "Neither unsafe tree permits a content read")
            try fileService.deleteFile(at: directory + "/unsafe")
        }
    }

    private func makePreviewService(fixture: RealFixture, spy: ImportBoundedReadSpy) -> SkillInstallService {
        SkillInstallService(
            gitService: GitService(fileService: fileService, askpassHelperPath: tempDir + "/askpass"),
            credentialStore: InMemoryCredentialStore(),
            fileService: spy,
            scratchRoot: tempDir + "/preview-scratch",
            storeRoot: fixture.storeRoot,
            lockPath: tempDir + "/sync.lock",
            remoteValidator: { ValidatedInstallRemote(repo: $0, cloneRemote: $0) }
        )
    }
}
