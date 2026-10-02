import XCTest
@testable import Pensieve

final class DeploymentsMachinePresentationTests: XCTestCase {
    private let localID = "11111111-1111-4111-8111-111111111111"
    private let miniID = "22222222-2222-4222-8222-222222222222"
    private let studioID = "33333333-3333-4333-8333-333333333333"

    func testOtherMachinesAreNamedOrderedAndUseTheirKnownAgents() {
        let own = state(id: localID, name: "This Mac", agents: ["hermes"])
        let zeta = state(id: miniID, name: "Zeta", agents: ["unknown", "codex", "claudeCode"])
        let alpha = state(id: studioID, name: "Alpha", agents: [])

        let content = remoteContent(states: [zeta, own, alpha])

        XCTAssertEqual(content.machines.map(\.name), ["Alpha", "Zeta"])
        XCTAssertEqual(content.machines[0].description,
                       "Every project on Alpha. Changes apply the next time it syncs.")
        XCTAssertTrue(content.machines[0].rows.isEmpty)
        XCTAssertEqual(content.machines[1].rows.map(\.platform), [.claudeCode, .codex])
        XCTAssertFalse(content.machines.contains { $0.id == localID })
    }

    func testRemoteWholeMacRowsReadIntentPublishedAndOffInOrder() {
        let remote = state(
            id: miniID,
            name: "Mini",
            agents: ["claudeCode", "grok", "codex"],
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")]
        )
        let intents: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: miniID, platform: .claudeCode, projectKey: nil)
        ]

        let rows = remoteContent(states: [remote], intents: intents).machines[0].rows

        assertRow(rows[0], on: true, enabled: true, note: nil)
        assertRow(rows[1], on: false, enabled: true, note: nil)
        assertRow(rows[2], on: true, enabled: false, note: "Turned on from Mini")
    }

    func testRemoteProjectsUseCaptionsOrderAdmissionAndThreeWayState() throws {
        let projects = [
            MachineStateProject(identityKey: "github.com/example/zeta", kind: "git-remote",
                                name: "Shared", path: "~/Projects/zeta"),
            MachineStateProject(identityKey: " invalid", kind: "git-remote", name: "Hidden", path: nil),
            MachineStateProject(identityKey: "github.com/example/fallback", kind: "git-remote",
                                name: "\n", path: nil)
        ]
        let remote = state(
            id: miniID,
            name: "Mini",
            agents: ["claudeCode", "grok", "cursor", "codex", "openClaw"],
            projects: projects,
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "claudeCode")],
            projectDeploys: [MachineStateProjectDeploy(
                slug: "alpha", platform: "cursor", projectKey: "github.com/example/zeta"
            )]
        )
        let intents: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: miniID, platform: .codex, projectKey: "github.com/example/zeta")
        ]
        let content = remoteContent(states: [remote], intents: intents)

        XCTAssertEqual(content.projects.map(\.name), ["Shared", "fallback"])
        let row = try XCTUnwrap(content.projects.first { $0.name == "Shared" })
        XCTAssertEqual(row.caption, "Mini · ~/Projects/zeta")
        XCTAssertEqual(row.platforms.map(\.platform), [.claudeCode, .grok, .cursor, .codex])
        assertRow(row.platforms[0], on: true, enabled: false, note: "On for every project on Mini")
        assertRow(row.platforms[1], on: false, enabled: true, note: nil)
        assertRow(row.platforms[2], on: true, enabled: false, note: "Turned on from Mini")
        assertRow(row.platforms[3], on: true, enabled: true, note: nil)
        XCTAssertEqual(content.projects.first { $0.name == "fallback" }?.caption, "Mini")
    }

    func testHeldWholeMacRetractionReturnsProjectToItsOwnIntent() {
        let projectKey = "github.com/example/project"
        let remote = state(
            id: miniID,
            name: "Mini",
            agents: ["codex"],
            projects: [MachineStateProject(identityKey: projectKey, kind: "git-remote", name: "Project")],
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")]
        )
        let intents: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: miniID, platform: .codex, projectKey: projectKey)
        ]
        let hold: Set<RemoteDeployKey> = [
            .init(machineID: miniID, skillSlug: "alpha", platformRaw: "codex", projectKey: nil)
        ]

        let content = remoteContent(states: [remote], intents: intents, holds: hold)

        assertRow(content.machines[0].rows[0], on: false, enabled: true, note: nil)
        assertRow(content.projects[0].platforms[0], on: true, enabled: true, note: nil)
    }

    func testStandingIntentWinsOverRetractionHold() {
        let remote = state(id: miniID, name: "Mini", agents: ["codex"])
        let intent: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: miniID, platform: .codex, projectKey: nil)
        ]
        let hold: Set<RemoteDeployKey> = [
            .init(machineID: miniID, skillSlug: "alpha", platformRaw: "codex", projectKey: nil)
        ]

        assertRow(
            remoteContent(states: [remote], intents: intent, holds: hold).machines[0].rows[0],
            on: true, enabled: true, note: nil
        )
    }

    func testHeldProjectRetractionAndFreshSessionPresentation() {
        let projectKey = "github.com/example/project"
        let deploy = MachineStateProjectDeploy(slug: "alpha", platform: "codex", projectKey: projectKey)
        let remote = state(
            id: miniID, name: "Mini", agents: ["codex"],
            publishedAt: Date(timeIntervalSince1970: 9_999),
            projects: [MachineStateProject(identityKey: projectKey, kind: "git-remote", name: "Project")],
            projectDeploys: [deploy]
        )
        let key = RemoteDeployKey(
            machineID: miniID, skillSlug: "alpha", platformRaw: "codex", projectKey: projectKey
        )

        var content = remoteContent(states: [remote], holds: [key])
        assertRow(content.projects[0].platforms[0], on: false, enabled: true, note: nil)

        let intent: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: miniID, platform: .codex, projectKey: projectKey)
        ]
        content = remoteContent(states: [remote], intents: intent, holds: [key])
        assertRow(content.projects[0].platforms[0], on: true, enabled: true, note: nil)

        let freshSession = RemoteRetractionStore()
        content = remoteContent(states: [remote], holds: freshSession.held)
        assertRow(content.projects[0].platforms[0], on: true, enabled: false, note: "Turned on from Mini")
    }

    func testWholeMacIntentProducesInheritedProjectRowsAndCollapsedMarks() {
        let projectKey = "github.com/example/project"
        let remote = state(
            id: miniID, name: "Mini", agents: ["claudeCode", "codex"],
            projects: [MachineStateProject(identityKey: projectKey, kind: "git-remote", name: "Project")]
        )
        let intents: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: miniID, platform: .codex, projectKey: nil)
        ]

        let row = remoteContent(states: [remote], intents: intents).projects[0]

        assertRow(row.platforms[0], on: false, enabled: true, note: nil)
        assertRow(row.platforms[1], on: true, enabled: false, note: "On for every project on Mini")
        XCTAssertEqual(row.deployedPlatforms, [.codex])
        XCTAssertNil(row.summary)

        let offRow = remoteContent(states: [remote]).projects[0]
        XCTAssertTrue(offRow.deployedPlatforms.isEmpty)
        XCTAssertEqual(offRow.summary, "Not deployed")
    }

    func testNoLocalIdentityOrIntentOnlyMachineProducesNoRemoteContent() {
        let remote = state(id: miniID, name: "Mini", agents: ["codex"])
        let intent: Set<DeploymentsPresentation.IntentFact> = [
            .init(machineID: studioID, platform: .codex, projectKey: nil)
        ]
        XCTAssertEqual(
            DeploymentsPresentation.remoteContent(
                skillSlug: "alpha", machineStates: [remote], localMachineID: nil,
                intents: intent, heldRetractions: []
            ),
            .init(machines: [], projects: [])
        )
        let content = remoteContent(states: [], intents: intent)
        XCTAssertTrue(content.machines.isEmpty)
        XCTAssertTrue(content.projects.isEmpty)
    }

    func testProjectRowsSortByNameThenThisMacThenRemoteMacName() {
        let local = Project(name: "Shared", path: "/Users/test/Shared")
        let localRows = DeploymentsPresentation.projectRows(
            projects: [local], projectPlatforms: [], macStatus: [:], projectStatus: [:],
            homeDirectory: "/Users/test", prefixesThisMac: true
        )
        let a = state(
            id: miniID, name: "Alpha Mac", agents: [],
            projects: [MachineStateProject(
                identityKey: "github.com/example/alpha", kind: "git-remote", name: "Shared", path: "~/Alpha"
            )]
        )
        let z = state(
            id: studioID, name: "Zulu Mac", agents: [],
            projects: [MachineStateProject(
                identityKey: "github.com/example/zulu", kind: "git-remote", name: "Shared", path: "~/Zulu"
            )]
        )
        let remote = remoteContent(states: [z, a]).projects

        let sorted = DeploymentsPresentation.sortedProjectRows(localRows + remote)

        XCTAssertEqual(sorted.map(\.caption), [
            "This Mac · ~/Shared", "Alpha Mac · ~/Alpha", "Zulu Mac · ~/Zulu"
        ])
    }

    func testProjectRowsKeepLocalizedStandardOrderWithAndWithoutRemoteMachines() {
        let ten = Project(name: "Project 10", path: "/Users/test/10")
        let two = Project(name: "Project 2", path: "/Users/test/2")
        let localRows = DeploymentsPresentation.projectRows(
            projects: [ten, two], projectPlatforms: [], macStatus: [:], projectStatus: [:],
            homeDirectory: "/Users/test", prefixesThisMac: false
        )
        XCTAssertEqual(DeploymentsPresentation.sortedProjectRows(localRows).map(\.name), ["Project 2", "Project 10"])

        let remote = state(
            id: miniID, name: "Mini", agents: [],
            projects: [MachineStateProject(
                identityKey: "github.com/example/remote", kind: "git-remote", name: "Project 2"
            )]
        )
        let prefixedLocals = DeploymentsPresentation.projectRows(
            projects: [ten, two], projectPlatforms: [], macStatus: [:], projectStatus: [:],
            homeDirectory: "/Users/test", prefixesThisMac: true
        )
        let sorted = DeploymentsPresentation.sortedProjectRows(
            prefixedLocals + remoteContent(states: [remote]).projects
        )
        XCTAssertEqual(sorted.map(\.name), ["Project 2", "Project 2", "Project 10"])
        XCTAssertEqual(sorted.prefix(2).map(\.caption), ["This Mac · ~/2", "Mini"])
    }

    private func remoteContent(
        states: [MachineState],
        intents: Set<DeploymentsPresentation.IntentFact> = [],
        holds: Set<RemoteDeployKey> = []
    ) -> DeploymentsPresentation.RemoteContent {
        DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: states, localMachineID: localID,
            intents: intents, heldRetractions: holds
        )
    }

    private func state(
        id: String,
        name: String,
        agents: [String],
        publishedAt: Date = Date(timeIntervalSince1970: 10),
        projects: [MachineStateProject] = [],
        userDeploys: [MachineStateUserDeploy] = [],
        projectDeploys: [MachineStateProjectDeploy] = []
    ) -> MachineState {
        MachineState(
            schemaVersion: 1, machineID: id, name: name, appVersion: "test",
            publishedAt: publishedAt, agents: agents, projects: projects,
            userDeploys: userDeploys, projectDeploys: projectDeploys
        )
    }

    private func assertRow(
        _ row: DeploymentsPresentation.PlatformRow,
        on: Bool,
        enabled: Bool,
        note: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(row.isOn, on, file: file, line: line)
        XCTAssertEqual(row.isEnabled, enabled, file: file, line: line)
        XCTAssertEqual(row.note, note, file: file, line: line)
    }
}

