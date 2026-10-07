import XCTest
@testable import Pensieve

final class ProjectListModelTests: XCTestCase {
    private typealias Fixture = RemoteProjectTestSupport

    func testLocalRowsKeepPresentationAndRemovalTargetWhenPublishedElsewhere() throws {
        let local = Project(name: "Local Workspace", path: "/Users/test/Projects/workspace")
        local.identityKey = Fixture.key
        local.identityKind = "remote"
        let index = DeployIndex(records: [DeployStateRecord(
            slug: "local-skill", platform: "codex", scope: "project", projectIdentityKey: Fixture.key,
            artifactPath: "/Users/test/Projects/workspace/agents/local-skill.md", recordedAt: "original"
        )])
        let model = list(projects: [local], states: [Fixture.machine(deploys: [Fixture.deploy("remote-skill")])],
                         deployIndex: index)
        let row = try XCTUnwrap(model.rows.first)

        XCTAssertEqual(model.totalCount, 1)
        XCTAssertEqual(row.selection, .project(local.id))
        XCTAssertTrue(row.localProject === local)
        XCTAssertEqual(row.presentation, ListRowModel(
            title: "Local Workspace", trailingText: "1 skill", line2: "~/Projects/workspace",
            line3: Fixture.key, line2TruncatesMiddle: true
        ))
    }

    func testRemoteRowsMergeByIdentityAndCountDistinctProjectSkills() throws {
        let mini = Fixture.machine(id: "a-mini", projects: [Fixture.project(), Fixture.project()], deploys: [
            Fixture.deploy("alpha"), Fixture.deploy("alpha", platform: "cursor"),
            Fixture.deploy("unrelated", key: "other")
        ])
        let laptop = Fixture.machine(id: "laptop", name: "MacBook Pro", projects: [
            Fixture.project(name: "Laptop Name"), Fixture.project(key: "other", name: "Workspace")
        ], deploys: [Fixture.deploy("alpha"), Fixture.deploy("beta")])
        let model = list(states: [laptop, mini])
        let row = try XCTUnwrap(model.rows.first { $0.selection == .remoteProject(Fixture.key) })

        XCTAssertEqual(model.totalCount, 2, "Different identities with the same name stay separate")
        XCTAssertEqual(row.presentation, ListRowModel(
            title: "Workspace", trailingText: "2 skills", line2: "On Mac mini and MacBook Pro", line3: Fixture.key
        ))
        XCTAssertNil(row.localProject, "A remote row has no local removal target")
        XCTAssertEqual(list(states: [mini, laptop]).rows.map(\.presentation), model.rows.map(\.presentation))
        XCTAssertEqual(list(states: [mini]).rows.first?.presentation.line2, "On Mac mini")
        XCTAssertEqual(list(states: [mini]).rows.first?.presentation.trailingText, "1 skill")
        let third = Fixture.machine(id: "studio", name: "Studio")
        XCTAssertEqual(list(states: [third, laptop, mini]).rows.first?.presentation.line2,
                       "On Mac mini, MacBook Pro, and Studio")
        let marker = Fixture.machine(projects: [Fixture.project(key: "marker-id", kind: "marker")])
        XCTAssertEqual(list(states: [marker]).rows.first?.presentation.line3, "Marker identity")
        let unknown = Fixture.machine(projects: [Fixture.project(kind: "future-kind")])
        XCTAssertEqual(list(states: [unknown]).rows.first?.presentation.line3, "Unknown identity")
        let localMarker = Project(name: "Local", path: "/local")
        localMarker.identityKind = "marker"
        XCTAssertEqual(list(projects: [localMarker]).rows.first?.presentation.line3, "Local marker identity")
        localMarker.identityKind = "future-kind"
        XCTAssertEqual(list(projects: [localMarker]).rows.first?.presentation.line3, "Identity pending")
    }

    func testEqualTitlesSortLocalBeforeRemoteThenByStableIdentity() throws {
        let first = Project(name: "Workspace", path: "/first")
        first.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        first.identityKey = "local-a"
        let second = Project(name: "Workspace", path: "/second")
        second.id = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        second.identityKey = "local-b"
        let remoteA = Fixture.machine(id: "a", projects: [Fixture.project(key: "remote-a")])
        let remoteB = Fixture.machine(id: "b", name: "Studio", projects: [Fixture.project(key: "remote-b")])
        let expected: [EntitySelection] = [
            .project(first.id), .project(second.id), .remoteProject("remote-a"), .remoteProject("remote-b")
        ]
        for projects in [[second, first], [first, second]] {
            for states in [[remoteB, remoteA], [remoteA, remoteB]] {
                XCTAssertEqual(list(projects: projects, states: states).rows.map(\.selection), expected)
            }
        }
    }

