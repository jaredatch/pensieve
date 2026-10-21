import SwiftData
import XCTest
@testable import Pensieve

private typealias InstallCategory = Pensieve.Category

private struct AdoptFixture {
    let installer: SkillInstallService
    let skillFile: String
    let pristine: Data
}

extension SkillInstallServiceTests {
    @MainActor
    func makeInstallContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self,
            DeployRecord.self, InstallCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func makeVendorFixture(named name: String = "Vendor Fixture") throws -> String {
        let repository = try makeRepository(named: name)
        try writeSkill(
            "skills/vendor",
            name: "Vendor",
            description: "Binary-safe fixture",
            in: repository
        )
        let binaryPath = repository + "/skills/vendor/assets/payload.bin"
        try FileManager.default.createDirectory(
            atPath: (binaryPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data([0x00, 0xFF, 0x80, 0x41, 0x0A]).write(to: URL(fileURLWithPath: binaryPath))
        let scriptPath = repository + "/skills/vendor/scripts/run.sh"
        try FileManager.default.createDirectory(
            atPath: (scriptPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho vendored\n".write(
            toFile: scriptPath,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o744],
            ofItemAtPath: scriptPath
        )
        try commit(repository)
        return repository
    }

    func makeInstallService(root: String,
                            using files: FileServiceProtocol? = nil,
                            manifest: ManifestReadWriting? = nil) -> SkillInstallService {
        let selectedFiles = files ?? fileService!
        return SkillInstallService(
            gitService: gitService,
            credentialStore: InMemoryCredentialStore(),
            fileService: selectedFiles,
            scratchRoot: root + "-scratch",
            storeRoot: root,
            manifestService: manifest,
            lockPath: root + "-sync.lock",
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            remoteValidator: fixtureRemoteValidator
        )
    }

    @MainActor
    func testVendorPreservesBytesAndMode() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let root = tempDir + "/store"
            let context = try makeInstallContext()
            let installer = makeInstallService(root: root)
            let source = repository + "/skills/vendor"
            let result = try installer.install(candidate: candidate, from: fetched, context: context)
            XCTAssertEqual(result, .installed(slug: "vendor"))
            let destination = root + "/skills/vendor"
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: destination + "/SKILL.md")),
                try Data(contentsOf: URL(fileURLWithPath: source + "/SKILL.md"))
            )
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: destination + "/assets/payload.bin")),
                try Data(contentsOf: URL(fileURLWithPath: source + "/assets/payload.bin"))
            )
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: destination + "/scripts/run.sh")),
                try Data(contentsOf: URL(fileURLWithPath: source + "/scripts/run.sh"))
            )
            XCTAssertTrue(fileService.isUserExecutableFile(at: destination + "/scripts/run.sh"))
            XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).first?.scope, .user)
            XCTAssertTrue(try context.fetch(FetchDescriptor<DeployRecord>()).isEmpty)
        }
    }

    func testStableHashDeterministicAcrossInstancesEnumerationOrdersAndModeSensitive() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let directory = repository + "/skills/vendor"
            let normal = makeInstallService(root: tempDir + "/hash-normal")
            let reversedFiles = ReverseListingFileService(wrapped: fileService)
            let reversed = makeInstallService(root: tempDir + "/hash-reversed", using: reversedFiles)
            let first = try normal.stableContentHash(at: directory)
            let second = try reversed.stableContentHash(at: directory)
            let third = try makeInstallService(root: tempDir + "/hash-third")
                .stableContentHash(at: directory)
            XCTAssertEqual(first, second)
            XCTAssertEqual(second, third)
            let script = directory + "/scripts/run.sh"
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script)
            XCTAssertNotEqual(try normal.stableContentHash(at: directory), first)
        }
    }

    @MainActor
    func testCollisionDetectionAndRenamePath() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let root = tempDir + "/collision-store"
            let context = try makeInstallContext()
            let installer = makeInstallService(root: root)
            try fileService.writeFile(at: root + "/skills/vendor/keep.txt", content: "untouched")
            let collision = try installer.install(candidate: candidate, from: fetched, context: context)
            XCTAssertEqual(
                collision,
                .collision(existing: SkillCollision(slug: "vendor", hasDirectory: true, hasSwiftDataRow: false))
            )
            XCTAssertEqual(try fileService.readFile(at: root + "/skills/vendor/keep.txt"), "untouched")
            XCTAssertFalse(fileService.directoryExists(at: root + "/manifest"))
            let rowOnly = Skill(name: "Row only", directoryName: "row-only")
            context.insert(rowOnly)
            try context.save()
            let rowCollision = try installer.install(candidate: candidate, renamedTo: "row-only",
                                                     from: fetched, context: context)
            XCTAssertEqual(
                rowCollision,
                .collision(existing: SkillCollision(slug: "row-only", hasDirectory: false, hasSwiftDataRow: true))
            )
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/row-only"))
            let renamed = try installer.install(candidate: candidate, renamedTo: "vendor-two",
                                                from: fetched, context: context)
            XCTAssertEqual(renamed, .installed(slug: "vendor-two"))
            XCTAssertTrue(fileService.fileExists(at: root + "/skills/vendor-two/SKILL.md"))
        }
    }

    @MainActor
    func testCollisionMatchesRowSlugCaseFolded() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let root = tempDir + "/collision-case-store"
            let context = try makeInstallContext()
            let installer = makeInstallService(root: root)
            // A quarantined row keeps its (legacy, mixed-case) slug with nothing on disk; on default APFS
            // "row-only" and "Row-Only" are one entry, so the install must collide on the row alone.
            let rowOnly = Skill(name: "Row only", directoryName: "Row-Only")
            context.insert(rowOnly)
            try context.save()
            let collision = try installer.install(
                candidate: candidate, renamedTo: "row-only", from: fetched, context: context
            )
            XCTAssertEqual(
                collision,
                .collision(existing: SkillCollision(slug: "row-only", hasDirectory: false, hasSwiftDataRow: true))
            )
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/row-only"))
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/Row-Only"))
        }
    }
    @MainActor
    func testAdoptCleanVsLocalDriftWithoutTouchingFiles() throws {
        try NativeTestWork.run { [self] in try assertAdoptCleanVsLocalDriftWithoutTouchingFiles() }
    }

    @MainActor
    private func assertAdoptCleanVsLocalDriftWithoutTouchingFiles() throws {
        let repository = try makeVendorFixture()
        let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(fetched.candidates.first)
        let root = tempDir + "/adopt-store"
        let context = try makeInstallContext()
        let fixture = try prepareAuthoredAdoptFixture(
            root: root, candidate: candidate, source: fetched, context: context)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        row.updateAvailable = true; row.lastCheckedHead = "stale-head"
        row.upstreamCommit = "stale-commit"; row.checkError = "stale error"
        try context.save()
        XCTAssertEqual(
            try fixture.installer.adopt(
                existingSlug: "adopted",
                candidate: candidate,
                from: fetched,
                context: context
            ),
            .clean
        )
        XCTAssertFalse(row.updateAvailable); XCTAssertNil(row.lastCheckedHead)
        XCTAssertNil(row.upstreamCommit); XCTAssertNil(row.checkError)
        XCTAssertEqual(try fileService.readData(at: fixture.skillFile), fixture.pristine)
        let text = try XCTUnwrap(String(data: fixture.pristine, encoding: .utf8))
        try fileService.writeFile(at: fixture.skillFile, content: text + "\nlocal\n")
        let drifted = try fileService.readData(at: fixture.skillFile)
        XCTAssertEqual(
            try fixture.installer.adopt(
                existingSlug: "adopted",
                candidate: candidate,
                from: fetched,
                context: context
            ),
            .localDrift
        )
        XCTAssertEqual(try fileService.readData(at: fixture.skillFile), drifted)
        let overlay = try XCTUnwrap(
            try ManifestService(fileService: fileService)
                .read(fromRoot: root).skills.first { $0.slug == "adopted" }
        )
        XCTAssertEqual(overlay.tags, ["keep"])
        XCTAssertEqual(overlay.agents, ["codex"])
        guard case .installed(let origin) = overlay.origin else {
            return XCTFail("adopt should write installed coordinates")
        }
        XCTAssertEqual(
            origin.contentHash,
            try fixture.installer.stableContentHash(at: repository + "/skills/vendor")
        )
    }

    @MainActor
    private func prepareAuthoredAdoptFixture(
        root: String,
        candidate: SkillCandidate,
        source: SkillFetchResult,
        context: ModelContext
    ) throws -> AdoptFixture {
        let installer = makeInstallService(root: root)
        _ = try NativeTestWork.run(container: context.container) { [self] jobContext in
            try installer.install(
                candidate: candidate,
                renamedTo: "adopted",
                from: source,
                context: jobContext
                )
        }
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        row.installedOrigin = nil
        try ManifestService(fileService: fileService).upsertSkillOverlay(
            SkillOverlay(
                slug: "adopted",
                createdAt: row.createdAt,
                scope: .user,
                tags: ["keep"],
                cursor: nil,
                agents: ["codex"],
                origin: .authored
            ),
            toRoot: root
        )
        let skillFile = root + "/skills/adopted/SKILL.md"
        return AdoptFixture(
            installer: installer,
            skillFile: skillFile,
            pristine: try fileService.readData(at: skillFile)
        )
    }

    @MainActor
    func testSymlinkBearingCandidateRefusedWithNothingWritten() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeRepository(named: "Symlink Vendor")
            try writeSkill("skills/hostile", name: "Hostile", description: "linked", in: repository)
            try FileManager.default.createSymbolicLink(
                atPath: repository + "/skills/hostile/escape",
                withDestinationPath: tempDir + "/outside"
            )
            try commit(repository)
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let root = tempDir + "/symlink-store"
            let context = try makeInstallContext()

            XCTAssertThrowsError(
                try makeInstallService(root: root)
                    .install(candidate: candidate, from: fetched, context: context)
            )
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills"))
            XCTAssertFalse(fileService.directoryExists(at: root + "/manifest"))
            XCTAssertTrue(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        }
    }

    @MainActor
    func testMidCopyFailureLeavesNoPartialCanonicalDirectory() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let root = tempDir + "/copy-failure-store"
            let failingFiles = FailingCopyFileService(
                wrapped: fileService,
                failingName: "payload.bin"
            )
            let manifest = ManifestService(fileService: failingFiles)
            let installer = makeInstallService(
                root: root,
                using: failingFiles,
                manifest: manifest
            )

            XCTAssertThrowsError(
                try installer.install(
                    candidate: candidate,
                    from: fetched,
                    context: makeInstallContext()
                )
            ) { error in
                XCTAssertTrue(error is FailingCopyFileService.CopyFailure, "Must reach the injected copy failure: \(error)")
            }
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills/vendor"))
            XCTAssertTrue(try vendorTempPaths(under: root).isEmpty)
            try assertNoVendorTemps(root: root)
            XCTAssertFalse(fileService.directoryExists(at: root + "/manifest"))
        }
    }

    func assertNoVendorTemps(root: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let location = try VendorTemporaryDirectory.namespace(storeRoot: root, fileService: fileService)
        guard fileService.directoryExists(at: location.parent) else { return }
        XCTAssertFalse(try fileService.listDirectory(at: location.parent).contains { $0.hasPrefix(location.prefix) },
                       file: file, line: line)
    }

    private func vendorTempPaths(under root: String) throws -> [String] {
        let temporary = try TestStoreTemporary(root: root, files: fileService)
        guard fileService.directoryExists(at: temporary.parent) else { return [] }
        return try temporary.paths(files: fileService)
    }
}
