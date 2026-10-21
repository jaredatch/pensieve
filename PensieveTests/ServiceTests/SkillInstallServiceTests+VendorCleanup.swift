import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    func testLaunchCleanupNeverListsTheTemporaryParent() throws {
        let root = tempDir + "/bounded-cleanup-store"
        try fileService.createDirectory(at: root)
        let temporaryParent = try fileService.storeTemporaryParent(root: root)
        let service = ImportPublicationFileService()
        let stale = try VendorTemporaryDirectory.makePath(storeRoot: root, fileService: fileService)
        try fileService.writeFile(at: stale + "/partial", content: "partial")
        defer { try? fileService.deleteDirectory(at: (stale as NSString).deletingLastPathComponent) }

        SkillInstallService.cleanupVendorTemps(fileService: service, storeRoot: root,
                                               lockPath: tempDir + "/bounded-cleanup.lock")

        XCTAssertFalse(service.directoryListings.isEmpty)
        XCTAssertFalse(service.directoryListings.contains(temporaryParent),
                       "Launch must not enumerate the shared temporary parent")
        XCTAssertFalse(fileService.directoryExists(at: stale))
        XCTAssertFalse(fileService.directoryExists(at: (stale as NSString).deletingLastPathComponent))
        XCTAssertEqual(service.directoryListings.filter { $0 == (stale as NSString).deletingLastPathComponent }.count, 1)
    }

    func testPublisherCreatesItsFolderAndRefusesLinkedOrFileOccupants() throws {
        let root = tempDir + "/namespace-store"
        try fileService.createDirectory(at: root)
        let folder = try VendorTemporaryDirectory.namespace(storeRoot: root, fileService: fileService).parent
        defer { try? fileService.deleteDirectory(at: folder) }
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: tempDir + "/namespace.lock"))
        defer { lock.release() }
        let publisher = ManifestService(fileService: fileService)
        let snapshot = ManifestSnapshot(schemaVersion: ManifestService.currentSchemaVersion,
                                        categories: [], projects: [], skills: [])
        XCTAssertFalse(try fileService.entryExistsWithoutFollowingLinks(at: folder))
        try publisher.write(snapshot, toRoot: root)
        XCTAssertNil(try fileService.entryTypeWithoutFollowingLinks(at: folder))
        try publisher.write(snapshot, toRoot: root)
        XCTAssertFalse(try fileService.entryExistsWithoutFollowingLinks(at: folder))

        let target = tempDir + "/foreign"
        let precious = target + "/manifest-build-" + UUID().uuidString + ".tmp"
        try fileService.writeFile(at: precious, content: "foreign bytes")
        for occupant in ["link", "file"] {
            if occupant == "link" {
                try fileService.createSymlink(at: folder, pointingTo: target)
            } else {
                try fileService.writeFile(at: folder, content: "occupied")
            }
            XCTAssertThrowsError(try publisher.write(snapshot, toRoot: root))
            SkillInstallService.cleanupVendorTemps(fileService: fileService, storeRoot: root,
                                                   lockPath: tempDir + "/namespace.lock", externallyHeldLock: true)
            XCTAssertEqual(try fileService.listDirectory(at: target), [(precious as NSString).lastPathComponent])
            XCTAssertEqual(try fileService.readFile(at: precious), "foreign bytes")
            if occupant == "link" {
                XCTAssertEqual(try fileService.symlinkTarget(at: folder), target)
            } else {
                XCTAssertEqual(try fileService.readFile(at: folder), "occupied")
            }
            try fileService.deleteFile(at: folder)
        }
    }

    func testLaunchCleanupRemovesOnlyStaleVendorTempsUnderLock() throws {
        try NativeTestWork.run { [self] in
            let root = tempDir + "/cleanup-store"
            let stale = tempDir + "/cleanup-store.vendor-" + UUID().uuidString + ".tmp"
            let legacyManifest = tempDir + "/cleanup-store.manifest-build-" + UUID().uuidString + ".tmp"
            let legacyMachine = tempDir + "/cleanup-store.machine-state-" + UUID().uuidString + ".tmp"
            try fileService.writeFile(at: legacyManifest + "/partial", content: "manifest")
            try fileService.writeFile(at: legacyMachine, content: "machine")
            let userDecoy = tempDir + "/cleanup-store.vendor-backup.tmp"
            let realSkill = root + "/skills/real-skill"
            try fileService.writeFile(at: stale + "/partial", content: "partial")
            try fileService.writeFile(at: userDecoy + "/precious", content: "user data")
            try fileService.writeFile(at: realSkill + "/SKILL.md", content: "keep")

            let current = try makeCleanupTemps(root: root)
            defer { try? fileService.deleteDirectory(at: (current[0] as NSString).deletingLastPathComponent) }
            SkillInstallService.cleanupVendorTemps(
                fileService: fileService,
                storeRoot: root,
                lockPath: tempDir + "/cleanup-sync.lock"
            )
            for path in current { XCTAssertFalse(try fileService.entryExistsWithoutFollowingLinks(at: path)) }

            XCTAssertFalse(fileService.directoryExists(at: stale))
            XCTAssertFalse(fileService.directoryExists(at: legacyManifest))
            XCTAssertFalse(fileService.fileExists(at: legacyMachine))
            // Non-UUID sibling in the sweep directory is USER data, never app-owned — must survive.
            XCTAssertTrue(fileService.fileExists(at: userDecoy + "/precious"))
            XCTAssertTrue(fileService.fileExists(at: realSkill + "/SKILL.md"))
        }
    }

    @MainActor
    func testLaunchCleanupLeavesVendorTempWhenLockIsBusy() throws {
        try NativeTestWork.run { [self] in
            let root = tempDir + "/cleanup-race-store"
            let stale = tempDir + "/cleanup-race-store.vendor-" + UUID().uuidString + ".tmp"
            let lockPath = tempDir + "/cleanup-race-sync.lock"
            try fileService.writeFile(
                at: stale + "/SKILL.md",
                content: "---\nname: Partial\ndescription: Interrupted copy\n---\npartial\n"
            )
            try fileService.createDirectory(at: root)
            let current = try makeCleanupTemps(root: root)
            defer { try? fileService.deleteDirectory(at: (current[0] as NSString).deletingLastPathComponent) }
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
            defer { held.release() }

            SkillInstallService.cleanupVendorTemps(
                fileService: fileService,
                storeRoot: root,
                lockPath: lockPath
            )
            XCTAssertTrue(fileService.directoryExists(at: stale))
            for path in current { XCTAssertTrue(try fileService.entryExistsWithoutFollowingLinks(at: path)) }
        }
    }

    private func makeCleanupTemps(root: String) throws -> [String] {
        try ["vendor", "manifest-build", "machine-state"].map { kind in
            let path = try VendorTemporaryDirectory.makePath(storeRoot: root, fileService: fileService, kind: kind)
            try fileService.writeFile(at: kind == "machine-state" ? path : path + "/partial", content: "partial")
            return path
        }
    }

    @MainActor
    func testInstallMutationRefusesWhileSyncLockIsHeld() throws {
        try NativeTestWork.run { [self] in
            let repository = try makeVendorFixture()
            let fetched = try service.fetch(repo: repository, ref: nil, credential: nil)
            let candidate = try XCTUnwrap(fetched.candidates.first)
            let root = tempDir + "/locked-store"
            let lockPath = root + "-sync.lock"
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
            defer { held.release() }
            let installer = SkillInstallService(
                gitService: gitService,
                credentialStore: InMemoryCredentialStore(),
                fileService: fileService,
                scratchRoot: root + "-scratch",
                storeRoot: root,
                lockPath: lockPath,
                remoteValidator: fixtureRemoteValidator
            )

            XCTAssertThrowsError(
                try installer.install(
                    candidate: candidate,
                    from: fetched,
                    context: makeInstallContext()
                )
            ) { error in
                XCTAssertEqual(error as? SkillInstallError, .syncInProgress)
            }
            XCTAssertFalse(fileService.directoryExists(at: root + "/skills"))
            XCTAssertFalse(fileService.directoryExists(at: root + "/manifest"))
        }
    }

}
