import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    func testLaunchCleanupRemovesOnlyStaleVendorTempsUnderLock() throws {
        try NativeTestWork.run { [self] in
            let root = tempDir + "/cleanup-store"
            let stale = tempDir + "/cleanup-store.vendor-" + UUID().uuidString + ".tmp"
            let userDecoy = tempDir + "/cleanup-store.vendor-backup.tmp"
            let realSkill = root + "/skills/real-skill"
            try fileService.writeFile(at: stale + "/partial", content: "partial")
            try fileService.writeFile(at: userDecoy + "/precious", content: "user data")
            try fileService.writeFile(at: realSkill + "/SKILL.md", content: "keep")

            SkillInstallService.cleanupVendorTemps(
                fileService: fileService,
                storeRoot: root,
                lockPath: tempDir + "/cleanup-sync.lock"
            )

            XCTAssertFalse(fileService.directoryExists(at: stale))
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
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
            defer { held.release() }

            SkillInstallService.cleanupVendorTemps(
                fileService: fileService,
                storeRoot: root,
                lockPath: lockPath
            )
            XCTAssertTrue(fileService.directoryExists(at: stale))
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
