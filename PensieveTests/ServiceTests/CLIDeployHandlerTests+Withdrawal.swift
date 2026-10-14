import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension CLIDeployHandlerTests {
    func assertUninstalledAndUnseenIntentWithdrawal(wildcard: Bool) throws {
        for machineID in [CLIDeployFixture.localID, CLIDeployFixture.remoteID] {
            let h = try CLIDeployFixture(installed: [.claudeCode], states: [])
            for (skill, projectKey) in [(h.skill, nil), (h.other, nil), (h.skill, h.project.identityKey)] {
                h.context.insert(MachineDeployIntent(machineID: machineID, skillSlug: skill.directoryName,
                    platformRaw: PlatformTarget.cursor.rawValue, projectKey: projectKey))
            }
            try h.context.save()
            try h.manifest.write(try h.manifest.snapshot(from: h.context), toRoot: h.root)
            let window = DeployIntentModel(service: h.service)
            window.reload(context: h.context)
            XCTAssertTrue(window.machines.contains { $0.id == machineID })
            XCTAssertTrue(window.availablePlatforms.contains(.cursor))
            let before = try h.intents()
            let targets = machineID == CLIDeployFixture.localID ? [] : [machineID]
            let refused = h.handler.handle(h.request(agents: ["cursor"], machines: targets), context: h.context)
            XCTAssertEqual(refused.envelope.error?.code, "agent_not_installed", "Deploy still requires an installed agent")
            XCTAssertEqual(try h.intents(), before)
            let removed = h.handler.handle(h.request("undeploy", agents: [wildcard ? "*" : "cursor"], machines: targets),
                context: h.context)
            XCTAssertEqual(removed.exitCode, 0)
            XCTAssertTrue(removed.envelope.ok)
            XCTAssertEqual(removed.envelope.changed, true)
            XCTAssertEqual(try h.intents(), before.subtracting([machineID + "|review|cursor"]))
            let manifest = try h.manifest.read(fromRoot: h.root)
            XCTAssertEqual(manifest.deployIntents.count, 2, "Other skills and project scopes must retain their intent")
        }
    }
}
