import SwiftData
import XCTest
@testable import Pensieve

private struct UnreadableRemoteIdentity: MachineIdentityProviding {
    func identifier() throws -> String { throw DeployStubFailure() }
}

@MainActor
extension DeployIntentModelTests {
    func testMachinePickerSanitizesNamesAndUsesNaturalOrderWithoutChangingIDs() throws {
        let macTenID = "33333333-3333-4333-8333-333333333333"
        let hostileID = "44444444-4444-4444-8444-444444444444"
        let states = [
            MachineState(
                schemaVersion: 1, machineID: remoteID, name: "Mac 2", appVersion: "test",
                publishedAt: Date(), agents: [], projects: [], userDeploys: [], projectDeploys: []
            ),
            MachineState(
                schemaVersion: 1, machineID: macTenID, name: "Mac 10", appVersion: "test",
                publishedAt: Date(), agents: [], projects: [], userDeploys: [], projectDeploys: []
            ),
            MachineState(
                schemaVersion: 1, machineID: hostileID, name: "\nM\u{200B}ac", appVersion: "test",
                publishedAt: Date(), agents: [], projects: [], userDeploys: [], projectDeploys: []
            )
        ]
        let harness = try makeHarness(states: states)

        harness.model.reload(context: harness.context)

        XCTAssertEqual(harness.model.machines.map(\.name), ["This Mac", "Mac", "Mac 2", "Mac 10"])
        XCTAssertEqual(harness.model.machines.map(\.id), [localID, hostileID, remoteID, macTenID])
    }

    func testMachinePickerBreaksSanitizedNameTiesByMachineIDInEitherInputOrder() throws {
        let pairs = [
            ("20000000-0000-4000-8000-000000000001", "30000000-0000-4000-8000-000000000001"),
            ("20000000-0000-4000-8000-000000000002", "30000000-0000-4000-8000-000000000002"),
            ("20000000-0000-4000-8000-000000000003", "30000000-0000-4000-8000-000000000003"),
            ("20000000-0000-4000-8000-000000000004", "30000000-0000-4000-8000-000000000004"),
            ("20000000-0000-4000-8000-000000000005", "30000000-0000-4000-8000-000000000005"),
            ("20000000-0000-4000-8000-000000000006", "30000000-0000-4000-8000-000000000006")
        ]

        for (firstID, secondID) in pairs {
            let first = MachineState(
                schemaVersion: 1, machineID: firstID, name: "Mac", appVersion: "test",
                publishedAt: Date(), agents: [], projects: [], userDeploys: [], projectDeploys: []
            )
            let second = MachineState(
                schemaVersion: 1, machineID: secondID, name: "M\u{200B}ac", appVersion: "test",
                publishedAt: Date(), agents: [], projects: [], userDeploys: [], projectDeploys: []
            )
            for states in [[first, second], [second, first]] {
                let harness = try makeHarness(states: states)
                harness.model.reload(context: harness.context)

                XCTAssertEqual(harness.model.machines.map(\.id), [localID, firstID, secondID])
                XCTAssertEqual(harness.model.machines.map(\.name), ["This Mac", "Mac", "Mac"])
            }
        }
    }

