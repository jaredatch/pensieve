import Foundation
import SwiftData
import XCTest
@testable import Pensieve

@MainActor
final class RemoteSkillRemovalTests: XCTestCase {
    func testARenameOnAnotherMacRemovesTheOldNamesProjectLinksAndRulesHere() throws {
        let h = try RemoteRemovalFixture(skills: ["alpha", "gamma"])
        defer { h.cleanup() }
        let projectA = try h.project("A"), projectB = try h.project("B"), projectC = try h.project("C", keyed: false)
        h.intent(project: projectA)
        h.intent("gamma", project: projectA)
        h.intent(agents: [.cursor])
        try h.deployBefore()
        try h.direct(project: projectC, agents: [.claudeCode, .cursor])
        try h.assertBefore(project: projectA)
        try h.assertBefore(project: projectA, slug: "gamma")
        try h.assertBefore([.cursor])
        try h.assertBefore([.claudeCode, .cursor], project: projectC, ledger: .direct)
        let oldID = try h.skill().id, gammaID = try h.skill("gamma").id
        let gammaPaths = RemoteRemovalFixture.agents.map { h.artifact($0, project: "A", slug: "gamma") }
        let gammaDisk = try h.disk(gammaPaths)
        let gammaState = try h.state.read().records.filter { $0.slug == "gamma" }
        let gammaHistory = try h.history(gammaID).map(\.id).sorted { $0.uuidString < $1.uuidString }
        let teammate = projectB.path + "/.cursor/rules/alpha.mdc"
        try h.files.writeData(at: teammate, data: h.files.readData(at: h.artifact(.cursor, project: "A")))
        XCTAssertTrue(CursorMDC.hasOwnershipMark(in: try h.files.readData(at: teammate)))
        let folder = h.artifact(.claudeCode, project: "C")
        try h.files.deleteFile(at: folder)
        try h.files.writeFile(at: folder + "/mine.txt", content: "Keep my folder")
        let personalRule = h.artifact(.cursor, project: "C")
        try h.files.writeFile(at: personalRule, content: "My own rewritten rule\n")
        let untouched = try h.disk([teammate, folder, personalRule])
        try h.pull(rename: true)
        try h.sync()
        try h.assertAbsent(RemoteRemovalFixture.agents, project: "A")
        try h.assertAbsent([.cursor])
        XCTAssertEqual(try h.files.symlinkTarget(at: h.artifact(.claudeCode, project: "A", slug: "beta-two")),
                       h.paths.skillsDir + "/beta-two")
        XCTAssertEqual(try h.files.symlinkTarget(at: h.artifact(.codex, project: "A", slug: "beta-two")),
                       h.paths.skillsDir + "/beta-two/SKILL.md")
        for project in ["A", nil] {
            XCTAssertTrue(CursorMDC.hasOwnershipMark(in: try h.files.readData(at: h.artifact(.cursor,
                project: project, slug: "beta-two"))))
        }
        XCTAssertEqual(try h.disk(gammaPaths), gammaDisk)
        XCTAssertEqual(try h.state.read().records.filter { $0.slug == "gamma" }, gammaState)
        XCTAssertEqual(try h.history(gammaID).map(\.id).sorted { $0.uuidString < $1.uuidString }, gammaHistory)
        XCTAssertEqual(try h.disk([teammate, folder, personalRule]), untouched)
        try h.assertSettled(oldID)
    }

    func testADeleteThatArrivedWhilePensieveWasClosedRemovesItsProjectLinksAndRulesAtLaunch() throws {
        let h = try RemoteRemovalFixture()
        defer { h.cleanup() }
        let projectA = try h.project("A"), projectD = try h.project("D"), projectC = try h.project("C", keyed: false)
        try h.category(project: projectA)
        h.intent(project: projectD, agents: [.claudeCode, .cursor])
        try h.deployBefore()
        try h.direct(project: projectC, agents: [.claudeCode])
        try h.assertBefore(project: projectA, ledger: .category)
        try h.assertBefore([.claudeCode, .cursor], project: projectD)
        try h.assertBefore([.claudeCode], project: projectC, ledger: .direct)
        let oldID = try h.skill().id
        let ownRule = h.artifact(.cursor, project: "D")
        try h.files.writeFile(at: ownRule, content: "User rewrote this rule\n")
        let personal = [projectA, projectD, projectC].map { $0.path + "/.cursor/rules/mine.mdc" }
        for path in personal { try h.files.writeFile(at: path, content: "Personal rule: " + path) }
        let untouched = try h.disk(personal + [ownRule])
        try h.pull()
        try h.launch {
            XCTAssertFalse(try h.state.read().records.contains { $0.slug == "alpha" })
            XCTAssertEqual(try h.history(oldID).count, 6)
        }
        try h.assertAbsent(RemoteRemovalFixture.agents, project: "A")
        try h.assertAbsent([.claudeCode], project: "C")
        try h.assertAbsent([.claudeCode], project: "D")
        XCTAssertEqual(try h.disk(personal + [ownRule]), untouched)
        try h.assertSettled(oldID)
        try assertSecondPassUnchanged(h, oldID: oldID, roots: h.allDeployRoots(["A", "C", "D"]))
    }

