import XCTest
@testable import Pensieve

@MainActor
final class RemovedDeploymentNoticeRestartTests: XCTestCase {
    func testPendingRemovalsAccumulateAcrossLaunchesUntilAcknowledged() throws {
        let h = try RemoteRemovalFixture(skills: ["alpha", "gamma"], persistent: true)
        defer { h.cleanup() }
        try prepare(h)
        try h.pull()
        try h.sync()
        let first = h.platform.removedDeploymentNotice.entries
        XCTAssertEqual(first.count, 1)
        try h.reopen()
        try h.launch()
        XCTAssertEqual(h.platform.removedDeploymentNotice.entries, first)
        try h.pull(slug: "gamma")
        try h.sync()
        let notice = h.platform.removedDeploymentNotice
        XCTAssertEqual(Set(notice.entries.map(\.slug)), ["alpha", "gamma"])
        notice.dismiss(first)
        XCTAssertEqual(notice.entries.map(\.slug), ["gamma"], "OK clears only the entries it showed")
        try h.reopen()
        XCTAssertEqual(h.platform.removedDeploymentNotice.entries.map(\.slug), ["gamma"])
        h.platform.removedDeploymentNotice.dismiss(h.platform.removedDeploymentNotice.entries)
        try h.reopen()
        try h.launch()
        XCTAssertTrue(h.platform.removedDeploymentNotice.entries.isEmpty)
    }

    func testFailedNoticeSaveKeepsSessionMessageWithoutBlockingCleanup() throws {
        let h = try RemoteRemovalFixture(persistent: true)
        defer { h.cleanup() }
        try prepare(h)
        try h.files.createDirectory(at: noticePath(h))
        let id = try h.skill().id
        try h.pull()
        try h.sync()
        XCTAssertEqual(h.platform.removedDeploymentNotice.entries.count, 1)
        try h.assertSettled(id)
        h.convergence.runAfterLaunchIngest()
        XCTAssertEqual(h.platform.removedDeploymentNotice.entries.count, 1)
        try h.reopen()
        XCTAssertTrue(h.platform.removedDeploymentNotice.entries.isEmpty)
    }

    func testFailedClearStaysDismissedThisSessionAndRepeatsOnlyOnNextLaunch() throws {
        let h = try RemoteRemovalFixture(persistent: true)
        defer { h.cleanup() }
        try prepare(h)
        try h.pull()
        try h.sync()
        let notice = h.platform.removedDeploymentNotice, entries = notice.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(h.files.fileExists(at: noticePath(h)), "A pending message must be saved before restart")
        guard h.files.fileExists(at: noticePath(h)) else { return }
        let saved = try h.files.readFile(at: noticePath(h))
        try h.files.deleteFile(at: noticePath(h))
        try h.files.createDirectory(at: noticePath(h))
        notice.dismiss(entries)
        XCTAssertTrue(notice.entries.isEmpty)
        try h.files.deleteDirectory(at: noticePath(h))
        try h.files.writeFile(at: noticePath(h), content: saved)
        h.convergence.runAfterLaunchIngest()
        XCTAssertTrue(notice.entries.isEmpty, "A later pass must not reload the old disk copy")
        try h.reopen()
        try h.launch()
        XCTAssertEqual(h.platform.removedDeploymentNotice.entries, entries)
        h.platform.removedDeploymentNotice.dismiss(entries)
        try h.reopen()
        XCTAssertTrue(h.platform.removedDeploymentNotice.entries.isEmpty)
    }

    func testUnreadableSavedMessageIsReplacedByNextRemoval() throws {
        let h = try RemoteRemovalFixture(persistent: true)
        defer { h.cleanup() }
        try prepare(h)
        try h.files.writeFile(at: noticePath(h), content: "broken JSON")
        try h.reopen()
        XCTAssertTrue(h.platform.removedDeploymentNotice.entries.isEmpty)
        try h.pull()
        try h.sync()
        let entries = h.platform.removedDeploymentNotice.entries
        XCTAssertEqual(entries.count, 1)
        try h.reopen()
        XCTAssertEqual(h.platform.removedDeploymentNotice.entries, entries)
    }

    private func noticePath(_ h: RemoteRemovalFixture) -> String {
        h.paths.appSupportDir + "/removed-deployment-notices.json"
    }

    private func prepare(_ h: RemoteRemovalFixture) throws {
        let project = try h.project("Website", keyed: false)
        try h.deployBefore()
        for slug in try h.store.listSkills() { try h.direct(project: project, agents: [.codex], slug: slug) }
    }
}