    func testRemoteWholeMacAndProjectSwitchesPersistIntentOnly() throws {
        var nudges = 0
        var reconciles = 0
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(
            notifier: { nudges += 1 },
            reconcile: { _ in reconciles += 1; return BatchResult() },
            remoteRetractions: holds
        )
        let skill = try insertSkill(context: harness.context)
        let projectKey = "github.com/example/remote"

        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )
        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: projectKey,
            skill: skill, platform: .codex, context: harness.context
        )

        var rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(Set(rows.compactMap(\.projectKey)), [projectKey])
        XCTAssertEqual(rows.filter { $0.projectKey == nil }.count, 1)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<IntentAssignment>()), 0)
        XCTAssertTrue(harness.linkService.linkCalls.isEmpty)
        XCTAssertTrue(harness.linkService.unlinkCalls.isEmpty)
        XCTAssertEqual(reconciles, 0)
        XCTAssertEqual(nudges, 2)
        let records = try ManifestService(fileService: harness.manifestFileService)
            .read(fromRoot: harness.root).deployIntents
        XCTAssertEqual(records.count, 2)

        try harness.model.setRemote(
            false, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )
        rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(rows.map(\.projectKey), [projectKey])
        XCTAssertEqual(holds.held, [RemoteDeployKey(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex", projectKey: nil
        )])

        try harness.model.setRemote(
            false, machineID: remoteID, projectKey: projectKey,
            skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(nudges, 4)
    }

    func testRemoteTwoQuickFlipsEndInSecondStateAndClearHoldOnTurnOn() throws {
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(remoteRetractions: holds)
        let skill = try insertSkill(context: harness.context)

        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )
        try harness.model.setRemote(
            false, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertEqual(holds.held.count, 1)

        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertTrue(holds.held.isEmpty)
    }

    func testRemoteManifestFailureRestoresRowAndRetractionHold() throws {
        var writes = 0
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(
            writeManifest: { _ in
                writes += 1
                if writes == 2 { throw DeployStubFailure() }
            },
            remoteRetractions: holds
        )
        let skill = try insertSkill(context: harness.context)
        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )

        XCTAssertThrowsError(try harness.model.setRemote(
            false, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        ))

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
        XCTAssertTrue(holds.held.isEmpty)
        XCTAssertNotNil(harness.model.error)
    }

    func testRemoteSwitchRefusesWhileSyncLockIsHeldBeforeMutation() throws {
        let lockPath = TestTemporaryDirectory.path + "PensieveRemoteSwitchLock-" + UUID().uuidString + ".lock"
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(lockPath: lockPath, remoteRetractions: holds)
        let skill = try insertSkill(context: harness.context)
        let lock = try XCTUnwrap(SyncLock.tryAcquire(at: lockPath))
        defer { lock.release() }

        XCTAssertThrowsError(try harness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        ))

        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
        XCTAssertTrue(holds.held.isEmpty)
        XCTAssertEqual(harness.model.error, "Sync is running. Try again when it finishes.")
    }

    func testRemoteSwitchRefusesLocalAndUnreadableIdentityBeforeMutation() throws {
        let localHarness = try makeHarness()
        let localSkill = try insertSkill(context: localHarness.context)

        XCTAssertThrowsError(try localHarness.model.setRemote(
            true, machineID: localID, projectKey: nil,
            skill: localSkill, platform: .codex, context: localHarness.context
        ))
        XCTAssertEqual(try localHarness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)

        let unreadableHarness = try makeHarness(identity: UnreadableRemoteIdentity())
        let unreadableSkill = try insertSkill(context: unreadableHarness.context)
        XCTAssertThrowsError(try unreadableHarness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: unreadableSkill, platform: .codex, context: unreadableHarness.context
        ))
        XCTAssertEqual(try unreadableHarness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 0)
    }

    func testSheetRetractionRecordsHoldAfterSuccessfulWriteAndPreventsBounce() throws {
        let holds = RemoteRetractionStore()
        let published = MachineState(
            schemaVersion: 1, machineID: remoteID, name: "Mini", appVersion: "test",
            publishedAt: Date(), agents: ["codex"], projects: [],
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")],
            projectDeploys: []
        )
        holds.observe([published])
        let harness = try makeHarness(states: [published], remoteRetractions: holds)
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex"
        ))
        try harness.context.save()

        _ = try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [remoteID], context: harness.context
        )

        let key = RemoteDeployKey(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex", projectKey: nil
        )
        XCTAssertEqual(holds.held, [key])
        let content = DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: [published], localMachineID: localID,
            intents: [], heldRetractions: holds.held
        )
        XCTAssertFalse(content.machines[0].rows[0].isOn)
        XCTAssertTrue(content.machines[0].rows[0].isEnabled)
    }

    func testSheetApplyRecordsDeletedRemoteHoldsAndClearsWrittenRemoteHolds() throws {
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(remoteRetractions: holds)
        let skill = try insertSkill(context: harness.context)
        let key = RemoteDeployKey(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex", projectKey: nil
        )
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex"
        ))
        try harness.context.save()

        _ = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [], context: harness.context
        )
        XCTAssertEqual(holds.held, [key], "removing a remote sheet selection records its hold")

        _ = try harness.model.apply(
            skills: [skill], platforms: [.codex], selectedMachineIDs: [remoteID], context: harness.context
        )
        XCTAssertTrue(holds.held.isEmpty, "re-adding through the sheet ends the exact hold")
    }

    func testRemoteProjectSwitchOnClearsItsExactHold() throws {
        let projectKey = "github.com/example/project"
        let key = RemoteDeployKey(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex", projectKey: projectKey
        )
        let holds = RemoteRetractionStore()
        holds.recordRetraction(key)
        let harness = try makeHarness(remoteRetractions: holds)
        let skill = try insertSkill(context: harness.context)

        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: projectKey,
            skill: skill, platform: .codex, context: harness.context
        )

        XCTAssertTrue(holds.held.isEmpty)
        XCTAssertEqual(
            try harness.context.fetch(FetchDescriptor<MachineDeployIntent>()).map(\.key),
            [remoteID + "|alpha|codex|" + projectKey]
        )
    }

    func testFailedSheetRetractionRecordsNoHold() throws {
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(
            writeManifest: { _ in throw DeployStubFailure() },
            remoteRetractions: holds
        )
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex"
        ))
        try harness.context.save()

        XCTAssertThrowsError(try harness.model.retract(
            skills: [skill], platforms: [.codex], machineIDs: [remoteID], context: harness.context
        ))

        XCTAssertTrue(holds.held.isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
    }

    func testFailedSaveChangesNoRemoteHold() throws {
        var shouldFailSave = false
        let holds = RemoteRetractionStore()
        let harness = try makeHarness(
            saveContext: { context in
                if shouldFailSave { throw DeployStubFailure() }
                try context.save()
            },
            remoteRetractions: holds
        )
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex"
        ))
        try harness.context.save()
        shouldFailSave = true

        XCTAssertThrowsError(try harness.model.setRemote(
            false, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        ))

        XCTAssertTrue(holds.held.isEmpty)
        XCTAssertEqual(try harness.context.fetchCount(FetchDescriptor<MachineDeployIntent>()), 1)
    }

    func testLocalSwitchLeavesRemoteRowsAndIntentsUnchanged() throws {
        let projectKey = "github.com/example/project"
        let published = MachineState(
            schemaVersion: 1, machineID: remoteID, name: "Mini", appVersion: "test",
            publishedAt: Date(), agents: ["codex"],
            projects: [MachineStateProject(identityKey: projectKey, kind: "git-remote", name: "Project")],
            userDeploys: [], projectDeploys: []
        )
        let harness = try makeHarness(states: [published])
        let skill = try insertSkill(context: harness.context)
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex"
        ))
        harness.context.insert(MachineDeployIntent(
            machineID: remoteID, skillSlug: "alpha", platformRaw: "codex", projectKey: projectKey
        ))
        try harness.context.save()
        let beforeRows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        let beforeFacts = DeploymentsPresentation.intentFacts(beforeRows, skillSlug: "alpha")
        let before = DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: [published], localMachineID: localID,
            intents: beforeFacts, heldRetractions: []
        )

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )

        let afterRows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        let remoteRows = afterRows.filter { $0.machineID == remoteID }
        XCTAssertEqual(Set(remoteRows.map(\.key)), Set(beforeRows.map(\.key)))
        let after = DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: [published], localMachineID: localID,
            intents: DeploymentsPresentation.intentFacts(afterRows, skillSlug: "alpha"),
            heldRetractions: []
        )
        XCTAssertEqual(after, before)
    }

    func testTabActionsLeaveIntentOnlyMachineUntouched() throws {
        let intentOnlyID = "44444444-4444-4444-8444-444444444444"
        let harness = try makeHarness()
        let skill = try insertSkill(context: harness.context)
        let untouched = MachineDeployIntent(
            machineID: intentOnlyID, skillSlug: "alpha", platformRaw: "codex"
        )
        harness.context.insert(untouched)
        try harness.context.save()

        _ = try harness.model.set(
            true, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        _ = try harness.model.set(
            false, skill: skill, platform: .codex, target: .userWide, context: harness.context
        )
        try harness.model.setRemote(
            true, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )
        try harness.model.setRemote(
            false, machineID: remoteID, projectKey: nil,
            skill: skill, platform: .codex, context: harness.context
        )

        let rows = try harness.context.fetch(FetchDescriptor<MachineDeployIntent>())
        XCTAssertEqual(rows.map(\.key), [intentOnlyID + "|alpha|codex"])
    }
}
