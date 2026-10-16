import Foundation
import Observation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class CLIDeployHandlerTests: XCTestCase {
    func testLocalAndProjectDeployPreviewApplyRepeatAndUndeploy() async throws {
        for projectScope in [false, true] {
            let h = try CLIDeployFixture()
            let target: DeployTarget = projectScope ? .project(h.project) : .userWide
            let project = projectScope ? "." : nil
            let request = h.request(agents: ["claude-code"], project: project)
            try await seedUnrelatedIntent(h)
            let before = try h.tree(), rows = try h.intents()
            var previewRequest = request
            previewRequest.deployment?.dryRun = true
            let preview = await h.handler.handle(previewRequest, context: h.context)
            XCTAssertTrue(preview.envelope.ok)
            XCTAssertEqual(try h.tree(), before)
            XCTAssertEqual(try h.intents(), rows)
            XCTAssertFalse(h.context.hasChanges)
            let invalidations = Counter()
            withObservationTracking { _ = h.platform.deployIndex } onChange: { invalidations.increment() }
            let applied = await h.handler.handle(request, context: h.context)
            XCTAssertTrue(applied.envelope.ok)
            XCTAssertEqual(applied.envelope.changed, true)
            XCTAssertEqual(invalidations.value, 1)
            XCTAssertFalse(h.platform.isDeployed(skill: h.other, platform: .codex))
            XCTAssertEqual(fields(preview)["changes"], fields(applied)["changes"])
            XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .claudeCode, target: target))
            XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<IntentAssignment>()), 1)
            let manifest = try NativeTestWork.run { try h.manifest.read(fromRoot: h.root) }
            let intent = manifest.deployIntents.first { $0.skillSlug == h.skill.directoryName }
            XCTAssertEqual(intent?.machineID, CLIDeployFixture.localID)
            XCTAssertEqual(intent?.projectKey, target.project?.identityKey)
            XCTAssertEqual(try h.platform.deployStateStore.read().records.count, 1)
            let stable = try h.tree()
            let repeated = await h.handler.handle(request, context: h.context)
            XCTAssertTrue(repeated.envelope.ok)
            XCTAssertEqual(repeated.exitCode, 0)
            XCTAssertEqual(repeated.envelope.changed, false)
            XCTAssertEqual(try h.tree(), stable)
            try await assertRemoval(h, project: project, target: target, stable: stable, rows: rows)
        }
        try await assertUninstalledAndUnseenIntentWithdrawal(wildcard: false)
    }

    private func assertRemoval(_ h: CLIDeployFixture, project: String?, target: DeployTarget,
                               stable: [String: Data], rows: Set<String>) async throws {
        let removal = h.request("undeploy", project: project)
        var dryRemoval = removal
        dryRemoval.deployment?.dryRun = true
        let removalPreview = await h.handler.handle(dryRemoval, context: h.context)
        XCTAssertEqual(try h.tree(), stable)
        let removed = await h.handler.handle(removal, context: h.context)
        XCTAssertTrue(removed.envelope.ok)
        XCTAssertEqual(fields(removalPreview)["changes"], fields(removed)["changes"])
        XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .claudeCode, target: target))
        XCTAssertEqual(try h.intents(), rows)
        XCTAssertTrue(try h.platform.deployStateStore.read().records.isEmpty)
        let empty = try h.tree()
        let repeated = await h.handler.handle(removal, context: h.context)
        XCTAssertTrue(repeated.envelope.ok)
        XCTAssertEqual(repeated.exitCode, 0)
        XCTAssertEqual(repeated.envelope.changed, false)
        XCTAssertEqual(try h.tree(), empty)
    }

    private func seedUnrelatedIntent(_ h: CLIDeployFixture) async throws {
        h.context.insert(MachineDeployIntent(machineID: CLIDeployFixture.localID,
            skillSlug: h.other.directoryName, platformRaw: PlatformTarget.codex.rawValue))
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
    }

    func testRemoteAndLocalTargetsPreserveOtherSelections() async throws {
        let h = try CLIDeployFixture()
        let window = DeployIntentModel(service: h.service)
        _ = try window.set(true, skill: h.other, platform: .codex, target: .userWide, context: h.context)
        let before = try h.intents()
        let remote = await h.handler.handle(h.request(agents: ["*"], machines: ["Mini"]), context: h.context)
        XCTAssertTrue(remote.envelope.ok)
        XCTAssertEqual(remote.envelope.next, ["pensieve sync"])
        XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        XCTAssertTrue(try h.intents().isSuperset(of: before))
        XCTAssertEqual(try h.intents().count, 3)
        let local = await h.handler.handle(h.request(machines: [CLIDeployFixture.localID]), context: h.context)
        XCTAssertTrue(local.envelope.ok)
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        let remoteRows = try h.intents().filter { $0.hasPrefix(CLIDeployFixture.remoteID) }
        XCTAssertEqual(remoteRows.count, 2)
        let removed = await h.handler.handle(h.request("undeploy", machines: ["Mini"]), context: h.context)
        XCTAssertTrue(removed.envelope.ok)
        XCTAssertTrue(try h.intents().isSuperset(of: before))
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        XCTAssertEqual(try h.intents().filter { $0.hasPrefix(CLIDeployFixture.remoteID) }.count, 1)
        let batch = await h.handler.handle(h.request(skills: [h.skill.directoryName, h.other.directoryName],
            agents: ["codex"], machines: ["Mini", CLIDeployFixture.localID]), context: h.context)
        XCTAssertTrue(batch.envelope.ok)
        XCTAssertEqual(try h.intents().count, 5)
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .codex))
        try await assertUninstalledAndUnseenIntentWithdrawal(wildcard: true)
        try await assertListedMachineNamesReachTheirTargets()
    }

    func testKeylessProjectsStayLocalAndWildcardListsUnsupportedAgents() async throws {
        let h = try CLIDeployFixture()
        let before = try h.intents()
        let deploy = await h.handler.handle(h.request(agents: ["*"], project: "Local"), context: h.context)
        XCTAssertTrue(deploy.envelope.ok)
        XCTAssertEqual(try h.intents(), before)
        guard case let .array(changes) = fields(deploy)["changes"] else { return XCTFail("Missing changes") }
        XCTAssertEqual(changes.count, 3)
        XCTAssertTrue(changes.allSatisfy { value in
            guard case let .object(fields) = value else { return false }
            return fields["localOnly"] == .bool(true)
        })
        XCTAssertEqual(fields(deploy)["skipped"], .array([
            .object(["agent": .string("hermes"), "reason": .string("project_scope_unsupported")])]))
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .codex, target: .project(h.keyless)))
        let removal = await h.handler.handle(h.request("undeploy", agents: ["*"], project: "Local"), context: h.context)
        XCTAssertTrue(removal.envelope.ok)
        XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .codex, target: .project(h.keyless)))
        XCTAssertEqual(try h.intents(), before)
        try await assertKeylessWildcardIgnoresUserWideIntents()
    }

    func testRefusedAgentNamesAndAmbiguousProjectsChangeNothing() async throws {
        let h = try CLIDeployFixture()
        let duplicate = Project(name: "App", path: h.directory.path + "/another")
        h.context.insert(duplicate)
        for slug in ["aardvark", "aardwolf", "revise", "reviews", "zzzz"] {
            h.context.insert(Skill(name: slug, directoryName: slug))
        }
        try h.context.save()
        let cases: [(CLIRequest, (String, Int32))] = [
            (h.request(skills: ["revie"]), ("skill_not_found", 4)),
            (h.request(agents: ["claud"]), ("agent_not_found", 4)),
            (h.request(project: "Ap"), ("project_not_found", 4)),
            (h.request(project: h.directory.path), ("project_not_registered", 4)),
            (h.request(machines: ["Min"]), ("machine_not_found", 4)),
            (h.request(project: "App"), ("ambiguous", 5)),
            (h.request(agents: ["grok-cli"]), ("agent_not_installed", 1)),
            (h.request(agents: ["xai"]), ("agent_not_installed", 1)),
            (h.request(agents: ["hermes-agent"], project: "Local"), ("project_scope_unsupported", 1)),
            (h.request(agents: ["hermes"], machines: ["Mini"]), ("agent_not_installed", 1))
        ]
        let before = try h.tree()
        for (request, expected) in cases {
            let (code, exit) = expected
            let result = await h.handler.handle(request, context: h.context)
            XCTAssertEqual(result.exitCode, exit, code)
            XCTAssertEqual(result.envelope.error?.code, code)
            XCTAssertFalse(try XCTUnwrap(result.envelope.error?.hint).isEmpty)
            if code.hasSuffix("_not_found") { XCTAssertTrue(result.envelope.error?.hint.contains("Closest names:") == true) }
            if code == "skill_not_found" {
                XCTAssertTrue(result.envelope.error?.hint.hasPrefix("Closest names: review, revise, reviews.") == true,
                    "Suggestions must rank distance ahead of alphabetical order")
            }
            if code == "project_not_registered" {
                XCTAssertTrue(result.envelope.error?.hint.contains("pensieve project add") == true)
            }
            if code == "ambiguous" { XCTAssertTrue(result.envelope.error?.message.contains(duplicate.path) == true) }
            XCTAssertEqual(try h.tree(), before, code)
            XCTAssertTrue(try h.intents().isEmpty)
        }
    }

    func testAmbiguousMachinesListIDsAndAnIDDisambiguatesTheTarget() async throws {
        let otherID = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let states = [CLIDeployFixture.remoteID, otherID].map { machineID in
            MachineState(schemaVersion: 1, machineID: machineID, name: " \nMi\u{200E}ni\t ", appVersion: "fixture",
                publishedAt: Date(), agents: ["claudeCode"], projects: [], userDeploys: [], projectDeploys: [])
        }
        let h = try CLIDeployFixture(states: states)
        let window = DeployIntentModel(service: h.service)
        window.reload(context: h.context)
        XCTAssertEqual(window.machines.filter { !$0.isLocal }.map(\.name), ["Mini", "Mini"])
        let refusal = await h.handler.handle(h.request(machines: ["Mini"]), context: h.context)
        XCTAssertEqual(refusal.exitCode, 5)
        XCTAssertEqual(refusal.envelope.error?.code, "ambiguous")
        for state in states { XCTAssertTrue(refusal.envelope.error?.message.contains(state.machineID) == true) }
        XCTAssertTrue(try h.intents().isEmpty)
        let applied = await h.handler.handle(h.request(machines: [otherID]), context: h.context)
        XCTAssertTrue(applied.envelope.ok)
        XCTAssertEqual(try h.intents(), [otherID + "|" + h.skill.directoryName + "|claudeCode"])
        try await assertMachineLookupPrecedence()
    }

    func testSharedWindowAndCommandLockAndSaveRollback() async throws {
        for failsSave in [false, true] {
            let h = try CLIDeployFixture(save: { context in
                if failsSave { throw DeployStubFailure() }
                try context.save()
            })
            let held = failsSave ? nil : try XCTUnwrap(SyncLock.tryAcquire(at: h.lock))
            defer { held?.release() }
            let window = DeployIntentModel(service: h.service)
            XCTAssertThrowsError(try window.set(true, skill: h.skill, platform: .claudeCode,
                target: .userWide, context: h.context))
            let result = await h.handler.handle(h.request(), context: h.context)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertEqual(result.envelope.error?.code, failsSave ? "deploy_failed" : "sync_running")
            XCTAssertEqual(result.envelope.error?.retryable, !failsSave)
            XCTAssertTrue(try h.intents().isEmpty)
            XCTAssertFalse(h.platform.isDeployed(skill: h.skill, platform: .claudeCode))
            let manifest = try NativeTestWork.run { try h.manifest.read(fromRoot: h.root) }
            XCTAssertTrue(manifest.deployIntents.isEmpty)
        }
    }

    func fields(_ reply: CLIReply) -> [String: CLIValue] {
        guard case let .object(fields) = reply.envelope.data else { XCTFail("Missing command data"); return [:] }
        return fields
    }
}