    func testCachedRemoteRowsHideNewLocalRegistrationBeforeRefresh() {
        var cache = RemoteProjectsModel()
        cache.refresh(.init(machineStates: [Fixture.machine()], localProjectIdentityKeys: [],
                            localMachineID: InertMachineIdentity.value), now: { Fixture.publishedAt })
        let local = Project(name: "Registered name", path: "/Users/test/Projects/workspace")
        local.identityKey = Fixture.key
        local.identityKind = "remote"
        let registered = ProjectListModel(projects: [local], remoteProjects: cache.projects, deployIndex: .empty,
                                          homeDirectory: "/Users/test", searchText: "")

        XCTAssertEqual(cache.projects.map(\.identityKey), [Fixture.key], "The cache still has the now-local key")
        XCTAssertEqual(registered.rows.map(\.selection), [.project(local.id)])
        XCTAssertEqual(registered.subtitle, "1 project")
        XCTAssertTrue(registered.rows.first?.localProject === local)
        let search = ProjectListModel(projects: [local], remoteProjects: cache.projects, deployIndex: .empty,
                                      homeDirectory: "/Users/test", searchText: "Workspace")
        XCTAssertTrue(search.rows.isEmpty, "The cached remote name must also leave search immediately")
        XCTAssertEqual(search.subtitle, "0 of 1 project")
        let unregistered = ProjectListModel(projects: [], remoteProjects: cache.projects, deployIndex: .empty,
                                            homeDirectory: "/Users/test", searchText: "")
        XCTAssertEqual(unregistered.rows.map(\.selection), [.remoteProject(Fixture.key)])
    }

    func testLocalIdentityAndOwnStateExcludeRemoteRows() {
        let local = Project(name: "Local name differs", path: "/local")
        local.identityKey = Fixture.key
        let keyless = Project(name: "Workspace", path: "/keyless")
        let own = Fixture.machine(id: InertMachineIdentity.value, projects: [
            Fixture.project(key: "removed-local", name: "Removed")
        ])
        let other = Fixture.machine(projects: [Fixture.project(), Fixture.project(key: "different-key")])
        let model = list(projects: [local, keyless], states: [own, other])

        XCTAssertEqual(Set(model.rows.map(\.selection)),
                       [.project(local.id), .project(keyless.id), .remoteProject("different-key")])
        XCTAssertTrue(list(states: [own]).rows.isEmpty, "An old own-state registration must not return")
        XCTAssertTrue(RemoteProjectModel.onlyOnOtherMacs(states: [own, other], localProjectIdentityKeys: [],
                                                       localMachineID: nil).isEmpty)
    }

    func testSearchSubtitleAndEmptyStateIncludeLocalAndRemoteRows() {
        let local = Project(name: "Local Workspace", path: "/local")
        let remote = Fixture.machine()
        let all = list(projects: [local], states: [remote])
        XCTAssertEqual(all.subtitle, "2 projects")
        XCTAssertEqual(list(projects: [local], states: [remote], search: "  WORKSPACE  ").rows.count, 2)
        let filtered = list(projects: [local], states: [remote], search: "local")
        XCTAssertEqual(filtered.rows.map(\.selection), [.project(local.id)])
        XCTAssertEqual(filtered.subtitle, "1 of 2 projects")
        XCTAssertEqual(list(states: [remote], search: "Work").subtitle, "1 project")
        XCTAssertFalse(list(states: [remote]).rows.isEmpty)
        XCTAssertFalse(list(projects: [local]).rows.isEmpty)
        let missing = list(states: [remote], search: "missing")
        XCTAssertTrue(missing.rows.isEmpty)
        XCTAssertEqual(missing.subtitle, "0 of 1 project")
        let empty = list()
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(empty.subtitle, "No projects")
    }

    private func list(projects: [Project] = [], states: [MachineState] = [],
                      deployIndex: DeployIndex = .empty, search: String = "") -> ProjectListModel {
        ProjectListModel(
            projects: projects,
            remoteProjects: RemoteProjectModel.onlyOnOtherMacs(
                states: states, localProjectIdentityKeys: Set(projects.compactMap(\.identityKey)),
                localMachineID: InertMachineIdentity.value
            ),
            deployIndex: deployIndex, homeDirectory: "/Users/test", searchText: search
        )
    }
}
