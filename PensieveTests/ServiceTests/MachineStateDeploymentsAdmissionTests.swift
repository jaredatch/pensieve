import XCTest
@testable import Pensieve

final class MachineStateDeploymentsAdmissionTests: XCTestCase {
    private let fileService = FileService()
    private let localID = "11111111-1111-4111-8111-111111111111"
    private let validID = "22222222-2222-4222-8222-222222222222"
    private let hostileID = "33333333-3333-4333-8333-333333333333"
    private let otherID = "44444444-4444-4444-8444-444444444444"

    func testOnlyReaderAdmittedStatesReachDeploymentPresentation() throws {
        try assertRejected(filename: "not-a-uuid.yaml", stateID: hostileID)
        try assertRejected(filename: hostileID + ".yaml", stateID: otherID)
        try assertRejected(filename: hostileID + ".yaml", stateID: validID)

        let root = makeRoot()
        defer { try? fileService.deleteDirectory(at: root) }
        let service = MachineStateService(fileService: fileService)
        try service.write(state(id: validID, name: "Valid"), toRoot: root)
        try service.write(state(id: localID, name: "Forged Local"), toRoot: root)
        let content = DeploymentsPresentation.remoteContent(
            skillSlug: "alpha",
            machineStates: service.readAll(fromRoot: root),
            localMachineID: localID,
            intents: [],
            heldRetractions: []
        )
        XCTAssertEqual(content.machines.map(\.id), [validID])
    }

    private func assertRejected(filename: String, stateID: String) throws {
        let root = makeRoot()
        let sourceRoot = root + "-source"
        defer {
            try? fileService.deleteDirectory(at: root)
            try? fileService.deleteDirectory(at: sourceRoot)
        }
        let service = MachineStateService(fileService: fileService)
        try service.write(state(id: validID, name: "Valid"), toRoot: root)
        try service.write(state(id: stateID, name: "Hostile"), toRoot: sourceRoot)
        let hostile = try fileService.readFile(at: sourceRoot + "/machines/" + stateID + ".yaml")
        try fileService.writeFile(
            at: root + "/machines/" + filename,
            content: hostile
        )

        let states = service.readAll(fromRoot: root)
        let content = DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: states, localMachineID: localID,
            intents: [], heldRetractions: []
        )
        XCTAssertEqual(states.map(\.machineID), [validID])
        XCTAssertEqual(content.machines.map(\.id), [validID])
    }

    private func state(id: String, name: String) -> MachineState {
        MachineState(
            schemaVersion: 1, machineID: id, name: name, appVersion: "test",
            publishedAt: Date(timeIntervalSince1970: 10), agents: ["codex"], projects: [],
            userDeploys: [], projectDeploys: []
        )
    }

    private func makeRoot() -> String {
        NSTemporaryDirectory() + "PensieveMachineAdmission-" + UUID().uuidString
    }
}
