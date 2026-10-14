import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
extension CLIReadHandlerTests {
    func assertMachineCatalogReads() throws {
        let retiredID = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let states = [(CLIDeployFixture.localID, "kramer"), (CLIDeployFixture.remoteID, "Mini")].map { id, name in
            MachineState(schemaVersion: 1, machineID: id, name: name, appVersion: "fixture", publishedAt: Date(),
                agents: ["cursor"], projects: [], userDeploys: [], projectDeploys: [])
        }
        let h = try CLIDeployFixture(installed: [.claudeCode, .codex], states: states)
        h.context.insert(MachineDeployIntent(machineID: retiredID, skillSlug: "review", platformRaw: "cursor"))
        try h.context.save()
        let reply = h.readHandler.handle(CLIRequest(command: "machine list"), context: h.context)
        XCTAssertEqual(reply.exitCode, 0)
        let rows = try machineRows(reply)
        XCTAssertEqual(rows[CLIDeployFixture.localID]?["agents"], .array([.string("claude"), .string("codex")]),
            "This Mac's agents come from live detection, not its last publication")
        XCTAssertEqual(rows[CLIDeployFixture.remoteID]?["agents"], .array([.string("cursor")]))
        for id in [CLIDeployFixture.localID, CLIDeployFixture.remoteID, retiredID] {
            XCTAssertEqual(rows[id]?["isLocal"], .bool(id == CLIDeployFixture.localID))
            XCTAssertEqual(rows[id]?["isUnseen"], .bool(id == retiredID))
        }
        for fixture in ["missing", "malformed", "directory", "symlink", "noncanonical"] {
            let path = h.directory.path + "/identity-" + fixture
            let identityPath = path + "/machine-id"
            let files = h.directory.files
            if fixture == "malformed" { try files.writeFile(at: identityPath, content: "broken") }
            if fixture == "directory" { try files.createDirectory(at: identityPath) }
            if fixture == "symlink" {
                try files.writeFile(at: path + "/foreign", content: CLIDeployFixture.localID)
                try files.createSymlink(at: identityPath, pointingTo: path + "/foreign")
            }
            if fixture == "noncanonical" {
                try files.writeFile(at: identityPath, content: "  " + CLIDeployFixture.localID.lowercased() + "  \n")
            }
            let before = try h.tree()
            let service = DeployMutationService(platformVM: h.platform, dependencies: .live(
                identity: MachineIdentity(fileService: files, appSupportDir: path, warn: { _ in }),
                stateService: DeployIntentStateStub(states: states), root: h.root, lockPath: h.lock,
                notifier: {}, reconcile: { _ in BatchResult() }))
            let handler = CLIReadHandler(store: h.store, deployments: service)
            let listed = handler.handle(CLIRequest(command: "machine list"), context: h.context)
            XCTAssertEqual(listed.exitCode, 0, "Published states survive an unavailable local identity: " + fixture)
            let listedRows = try machineRows(listed)
            XCTAssertEqual(listedRows[CLIDeployFixture.remoteID]?["name"], .string("Mini"))
            XCTAssertEqual(listedRows[CLIDeployFixture.localID]?["name"],
                .string(fixture == "noncanonical" ? "This Mac" : "kramer"))
            XCTAssertEqual(try h.tree(), before, "A machine read must not create, repair or rewrite identity: " + fixture)
        }
    }

    private func machineRows(_ reply: CLIReply) throws -> [String: [String: CLIValue]] {
        guard case let .array(rows) = reply.envelope.data else { XCTFail("Missing machines"); return [:] }
        return try Dictionary(uniqueKeysWithValues: rows.map { value in
            guard case let .object(fields) = value, case let .string(id) = fields["id"] else {
                throw DeployStubFailure()
            }
            return (id, fields)
        })
    }
}
