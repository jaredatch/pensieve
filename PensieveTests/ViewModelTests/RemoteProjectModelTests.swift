import XCTest
@testable import Pensieve

final class RemoteProjectModelTests: XCTestCase {
    private typealias Fixture = RemoteProjectTestSupport

    func testLowestMachineIDSuppliesNameAndKindAcrossPublishesAndRenames() throws {
        let owner = Fixture.machine(id: "a", name: "Zulu", projects: [
            Fixture.project(name: "Canonical", kind: "marker")
        ])
        let other = Fixture.machine(id: "b", name: "Alpha", projects: [Fixture.project(name: "Other")])
        let republishedOwner = Fixture.machine(id: "a", name: "Aardvark", projects: owner.projects,
                                              deploys: [Fixture.deploy("unrelated", key: "elsewhere")],
                                              publishedAt: Fixture.publishedAt.addingTimeInterval(3_600))
        let republishedOther = Fixture.machine(id: "b", name: "Before Zulu", projects: other.projects,
                                              deploys: [Fixture.deploy("another", key: "elsewhere")],
                                              publishedAt: Fixture.publishedAt.addingTimeInterval(7_200))
        let renamedProject = Fixture.machine(id: "a", name: "Zulu", projects: [
            Fixture.project(name: "Renamed", kind: "remote")
        ])
        let removedProject = Fixture.machine(id: "a", name: "Zulu", projects: [])
        let cases: [([MachineState], (name: String, kind: String))] = [
            ([owner, other], ("Canonical", "marker")),
            ([republishedOwner, other], ("Canonical", "marker")),
            ([owner, republishedOther], ("Canonical", "marker")),
            ([republishedOwner, republishedOther], ("Canonical", "marker")),
            ([renamedProject, republishedOther], ("Renamed", "remote")),
            ([removedProject, republishedOther], ("Other", "remote"))
        ]
        for (states, expected) in cases {
            for orderedStates in [states, Array(states.reversed())] {
                let project = try XCTUnwrap(RemoteProjectModel.onlyOnOtherMacs(
                    states: orderedStates, localProjectIdentityKeys: [], localMachineID: InertMachineIdentity.value
                ).first)
                XCTAssertEqual(project.name, expected.name)
                XCTAssertEqual(project.kind, expected.kind)
            }
        }
    }

    func testDetailShowsEachMacPathFreshnessAndOnlyItsProjectDeploys() throws {
        let mini = Fixture.machine(projects: [Fixture.project(path: "~/Projects/mini")], deploys: [
            Fixture.deploy("alpha"), Fixture.deploy("alpha"), Fixture.deploy("alpha", platform: "cursor"),
            Fixture.deploy("unrelated", key: "elsewhere")
        ])
        let laptop = Fixture.machine(id: "laptop", name: "MacBook Pro", projects: [Fixture.project(path: nil)],
                                     publishedAt: Fixture.publishedAt.addingTimeInterval(3_600))
        let now = Fixture.publishedAt.addingTimeInterval(7_200)
        let projects = RemoteProjectModel.onlyOnOtherMacs(states: [laptop, mini], localProjectIdentityKeys: [],
                                                        localMachineID: InertMachineIdentity.value, now: { now })
        let project = try XCTUnwrap(projects.first)

        XCTAssertEqual(project.name, "Workspace")
        XCTAssertEqual(project.displayIdentityKey, Fixture.key)
        XCTAssertEqual(project.machines.map { $0.detail.name }, ["Mac mini", "MacBook Pro"])
        XCTAssertEqual(project.machines.map(\.publishedPath), ["~/Projects/mini", nil])
        XCTAssertEqual(project.machines.map { $0.detail.lastUpdatedText },
                       ["Last updated 2 hours ago", "Last updated 1 hour ago"])
        let deploys = try XCTUnwrap(project.machines.first).deploys
        XCTAssertEqual(deploys.map(\.displaySkillSlug), ["alpha", "alpha"])
        XCTAssertEqual(deploys.map(\.platformName), ["Codex", "Cursor"])
        XCTAssertTrue(project.machines[1].deploys.isEmpty)
        XCTAssertEqual(project.machines[0].detail.lastUpdatedText(relativeTo: now.addingTimeInterval(3_600)),
                       "Last updated 3 hours ago")
    }

    func testPublishedTextIsSanitizedAndPathsStayLiteralDisplayText() throws {
        let key = "github.com/exa\u{200B}mple/" + String(repeating: "k", count: 300)
        let path = "~/Projects/../[link](https://example.com)/\u{200F}" + String(repeating: "p", count: 300)
        let state = Fixture.machine(name: "\nMac\u{200B} mini", projects: [
            Fixture.project(key: key, name: "\n" + String(repeating: "N", count: 100), path: path)
        ], deploys: [Fixture.deploy("ski\u{200B}ll", platform: "ag\u{200F}ent", key: key)])
        let project = try XCTUnwrap(RemoteProjectModel.onlyOnOtherMacs(
            states: [state], localProjectIdentityKeys: [], localMachineID: InertMachineIdentity.value
        ).first)
        let row = ListRows.remoteProject(project)

        XCTAssertEqual(project.identityKey, key, "Matching keeps the original identity")
        XCTAssertEqual(row.title, String(repeating: "N", count: 79) + "…")
        XCTAssertEqual(row.line2, "On Mac mini")
        XCTAssertEqual(row.line3, "github.com/example/" + String(repeating: "k", count: 236) + "…")
        let machine = try XCTUnwrap(project.machines.first)
        XCTAssertEqual(machine.publishedPath?.count, 256)
        XCTAssertTrue(machine.publishedPath?.hasPrefix("~/Projects/../[link](https://example.com)/") == true)
        XCTAssertFalse(machine.publishedPath?.contains("\u{200F}") == true)
        XCTAssertEqual(machine.deploys.map(\.displaySkillSlug), ["skill"])
        XCTAssertEqual(machine.deploys.map(\.platformName), ["agent"])
        let unnamed = Fixture.machine(projects: [Fixture.project(key: "repo/Fall\u{200B}back", name: "\n\u{200F}")])
        XCTAssertEqual(RemoteProjectModel.onlyOnOtherMacs(states: [unnamed], localProjectIdentityKeys: [],
                                                        localMachineID: InertMachineIdentity.value).first?.name, "Fallback")
    }
}
