import XCTest
@testable import Pensieve

final class DeploymentsMachineSanitizationTests: XCTestCase {
    func testEveryPublishedStringSurfaceUsesTheSanitizedValues() throws {
        let controls = "\n\u{001B}\0\u{202E}\u{2067}"
        let machineName = controls + String(repeating: "M", count: 10_000)
        let projectName = controls + String(repeating: "P", count: 10_000)
        let path = "~/" + controls + String(repeating: "x", count: 10_000)
        let remoteID = "22222222-2222-4222-8222-222222222222"
        let remote = MachineState(
            schemaVersion: 1, machineID: remoteID, name: machineName, appVersion: "test",
            publishedAt: Date(), agents: ["codex"],
            projects: [MachineStateProject(
                identityKey: "github.com/example/project", kind: "git-remote",
                name: projectName, path: path
            )],
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")],
            projectDeploys: []
        )

        let content = DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: [remote],
            localMachineID: "11111111-1111-4111-8111-111111111111",
            intents: [], heldRetractions: []
        )
        let machine = try XCTUnwrap(content.machines.first)
        let project = try XCTUnwrap(content.projects.first)

        XCTAssertEqual(machine.name.count, 80)
        XCTAssertTrue(machine.name.hasSuffix("…"))
        XCTAssertTrue(machine.description.contains(machine.name))
        XCTAssertEqual(machine.rows[0].note, "Turned on from " + machine.name)
        XCTAssertEqual(project.name.count, 80)
        XCTAssertTrue(project.name.hasSuffix("…"))
        let sanitizedPath = PublishedStringSanitizer.path(path)
        XCTAssertEqual(sanitizedPath.count, 256)
        XCTAssertEqual(project.caption, machine.name + " · " + sanitizedPath)
        for value in [machine.name, machine.description, machine.rows[0].note ?? "", project.name, project.caption] {
            XCTAssertFalse(value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
            XCTAssertFalse(value.contains("\u{202E}"))
            XCTAssertFalse(value.contains("\u{2067}"))
        }
    }
}
