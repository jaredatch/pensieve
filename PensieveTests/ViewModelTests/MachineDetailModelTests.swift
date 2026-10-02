import XCTest
@testable import Pensieve

final class MachineDetailModelTests: XCTestCase {
    func testStalenessFormatting() {
        let publishedAt = Date(timeIntervalSince1970: 1_000_000)
        let model = makeModel(publishedAt: publishedAt, now: { publishedAt.addingTimeInterval(7_200) })

        XCTAssertEqual(model.lastUpdatedText, "Last updated 2 hours ago")
        XCTAssertFalse(model.lastUpdatedText.localizedCaseInsensitiveContains("synced"))
    }

    func testOverlapComputation() {
        let state = makeState(projects: [
            MachineStateProject(identityKey: "github.com/example/here", kind: "git-remote", name: "Here"),
            MachineStateProject(identityKey: "github.com/example/there", kind: "git-remote", name: "There")
        ])
        let model = MachineDetailModel(
            state: state,
            localProjectIdentityKeys: ["github.com/example/here"],
            localMachineID: state.machineID,
            now: { state.publishedAt }
        )

        XCTAssertEqual(model.registeredHereProjects.map(\.identityKey), ["github.com/example/here"])
        XCTAssertEqual(model.onlyOnMachineProjects.map(\.identityKey), ["github.com/example/there"])
        XCTAssertEqual(model.agents.map(\.name), ["Claude Code", "Codex"])
        XCTAssertEqual(model.userDeploys.map(\.skillSlug), ["pdf-tools"])
        XCTAssertEqual(model.projectDeploys.first?.projectName, "There")
        XCTAssertTrue(model.isLocalMachine)
    }

    func testOrphanStateAges() {
        let publishedAt = Date(timeIntervalSince1970: 1_000_000)
        var current = publishedAt.addingTimeInterval(60)
        let model = makeModel(publishedAt: publishedAt, now: { current })
        let initialAge = model.secondsSinceLastUpdated

        current = publishedAt.addingTimeInterval(400 * 24 * 60 * 60)

        XCTAssertGreaterThan(model.secondsSinceLastUpdated, initialAge)
        XCTAssertEqual(model.machineID, makeState().machineID)
        XCTAssertEqual(model.onlyOnMachineProjects.map(\.name), ["Remote Only"])
        XCTAssertTrue(model.lastUpdatedText.lowercased().hasPrefix("last updated"))
    }

    func testPublishedPathDoesNotChangeExistingMachinePresentation() {
        let withoutPath = makeState()
        let withPath = makeState(projects: [
            MachineStateProject(
                identityKey: "github.com/example/remote",
                kind: "git-remote",
                name: "Remote Only",
                path: "~/Projects/Remote"
            )
        ])
        let first = MachineDetailModel(
            state: withoutPath, localProjectIdentityKeys: [], localMachineID: nil,
            now: { withoutPath.publishedAt }
        )
        let second = MachineDetailModel(
            state: withPath, localProjectIdentityKeys: [], localMachineID: nil,
            now: { withPath.publishedAt }
        )

        XCTAssertEqual(first.agents, second.agents)
        XCTAssertEqual(first.registeredHereProjects, second.registeredHereProjects)
        XCTAssertEqual(first.onlyOnMachineProjects, second.onlyOnMachineProjects)
        XCTAssertEqual(first.userDeploys, second.userDeploys)
        XCTAssertEqual(first.projectDeploys, second.projectDeploys)
    }

