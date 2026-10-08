import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testCrashWindowsConvergeThroughRebuild() throws {
        let repository = try makeVendorFixture(named: "Crash Fixture")
        let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first)

        try assertInstallCrashAfterFilesConverges(candidate: candidate, source: fetched)
        try assertInstallCrashAfterManifestConverges(candidate: candidate, source: fetched)
        try assertAdoptCrashAfterManifestConverges(candidate: candidate, source: fetched)
        try assertUpdateCrashAfterFilesConverges(
            repository: repository,
            candidate: candidate,
            source: fetched
        )
    }

    @MainActor
    func testUpdateWithUnreadableManifestLeavesCanonicalFilesUntouched() throws {
        let repository = try makeVendorFixture()
        let source = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(source.candidates.first)
        let root = tempDir + "/unreadable-update-store"
        let context = try makeInstallContext()
        let installer = makeInstallService(root: root)
        _ = try installer.install(candidate: candidate, from: source, context: context)
        let skillPath = root + "/skills/vendor/SKILL.md"
        let before = try fileService.readData(at: skillPath)
        try fileService.writeFile(
            at: root + "/manifest/skills/vendor.yaml",
            content: "slug: [not-a-scalar]\n"
        )
        try fileService.writeFile(
            at: repository + "/skills/vendor/SKILL.md",
            content: "---\nname: Vendor\ndescription: Binary-safe fixture\n---\nnew upstream\n"
        )
        try commit(repository, message: "upstream changes")
        let updatedSource = try service.fetch(repo: repository, ref: nil, credential: nil)
        let updatedCandidate = try XCTUnwrap(updatedSource.candidates.first)

        XCTAssertThrowsError(
            try installer.update(
                existingSlug: "vendor",
                candidate: updatedCandidate,
                from: updatedSource,
                context: context
            )
        )
        XCTAssertEqual(try fileService.readData(at: skillPath), before)
    }

    @MainActor
    private func assertInstallCrashAfterFilesConverges(
        candidate: SkillCandidate,
        source: SkillFetchResult
    ) throws {
        let root = tempDir + "/crash-install-files"
        let durableManifest = ManifestService(fileService: fileService)
        let crashing = CrashManifest(
            wrapped: durableManifest,
            failurePoint: .beforeUpsert
        )
        let context = try makeInstallContext()

        XCTAssertThrowsError(
            try makeInstallService(root: root, manifest: crashing)
                .install(candidate: candidate, from: source, context: context)
        )
        XCTAssertTrue(fileService.fileExists(at: root + "/skills/vendor/SKILL.md"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)

        let rebuiltContext = try makeInstallContext()
        let rebuild = StoreRebuildService(
            fileService: fileService,
            manifestService: durableManifest
        )
        let migration = StoreMigrationService(
            fileService: fileService,
            manifestService: durableManifest,
            skillStore: SkillStore(fileService: fileService, baseDir: root + "/skills", storeRoot: root)
        )
        let outcome = LaunchReconciler(
            rebuildService: rebuild,
            migrationService: migration,
            fileService: fileService,
            manifestService: durableManifest,
            root: root,
            lockPath: root + "-sync.lock",
            git: TestPaths.git
        ).reconcileOnLaunch(context: rebuiltContext, alreadyMigrated: true)
        let rebuilt = try XCTUnwrap(try rebuiltContext.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(outcome.rebuild.skillsInserted, 1)
        XCTAssertNil(rebuilt.installedOrigin)
    }

    @MainActor
    private func assertInstallCrashAfterManifestConverges(
        candidate: SkillCandidate,
        source: SkillFetchResult
    ) throws {
        let root = tempDir + "/crash-install-manifest"
        let durableManifest = ManifestService(fileService: fileService)
        let crashing = CrashManifest(
            wrapped: durableManifest,
            failurePoint: .afterUpsert
        )
        let context = try makeInstallContext()

        XCTAssertThrowsError(
            try makeInstallService(root: root, manifest: crashing)
                .install(candidate: candidate, from: source, context: context)
        )
        XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)

        let rebuiltContext = try makeInstallContext()
        _ = StoreRebuildService(
            fileService: fileService,
            manifestService: durableManifest
        ).rebuild(fromRoot: root, context: rebuiltContext)
        let rebuilt = try XCTUnwrap(try rebuiltContext.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(rebuilt.installedOrigin?.installedCommit, source.headCommit)
        XCTAssertEqual(rebuilt.installedOrigin?.installedTree, candidate.treeHash)
    }

    @MainActor
    private func assertAdoptCrashAfterManifestConverges(
        candidate: SkillCandidate,
        source: SkillFetchResult
    ) throws {
        let root = tempDir + "/crash-adopt"
        let durableManifest = ManifestService(fileService: fileService)
        let context = try makeInstallContext()
        let good = makeInstallService(root: root, manifest: durableManifest)
        _ = try good.install(
            candidate: candidate,
            renamedTo: "adopt-crash",
            from: source,
            context: context
        )
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        row.installedOrigin = nil
        try durableManifest.upsertSkillOverlay(
            SkillOverlay(
                slug: "adopt-crash",
                createdAt: row.createdAt,
                scope: .user,
                tags: [],
                cursor: nil,
                agents: [],
                origin: .authored
            ),
            toRoot: root
        )
        let skillPath = root + "/skills/adopt-crash/SKILL.md"
        let before = try fileService.readData(at: skillPath)
        let crashing = CrashManifest(
            wrapped: durableManifest,
            failurePoint: .afterUpsert
        )

        XCTAssertThrowsError(
            try makeInstallService(root: root, manifest: crashing)
                .adopt(
                    existingSlug: "adopt-crash",
                    candidate: candidate,
                    from: source,
                    context: context
                )
        )
        XCTAssertNil(row.installedOrigin)
        XCTAssertEqual(try fileService.readData(at: skillPath), before)

        let rebuiltContext = try makeInstallContext()
        _ = StoreRebuildService(
            fileService: fileService,
            manifestService: durableManifest
        ).rebuild(fromRoot: root, context: rebuiltContext)
        let rebuilt = try XCTUnwrap(try rebuiltContext.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(rebuilt.installedOrigin?.installedCommit, source.headCommit)
    }

    @MainActor
    private func assertUpdateCrashAfterFilesConverges(
        repository: String,
        candidate: SkillCandidate,
        source: SkillFetchResult
    ) throws {
        let root = tempDir + "/crash-update"
        let durableManifest = ManifestService(fileService: fileService)
        let originalContext = try makeInstallContext()
        let good = makeInstallService(root: root, manifest: durableManifest)
        _ = try good.install(
            candidate: candidate,
            from: source,
            context: originalContext
        )
        let afterManifestRoot = root + "-after-manifest"
        let afterManifestContext = try makeInstallContext()
        _ = try makeInstallService(root: afterManifestRoot, manifest: durableManifest).install(
            candidate: candidate,
            from: source,
            context: afterManifestContext
        )
        let (updatedSource, updatedCandidate) = try advanceUpstream(repository)
        let crashing = CrashManifest(
            wrapped: durableManifest,
            failurePoint: .beforeUpsert
        )

        XCTAssertThrowsError(
            try makeInstallService(root: root, manifest: crashing)
                .update(
                    existingSlug: "vendor",
                    candidate: updatedCandidate,
                    from: updatedSource,
                    context: originalContext
                )
        )
        XCTAssertTrue(
            try fileService.readFile(at: root + "/skills/vendor/SKILL.md")
                .contains("updated body")
        )

        try assertStaleUpdateReapplies(
            root: root,
            manifest: durableManifest,
            installer: good,
            previousSource: source,
            updatedSource: updatedSource,
            updatedCandidate: updatedCandidate
        )
        try assertUpdateCrashAfterManifestConverges(
            root: afterManifestRoot,
            manifest: durableManifest,
            context: afterManifestContext,
            updatedSource: updatedSource,
            updatedCandidate: updatedCandidate
        )
    }

    private func advanceUpstream(
        _ repository: String
    ) throws -> (SkillFetchResult, SkillCandidate) {
        try writeSkill(
            "skills/vendor",
            name: "Vendor",
            description: "Binary-safe fixture",
            in: repository
        )
        try fileService.writeFile(
            at: repository + "/skills/vendor/SKILL.md",
            content: "---\nname: Vendor\ndescription: Binary-safe fixture\n---\nupdated body\n"
        )
        try commit(repository, message: "upstream update")
        let source = try service.fetch(repo: repository, ref: nil, credential: nil)
        return (source, try XCTUnwrap(source.candidates.first))
    }

    @MainActor
    private func assertUpdateCrashAfterManifestConverges(
        root: String,
        manifest: ManifestService,
        context: ModelContext,
        updatedSource: SkillFetchResult,
        updatedCandidate: SkillCandidate
    ) throws {
        let staleRow = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        let previousCommit = try XCTUnwrap(staleRow.installedOrigin?.installedCommit)
        let crashing = CrashManifest(wrapped: manifest, failurePoint: .afterUpsert)

        XCTAssertThrowsError(
            try makeInstallService(root: root, manifest: crashing).update(
                existingSlug: "vendor",
                candidate: updatedCandidate,
                from: updatedSource,
                context: context
            )
        )
        XCTAssertEqual(staleRow.installedOrigin?.installedCommit, previousCommit)

        let rebuiltContext = try makeInstallContext()
        _ = StoreRebuildService(
            fileService: fileService,
            manifestService: manifest
        ).rebuild(fromRoot: root, context: rebuiltContext)
        let rebuilt = try XCTUnwrap(try rebuiltContext.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(rebuilt.installedOrigin?.installedCommit, updatedSource.headCommit)
        XCTAssertEqual(rebuilt.installedOrigin?.installedTree, updatedCandidate.treeHash)
    }

    @MainActor
    private func assertStaleUpdateReapplies(
        root: String,
        manifest: ManifestService,
        installer: SkillInstallService,
        previousSource: SkillFetchResult,
        updatedSource: SkillFetchResult,
        updatedCandidate: SkillCandidate
    ) throws {
        let rebuiltContext = try makeInstallContext()
        _ = StoreRebuildService(
            fileService: fileService,
            manifestService: manifest
        ).rebuild(fromRoot: root, context: rebuiltContext)
        let stale = try XCTUnwrap(try rebuiltContext.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(stale.installedOrigin?.installedCommit, previousSource.headCommit)
        try installer.update(
            existingSlug: "vendor",
            candidate: updatedCandidate,
            from: updatedSource,
            context: rebuiltContext
        )
        XCTAssertEqual(stale.installedOrigin?.installedCommit, updatedSource.headCommit)
        XCTAssertEqual(stale.installedOrigin?.installedTree, updatedCandidate.treeHash)
    }

    func testVendorTempLivesOutsideStoreRoot() throws {
        let source = tempDir + "/vendor-temp-source"
        try fileService.writeFile(at: source + "/nested/payload.txt", content: "payload")
        let root = tempDir + "/vendor-temp-store"
        try fileService.createDirectory(at: root + "/skills")
        let recording = RecordingVendorFileService(wrapped: fileService)
        let installer = makeInstallService(root: root, using: recording)

        try installer.vendor(
            sourceDirectory: source,
            to: root + "/skills/vendor",
            excludingTopLevelGitMetadata: false
        )

        XCTAssertFalse(recording.pathsCreatedBeforeSwap.isEmpty)
        XCTAssertTrue(
            recording.pathsCreatedBeforeSwap.allSatisfy {
                $0 != root && !$0.hasPrefix(root + "/")
            },
            "vendor build paths must remain outside the synced store: "
                + recording.pathsCreatedBeforeSwap.joined(separator: ", ")
        )
        XCTAssertTrue(fileService.fileExists(at: root + "/skills/vendor/nested/payload.txt"))
    }

    func testCopyFileRejectsSymlinkSourceWithoutCreatingDestination() throws {
        let target = tempDir + "/copy-link-target"
        let source = tempDir + "/copy-link-source"
        let destination = tempDir + "/copy-link-destination"
        try fileService.writeFile(at: target, content: "outside")
        try fileService.createSymlink(at: source, pointingTo: target)

        XCTAssertThrowsError(try fileService.copyFile(at: source, to: destination))
        XCTAssertFalse(fileService.fileExists(at: destination))
        XCTAssertFalse(fileService.isSymlink(at: destination))
    }

    func testCopyFilePreservesBytesAndUserExecutableMode() throws {
        let executableSource = tempDir + "/copy-executable-source"
        let executableDestination = tempDir + "/copy-executable-destination"
        let plainSource = tempDir + "/copy-plain-source"
        let plainDestination = tempDir + "/copy-plain-destination"
        let executableBytes = Data([0x00, 0xFF, 0x41])
        let plainBytes = Data([0x80, 0x42, 0x0A])
        try executableBytes.write(to: URL(fileURLWithPath: executableSource))
        try plainBytes.write(to: URL(fileURLWithPath: plainSource))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableSource
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: plainSource
        )

        try fileService.copyFile(at: executableSource, to: executableDestination)
        try fileService.copyFile(at: plainSource, to: plainDestination)

        XCTAssertEqual(try fileService.readData(at: executableDestination), executableBytes)
        XCTAssertEqual(try fileService.readData(at: plainDestination), plainBytes)
        XCTAssertTrue(fileService.isUserExecutableFile(at: executableDestination))
        XCTAssertFalse(fileService.isUserExecutableFile(at: plainDestination))
    }
}