    func testCleanupWaitsForAMissingProjectFolderAndFinishesWhenItIsBack() throws {
        let h = try RemoteRemovalFixture(skills: ["alpha", "gamma"], persistent: true)
        defer { h.cleanup() }
        try prepareMissingProject(h)
        let oldID = try h.skill().id
        let offline = h.root + "/offline", projectPath = h.root + "/A"
        try h.files.replaceItem(at: offline, with: projectPath)
        let offlineBefore = try h.disk([offline])
        try h.pull()
        try h.sync()
        try assertWaiting(h, oldID: oldID, offline: offline, expected: offlineBefore)
        try h.reopen()
        try h.launch()
        try assertWaiting(h, oldID: oldID, offline: offline, expected: offlineBefore)
        let link = offline + "/.claude/skills/alpha"
        try h.files.createSymlink(at: link, pointingTo: h.paths.skillsDir + "/gamma")
        try h.reopen()
        try h.files.replaceItem(at: projectPath, with: offline)
        try h.launch()
        try h.assertAbsent([.codex, .cursor], project: "A")
        XCTAssertEqual(try h.files.symlinkTarget(at: h.artifact(.claudeCode, project: "A")), h.paths.skillsDir + "/gamma")
        try h.assertSettled(oldID)
    }

    func testDeletingASkillHereThenStartingUpChangesNothingInYourProjects() async throws {
        let h = try RemoteRemovalFixture()
        defer { h.cleanup() }
        let projectA = try h.project("A"), projectC = try h.project("C", keyed: false)
        h.intent(project: projectA)
        try h.deployBefore()
        try h.direct(project: projectC, agents: [.cursor])
        try h.assertBefore(project: projectA)
        try h.assertBefore([.cursor], project: projectC, ledger: .direct)
        let oldID = try h.skill().id
        let ownRule = h.artifact(.cursor, project: "C")
        try h.files.writeFile(at: ownRule, content: "My own rule, kept by Delete\n")
        let ownBytes = try h.files.readData(at: ownRule)
        let library = h.paths.makeLibrary(notifier: {})
        XCTAssertTrue(SkillDeletionFlow.delete(skill: try h.skill(), library: library, platformVM: h.platform,
            projects: [projectA, projectC], context: h.context))
        await library.manifestSaves?.waitUntilIdle()
        try h.assertAbsent(RemoteRemovalFixture.agents, project: "A")
        XCTAssertEqual(try h.files.readData(at: ownRule), ownBytes)
        XCTAssertEqual(try h.history(oldID).count, 4)
        let roots = h.allDeployRoots(["A", "C"]), afterDelete = try h.disk(h.allDeployRoots(["A", "C"]))
        try h.launch()
        XCTAssertEqual(try h.disk(roots), afterDelete)
        try h.assertSettled(oldID)
        try assertSecondPassUnchanged(h, oldID: oldID, roots: roots)
    }
}

private extension RemoteSkillRemovalTests {
    func prepareMissingProject(_ h: RemoteRemovalFixture) throws {
        let project = try h.project("A")
        h.intent(project: project)
        try h.deployBefore()
        try h.assertBefore(project: project)
    }

    func assertWaiting(_ h: RemoteRemovalFixture, oldID: UUID, offline: String, expected: [String: String]) throws {
        XCTAssertEqual(try h.disk([offline]), expected)
        XCTAssertEqual(try h.history(oldID).count, 3)
        try h.assertNoWaiting()
    }

    func assertSecondPassUnchanged(_ h: RemoteRemovalFixture, oldID: UUID, roots: [String]) throws {
        let disk = try h.disk(roots)
        let records = try h.state.read().records
        let historyIDs = try h.context.fetch(FetchDescriptor<DeployRecord>()).map(\.id)
        h.convergence.runAfterLaunchIngest()
        XCTAssertEqual(try h.disk(roots), disk)
        XCTAssertEqual(try h.state.read().records, records)
        XCTAssertEqual(try h.context.fetch(FetchDescriptor<DeployRecord>()).map(\.id), historyIDs)
        try h.assertSettled(oldID)
    }
}
