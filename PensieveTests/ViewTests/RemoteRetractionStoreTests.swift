import XCTest
@testable import Pensieve

final class RemoteRetractionStoreTests: XCTestCase {
    private let localID = "11111111-1111-4111-8111-111111111111"
    private let miniID = "22222222-2222-4222-8222-222222222222"

    func testHoldEndsOnlyAfterPublishedDeployDisappears() {
        let store = RemoteRetractionStore()
        let key = wholeMacKey
        store.observe([state(
            publishedAt: Date(timeIntervalSince1970: 20),
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")]
        )])
        store.recordRetraction(key)
        store.observe([state(
            publishedAt: Date(timeIntervalSince1970: 25),
            userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")]
        )])
        XCTAssertEqual(store.held, [key], "a newer publication that still carries the deploy cannot end the hold")

        store.observe([state(publishedAt: Date(timeIntervalSince1970: 30))])
        XCTAssertTrue(store.held.isEmpty)

        store.recordRetraction(key)
        store.recordIntent(key)
        XCTAssertTrue(store.held.isEmpty, "turning the switch on again ends the hold")
    }

    func testHoldWaitsForListedThenAbsentAcknowledgement() {
        let store = RemoteRetractionStore()
        let absent = state()
        let listed = state(userDeploys: [MachineStateUserDeploy(slug: "alpha", platform: "codex")])

        store.observe([absent])
        store.recordRetraction(wholeMacKey)
        store.observe([absent])
        XCTAssertEqual(store.held, [wholeMacKey], "a pre-deploy state cannot acknowledge the retraction")

        store.observe([listed])
        XCTAssertEqual(store.held, [wholeMacKey])
        store.observe([absent])
        XCTAssertTrue(store.held.isEmpty, "listed then absent acknowledges the retraction")
    }

    func testHoldSurvivesStateGapAndAppliesWhenStateReturns() {
        let store = RemoteRetractionStore()
        let projectKey = "github.com/example/project"
        let key = RemoteDeployKey(
            machineID: miniID, skillSlug: "alpha", platformRaw: "codex", projectKey: projectKey
        )
        let listed = state(
            projects: [MachineStateProject(
                identityKey: projectKey, kind: "git-remote", name: "Project"
            )],
            projectDeploys: [MachineStateProjectDeploy(
                slug: "alpha", platform: "codex", projectKey: projectKey
            )]
        )

        store.observe([listed])
        store.recordRetraction(key)
        store.observe([])
        let missing = remoteContent(states: [], holds: store.held)
        XCTAssertTrue(missing.machines.isEmpty)
        XCTAssertTrue(missing.projects.isEmpty)
        XCTAssertEqual(store.held, [key])

        store.observe([listed])
        let returned = remoteContent(states: [listed], holds: store.held)
        XCTAssertFalse(returned.projects[0].platforms[0].isOn)
        XCTAssertTrue(returned.projects[0].platforms[0].isEnabled)
    }

    func testObservingUnchangedHoldsDoesNotInvalidateObservers() {
        let store = RemoteRetractionStore()
        let invalidated = expectation(description: "held changed")
        invalidated.isInverted = true
        withObservationTracking {
            _ = store.held
        } onChange: {
            invalidated.fulfill()
        }

        store.observe([state()])

        wait(for: [invalidated], timeout: 0.01)
    }

    private var wholeMacKey: RemoteDeployKey {
        RemoteDeployKey(machineID: miniID, skillSlug: "alpha", platformRaw: "codex", projectKey: nil)
    }

    private func remoteContent(
        states: [MachineState],
        holds: Set<RemoteDeployKey>
    ) -> DeploymentsPresentation.RemoteContent {
        DeploymentsPresentation.remoteContent(
            skillSlug: "alpha", machineStates: states, localMachineID: localID,
            intents: [], heldRetractions: holds
        )
    }

    private func state(
        publishedAt: Date = Date(timeIntervalSince1970: 10),
        projects: [MachineStateProject] = [],
        userDeploys: [MachineStateUserDeploy] = [],
        projectDeploys: [MachineStateProjectDeploy] = []
    ) -> MachineState {
        MachineState(
            schemaVersion: 1, machineID: miniID, name: "Mini", appVersion: "test",
            publishedAt: publishedAt, agents: ["codex"], projects: projects,
            userDeploys: userDeploys, projectDeploys: projectDeploys
        )
    }
}
