import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension CLIDeployHandlerTests {
    func assertListedMachineNamesReachTheirTargets() throws {
        let rawRemoteName = " \nMi\u{200E}ni\t "
        let states = [(CLIDeployFixture.localID, "kramer"), (CLIDeployFixture.remoteID, rawRemoteName)].map { id, name in
            MachineState(schemaVersion: 1, machineID: id, name: name, appVersion: "fixture", publishedAt: Date(),
                agents: ["claudeCode"], projects: [], userDeploys: [], projectDeploys: [])
        }
        let h = try CLIDeployFixture(states: states)
        let window = DeployIntentModel(service: h.service)
        window.reload(context: h.context)
        XCTAssertEqual(window.machines.map(\.name), ["This Mac", "Mini"])
        let listed = h.readHandler.handle(CLIRequest(command: "machine list"), context: h.context)
        guard case let .array(rows) = listed.envelope.data else { return XCTFail("Missing machines") }
        let names = rows.compactMap { row -> CLIValue? in
            guard case let .object(fields) = row else { return nil }
            return fields["name"]
        }
        XCTAssertEqual(names, [.string("This Mac"), .string("Mini")], "List names must match the window")
        for (name, id) in [("This Mac", CLIDeployFixture.localID), ("kramer", CLIDeployFixture.localID),
                           ("Mini", CLIDeployFixture.remoteID), (rawRemoteName, CLIDeployFixture.remoteID)] {
            let reply = h.handler.handle(h.request(machines: [name]), context: h.context)
            XCTAssertEqual(reply.exitCode, 0, name)
            XCTAssertTrue(reply.envelope.ok, name)
            XCTAssertEqual(try h.intents(), [id + "|review|claudeCode"], name)
            XCTAssertEqual(h.platform.isDeployed(skill: h.skill, platform: .claudeCode), id == CLIDeployFixture.localID)
            XCTAssertTrue(h.handler.handle(h.request("undeploy", machines: [name]), context: h.context).envelope.ok)
            XCTAssertTrue(try h.intents().isEmpty)
        }
    }

    func assertPublishedMachineAliasesRemainAmbiguous() throws {
        let states = [CLIDeployFixture.localID, CLIDeployFixture.remoteID].map { id in
            MachineState(schemaVersion: 1, machineID: id, name: "Mini", appVersion: "fixture", publishedAt: Date(),
                agents: ["claudeCode"], projects: [], userDeploys: [], projectDeploys: [])
        }
        let h = try CLIDeployFixture(states: states)
        let reply = h.handler.handle(h.request(machines: ["Mini"]), context: h.context)
        XCTAssertEqual(reply.exitCode, 5, "A local published alias must not silently select a remote Mac")
        XCTAssertEqual(reply.envelope.error?.code, "ambiguous")
        for id in [CLIDeployFixture.localID, CLIDeployFixture.remoteID] {
            XCTAssertTrue(reply.envelope.error?.message.contains(id) == true)
        }
        XCTAssertTrue(try h.intents().isEmpty)
    }

    func assertKeylessWildcardIgnoresUserWideIntents() throws {
        let h = try CLIDeployFixture(installed: [.claudeCode])
        for agent in [PlatformTarget.cursor, .hermes] {
            h.context.insert(MachineDeployIntent(machineID: CLIDeployFixture.localID,
                skillSlug: h.skill.directoryName, platformRaw: agent.rawValue))
        }
        try h.context.save()
        try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
        let seeded = h.platform.deployBatch(skills: [h.skill], platforms: [.cursor],
            target: .project(h.keyless), context: h.context)
        XCTAssertEqual(seeded.successes.count, 1, "Fixture represents an artifact left by an uninstalled agent")
        let before = try h.tree(), intents = try h.intents()
        let reply = h.handler.handle(h.request("undeploy", agents: ["*"], project: "Local"), context: h.context)
        XCTAssertTrue(reply.envelope.ok)
        XCTAssertEqual(reply.envelope.changed, false, "User-wide intent does not expand a keyless project's wildcard")
        guard case let .object(fields) = reply.envelope.data else { return XCTFail("Missing withdrawal result") }
        XCTAssertEqual(fields["changes"], .array([]))
        XCTAssertEqual(fields["skipped"], .array([]), "Uninstalled global-only Hermes does not belong to this project")
        XCTAssertTrue(h.platform.isDeployed(skill: h.skill, platform: .cursor, target: .project(h.keyless)))
        XCTAssertEqual(try h.tree(), before)
        XCTAssertEqual(try h.intents(), intents)
    }
}