extension DeploymentsMachinePresentationTests {
    func testTwentyThousandRemoteProjectsAndDeploysBuildWithinBudget() {
        let count = 20_000
        let projects = (0..<count).map { index in
            MachineStateProject(
                identityKey: "github.com/example/project-\(index)",
                kind: "git-remote",
                name: "Project \(index)"
            )
        }
        let deploys = (0..<count).map { index in
            MachineStateProjectDeploy(
                slug: "alpha",
                platform: "codex",
                projectKey: "github.com/example/project-\(index)"
            )
        }
        let remote = state(
            id: miniID,
            name: "Mini",
            agents: ["codex"],
            projects: projects,
            projectDeploys: deploys
        )
        let clock = ContinuousClock()
        var content = DeploymentsPresentation.RemoteContent(machines: [], projects: [])

        let elapsed = clock.measure {
            content = remoteContent(states: [remote])
        }

        XCTAssertEqual(content.projects.count, count)
        XCTAssertEqual(content.projects.last?.platforms.first?.isOn, true)
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testEmptyAndUnknownOnlyAgentListsUseTheEmptySectionCopy() {
        for agents in [[], ["grok-unknown"]] {
            let content = remoteContent(states: [state(id: miniID, name: "Mini", agents: agents)])

            XCTAssertTrue(content.machines[0].rows.isEmpty)
            XCTAssertEqual(content.machines[0].emptyText, "No supported agents detected")
        }

        let supported = remoteContent(states: [state(id: miniID, name: "Mini", agents: ["codex"])])
        XCTAssertFalse(supported.machines[0].rows.isEmpty)
        XCTAssertNil(supported.machines[0].emptyText)
    }

    func testInvisibleMachineProjectAndFallbackNamesUseVisibleFallbacks() {
        let invisible = "\u{200D}\u{200C}"
        let remote = state(
            id: miniID, name: invisible, agents: [],
            projects: [
                MachineStateProject(
                    identityKey: "github.com/example/visible-fallback", kind: "git-remote", name: invisible
                )
            ]
        )

        let content = remoteContent(states: [remote])

        XCTAssertEqual(content.machines[0].name, "Mac")
        XCTAssertEqual(content.machines[0].description, "Every project on Mac. Changes apply the next time it syncs.")
        XCTAssertEqual(content.projects.map(\.name), ["visible-fallback"])
        XCTAssertEqual(Set(content.projects.map(\.caption)), ["Mac"])
    }

    func testMachineNamesUseLocalizedStandardOrder() {
        let ten = state(id: miniID, name: "Mac 10", agents: [])
        let two = state(id: studioID, name: "Mac 2", agents: [])

        XCTAssertEqual(remoteContent(states: [ten, two]).machines.map(\.name), ["Mac 2", "Mac 10"])
    }
}
