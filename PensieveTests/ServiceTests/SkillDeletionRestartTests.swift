import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class SkillDeletionRestartTests: XCTestCase {
    func testADeletionQueuedJustBeforeQuitStaysDeletedAndPublishesOnLaunch() async throws {
        for failRowSave in [false, true] {
            try await assertOrdinaryDeletionSurvivesQuit(failRowSave: failRowSave)
        }
    }

    private func assertOrdinaryDeletionSurvivesQuit(failRowSave: Bool) async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        h.local.skillSlugs = ["alpha"]
        h.doomed.skillSlugs = ["alpha"]
        for machine in [ProjectIntentHarness.localID, ProjectIntentHarness.remoteID] {
            h.context.insert(MachineDeployIntent(machineID: machine, skillSlug: "alpha", platformRaw: "codex"))
        }
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)

        var saveCount = 0
        XCTAssertEqual(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
            projects: [], context: h.context, persist: { context in
                saveCount += 1
                if failRowSave && saveCount == 2 { throw CocoaError(.fileWriteNoPermission) }
                try context.save()
            }), !failRowSave)
        XCTAssertFalse(h.files.directoryExists(at: h.root + "/skills/alpha"))
        let record = h.files.fileExists(at: h.recordPath)
            ? try JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any] : nil
        XCTAssertEqual((record?["deletions"] as? [[String: Any]])?.compactMap { $0["slug"] as? String }, ["alpha"])
        h.quit() // No suspension gives the old queue a chance to publish.

        try await h.relaunchThroughRuntime()
        XCTAssertFalse(h.local.skillSlugs.contains("alpha"))
        XCTAssertFalse(h.doomed.skillSlugs.contains("alpha"))
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<MachineDeployIntent>()).contains { $0.skillSlug == "alpha" })
        XCTAssertFalse(try h.context.fetch(FetchDescriptor<Skill>()).contains { $0.directoryName == "alpha" })
        await h.saves.waitUntilIdle()
        let durable = try h.manifest.read(fromRoot: h.root)
        XCTAssertFalse(durable.skills.contains { $0.slug == "alpha" })
        XCTAssertFalse(durable.categories.contains { $0.skillSlugs.contains("alpha") })
        XCTAssertFalse(durable.deployIntents.contains { $0.skillSlug == "alpha" })
        let settled = h.files.fileExists(at: h.recordPath)
            ? try JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any] : nil
        XCTAssertEqual((settled?["deletions"] as? [[String: Any]])?.count ?? 0, 0)
    }

    func testDeletingACollisionBeforeQuitRetiresThisMacAndPreservesThePeerThroughSync() async throws {
        for folderReturn in [PeerFolderReturn.never, .beforeLaunch, .duringLaunch] {
            for failRowSave in [false, true] {
                try await assertCollisionDeletionSurvivesQuit(failRowSave: failRowSave, folderReturn: folderReturn)
            }
        }
    }

    func testAPeerSkillArrivingDuringLaunchSurvivesDeletionReplayAndWholeSnapshotPublication() async throws {
        for whileWaitingForLock in [false, true] {
            try await assertPeerArrivalSurvives(whileWaitingForLock: whileWaitingForLock)
        }
    }

    private func assertPeerArrivalSurvives(whileWaitingForLock: Bool) async throws {
        let h = try ManifestSaveFixture(persistent: true)
        defer { h.cleanup() }
        let root = h.root
        try NativeTestWork.run {
            try TestPaths.git.initRepository(at: root)
            XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: root, message: "seed"))
        }
        h.local.skillSlugs = ["alpha"]
        h.context.insert(MachineDeployIntent(machineID: ProjectIntentHarness.remoteID,
            skillSlug: "alpha", platformRaw: "codex"))
        try h.context.save()
        var peer = try h.manifest.snapshot(from: h.context)
        let alpha = try XCTUnwrap(peer.skills.firstIndex { $0.slug == "alpha" })
        peer.skills[alpha].createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        peer.skills[alpha].tags = ["peer"]
        peer.skills[alpha].scope = .project
        peer.categories.sort { $0.name < $1.name }
        peer.skills.sort { $0.slug < $1.slug }
        let arriving = peer
        XCTAssertTrue(SkillDeletionFlow.delete(skill: h.alpha, library: h.library, platformVM: h.platform,
                                              projects: [], context: h.context))
        h.quit()

        try await relaunchWithPeerArrival(arriving, in: h, whileWaitingForLock: whileWaitingForLock)
        try await assertPeerPublication(arriving, in: h)
    }

    private func relaunchWithPeerArrival(_ arriving: ManifestSnapshot, in h: ManifestSaveFixture,
                                         whileWaitingForLock: Bool) async throws {
        let root = h.root
        let files = h.files, manifest = h.manifest
        let paths = AppRuntimePaths(storeRoot: root, appSupportDir: root + "/support")
        let reconcile = paths.makeLaunchReconcile()
        let deliverPeer = {
            try files.writeFile(at: root + "/skills/alpha/SKILL.md",
                content: SkillSerializer.serialize(name: "Peer Alpha", description: "peer", body: "peer body"))
            try manifest.write(arriving, toRoot: root)
        }
        if whileWaitingForLock {
            let held = try XCTUnwrap(SyncLock.tryAcquire(at: h.lockPath))
            defer { held.release() }
            try await h.relaunchThroughRuntime()
            XCTAssertTrue(h.saves.hasActiveSaves, "Restored cleanup must still be waiting to save")
            if h.saves.hasActiveSaves {
                await TestWait.until(failureMessage: "Deletion replay never waited for the helper's lock") { h.saves.isWaiting }
            }
            try deliverPeer()
            try NativeTestWork.run {
                XCTAssertTrue(try TestPaths.git.stageAllAndCommit(at: root, message: "peer arrives during pull"))
            }
            held.release()
        } else {
            try await h.relaunchThroughRuntime(launchReconcile: { context, migrated in
                if !files.directoryExists(at: root + "/skills/alpha") {
                    do { try deliverPeer() } catch { XCTFail("Couldn't deliver the peer creation: \(error)") }
                }
                return reconcile(context, migrated)
            })
        }
    }

    private func assertPeerPublication(_ arriving: ManifestSnapshot, in h: ManifestSaveFixture) async throws {
        let root = h.root
        await h.saves.waitUntilIdle()

        let displayed = try h.manifest.snapshot(from: h.context)
        XCTAssertEqual(displayed.skills.first { $0.slug == "alpha" }, arriving.skills.first { $0.slug == "alpha" })
        XCTAssertEqual(displayed.categories.sorted { $0.name < $1.name }, arriving.categories)
        XCTAssertEqual(displayed.deployIntents, arriving.deployIntents)
        XCTAssertEqual(try h.manifest.read(fromRoot: root), arriving)
        let record = try JSONSerialization.jsonObject(with: h.files.readData(at: h.recordPath)) as? [String: Any]
        XCTAssertEqual((record?["deletions"] as? [[String: Any]])?.count ?? 0, 0)
        // A later sync publishes the rebuilt rows through this same whole-snapshot boundary.
        try h.manifest.write(try StoreIngestState.snapshotForPublication(using: h.manifest,
            context: h.context, root: root), toRoot: root)
        XCTAssertEqual(try h.manifest.read(fromRoot: root), arriving)
        try await h.relaunchThroughRuntime()
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.manifest.read(fromRoot: root), arriving)
    }

    private enum PeerFolderReturn { case never, beforeLaunch, duringLaunch }

    private func assertCollisionDeletionSurvivesQuit(failRowSave: Bool, folderReturn: PeerFolderReturn) async throws {
        let h = try CollisionCreateFixture(persistent: true)
        defer { h.cleanup() }
        await h.saves.waitUntilIdle()
        try h.addOwnIntent()
        // Seed the saved request in both the local rows and the durable peer snapshot.
        var before = try h.f.manifest.read(fromRoot: h.f.app)
        before.deployIntents.append(DeployIntentRecord(machineID: ProjectIntentHarness.localID, skillSlug: "item",
            platformRaw: PlatformTarget.claudeCode.rawValue, projectKey: nil))
        try h.f.manifest.write(before, toRoot: h.f.app)
        XCTAssertEqual(try h.ownIntents(), ["item"])
        XCTAssertTrue(try h.f.manifest.read(fromRoot: h.f.app).deployIntents.contains {
            $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
        })

        var saveCount = 0
        XCTAssertEqual(SkillDeletionFlow.delete(skill: h.skill, library: h.library, platformVM: h.platform,
            projects: [], context: h.context, persist: { context in
                saveCount += 1
                if failRowSave && saveCount == 2 { throw CocoaError(.fileWriteNoPermission) }
                try context.save()
            }), !failRowSave)
        h.quit()
        let root = h.f.app, files = h.f.files
        let paths = AppRuntimePaths(storeRoot: root, appSupportDir: h.support)
        let reconcile = paths.makeLaunchReconcile()
        let deliverFolder = {
            try files.writeFile(at: root + "/skills/item/SKILL.md",
                content: SkillSerializer.serialize(name: "Peer Item", description: "peer", body: "peer body"))
        }
        if folderReturn == .beforeLaunch { try deliverFolder() }
        try await h.relaunchThroughRuntime(launchReconcile: { context, migrated in
            if folderReturn == .duringLaunch {
                do { try deliverFolder() } catch { XCTFail("Couldn't deliver the peer folder: \(error)") }
            }
            return reconcile(context, migrated)
        })
        await h.saves.waitUntilIdle()
        XCTAssertEqual(try h.ownIntents(), [])
        XCTAssertFalse(try h.f.manifest.read(fromRoot: h.f.app).deployIntents.contains {
            $0.machineID == ProjectIntentHarness.localID && $0.skillSlug == "item"
        })
        try h.assertPeer()
        try h.sync()
        try h.assertPeer()
    }
}