    func testPublishedMachineNameIsSanitizedForDetailPresentation() {
        let base = makeState()
        let state = MachineState(
            schemaVersion: base.schemaVersion, machineID: base.machineID,
            name: "\n\u{200F}" + String(repeating: "M", count: 100), appVersion: base.appVersion,
            publishedAt: base.publishedAt, agents: base.agents, projects: base.projects,
            userDeploys: base.userDeploys, projectDeploys: base.projectDeploys
        )
        let model = MachineDetailModel(
            state: state, localProjectIdentityKeys: [], localMachineID: nil,
            now: { state.publishedAt }
        )

        XCTAssertEqual(model.name.count, 80)
        XCTAssertTrue(model.name.hasSuffix("…"))
        XCTAssertFalse(model.name.contains("\n"))
        XCTAssertFalse(model.name.contains("\u{200F}"))
    }

    func testPublishedUnknownAgentAndProjectNamesAreSanitized() {
        let projectKey = "github.com/example/project"
        let base = makeState()
        let state = MachineState(
            schemaVersion: base.schemaVersion, machineID: base.machineID,
            name: base.name, appVersion: base.appVersion, publishedAt: base.publishedAt,
            agents: ["z\u{200B}ed"],
            projects: [MachineStateProject(
                identityKey: projectKey, kind: "git-remote", name: "Pro\u{200B}ject"
            )],
            userDeploys: [],
            projectDeploys: [MachineStateProjectDeploy(
                slug: "alpha", platform: "zed", projectKey: projectKey
            )]
        )

        let model = MachineDetailModel(
            state: state, localProjectIdentityKeys: [projectKey], localMachineID: nil,
            now: { state.publishedAt }
        )

        XCTAssertEqual(model.agents.map(\.name), ["zed"])
        XCTAssertEqual(model.registeredHereProjects.map(\.name), ["Project"])
        XCTAssertEqual(model.projectDeploys.map(\.projectName), ["Project"])
    }

    func testPublishedAppVersionAndDeploySlugsAreSanitized() {
        let base = makeState()
        let state = MachineState(
            schemaVersion: base.schemaVersion, machineID: base.machineID,
            name: base.name, appVersion: "1\u{200B}.2", publishedAt: base.publishedAt,
            agents: base.agents, projects: base.projects,
            userDeploys: [MachineStateUserDeploy(slug: "ski\u{200B}ll", platform: "codex")],
            projectDeploys: [MachineStateProjectDeploy(
                slug: "pro\u{200B}ject-skill", platform: "codex",
                projectKey: "github.com/example/remote"
            )]
        )

        let model = MachineDetailModel(
            state: state, localProjectIdentityKeys: [], localMachineID: nil,
            now: { state.publishedAt }
        )

        XCTAssertEqual(model.appVersion, "1.2")
        XCTAssertEqual(model.userDeploys.map(\.displaySkillSlug), ["skill"])
        XCTAssertEqual(model.projectDeploys.map(\.displaySkillSlug), ["project-skill"])
        XCTAssertEqual(model.userDeploys.map(\.skillSlug), ["ski\u{200B}ll"])
        XCTAssertEqual(model.projectDeploys.map(\.skillSlug), ["pro\u{200B}ject-skill"])
    }

    private func makeModel(publishedAt: Date, now: @escaping () -> Date) -> MachineDetailModel {
        MachineDetailModel(
            state: makeState(publishedAt: publishedAt),
            localProjectIdentityKeys: [],
            localMachineID: nil,
            now: now
        )
    }

    private func makeState(
        publishedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        projects: [MachineStateProject] = [
            MachineStateProject(identityKey: "github.com/example/remote", kind: "git-remote", name: "Remote Only")
        ]
    ) -> MachineState {
        MachineState(
            schemaVersion: 1,
            machineID: "5A9C2E31-8F04-4D2B-9C61-0B7A43F1D002",
            name: "Test Mac",
            appVersion: "0.12.0",
            publishedAt: publishedAt,
            agents: ["claudeCode", "codex"],
            projects: projects,
            userDeploys: [MachineStateUserDeploy(slug: "pdf-tools", platform: "claudeCode")],
            projectDeploys: [MachineStateProjectDeploy(
                slug: "swift-conventions",
                platform: "codex",
                projectKey: "github.com/example/there"
            )]
        )
    }
}
