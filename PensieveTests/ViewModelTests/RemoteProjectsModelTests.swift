import XCTest
@testable import Pensieve

final class RemoteProjectsModelTests: XCTestCase {
    private typealias Fixture = RemoteProjectTestSupport

    func testUnchangedInputsKeepSharedMachineModels() throws {
        let mini = Fixture.machine()
        let laptop = Fixture.machine(id: "laptop", name: "MacBook Pro")
        var model = RemoteProjectsModel()
        XCTAssertTrue(model.refresh(inputs([mini, laptop], keys: ["b", "a"]), now: { Fixture.publishedAt }))
        let machine = try XCTUnwrap(model.projects.first?.machines.first?.detail)

        XCTAssertFalse(model.refresh(inputs([laptop, mini], keys: ["a", "b", "a"]), now: { Fixture.publishedAt }))
        XCTAssertTrue(model.projects.first?.machines.first?.detail === machine,
                      "Unchanged semantic inputs must keep the machine models shared by the list and detail")
    }

    func testRefreshTracksDetailsRegistrationAndLocalMachineIdentity() throws {
        var model = RemoteProjectsModel()
        XCTAssertTrue(model.refresh(inputs([Fixture.machine()]), now: { Fixture.publishedAt }))
        let changed = Fixture.machine(projects: [Fixture.project(name: "Renamed", path: "~/New")],
                                      deploys: [Fixture.deploy("new-skill")],
                                      publishedAt: Fixture.publishedAt.addingTimeInterval(3_600))
        XCTAssertTrue(model.refresh(inputs([changed]), now: { Fixture.publishedAt }))
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.name, "Renamed")
        XCTAssertEqual(project.machines.first?.publishedPath, "~/New")
        XCTAssertEqual(project.machines.first?.deploys.map(\.displaySkillSlug), ["new-skill"])
        XCTAssertEqual(project.machines.first?.detail.publishedAt, changed.publishedAt)

        XCTAssertTrue(model.refresh(inputs([changed], keys: [Fixture.key]), now: { Fixture.publishedAt }))
        XCTAssertTrue(model.projects.isEmpty, "A local registration retires the remote row")
        XCTAssertTrue(model.refresh(inputs([changed]), now: { Fixture.publishedAt }))
        XCTAssertEqual(model.projects.map(\.identityKey), [Fixture.key])
        XCTAssertTrue(model.refresh(inputs([changed], localID: changed.machineID), now: { Fixture.publishedAt }))
        XCTAssertTrue(model.projects.isEmpty, "Changing this Mac's identity must reclassify its state")
        XCTAssertTrue(model.refresh(inputs([changed], localID: nil), now: { Fixture.publishedAt }))
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(model.refresh(inputs([changed]), now: { Fixture.publishedAt }))
        XCTAssertTrue(model.refresh(inputs([]), now: { Fixture.publishedAt }))
        XCTAssertTrue(model.projects.isEmpty, "Removing the last publication clears the cached result")
    }

    private func inputs(_ states: [MachineState], keys: [String] = [],
                        localID: String? = InertMachineIdentity.value) -> RemoteProjectsModel.Inputs {
        RemoteProjectsModel.Inputs(machineStates: states, localProjectIdentityKeys: keys, localMachineID: localID)
    }
}
