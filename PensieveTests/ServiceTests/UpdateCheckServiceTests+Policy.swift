import XCTest
@testable import Pensieve

@MainActor
extension UpdateCheckServiceTests {
    func testInstallCredentialUsedAndSyncCredentialNeverFallsBack() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.store(token: "sync-decoy", username: "sync", forHost: "github.com")
        try credentials.store(
            token: "install-secret",
            username: "x-access-token",
            forHost: CredentialHost.githubInstall
        )
        insertSkill(slug: "one", repo: "fixture://repo", path: "skills/one")
        git.heads["fixture://repo"] = "head"
        git.trees["skills/one"] = "tree"
        try context.save()

        try makeService(credentials: credentials).checkAll(context: context)

        XCTAssertTrue(git.receivedCredentials.allSatisfy {
            $0 == .httpsToken(username: "x-access-token", token: "install-secret")
        })
        try credentials.delete(forHost: CredentialHost.githubInstall)
        git.receivedCredentials.removeAll()
        try makeService(credentials: credentials).checkAll(context: context)
        XCTAssertTrue(git.receivedCredentials.allSatisfy { $0 == nil })
    }

    func testDriftComputationAndFrequencyGating() throws {
        XCTAssertFalse(UpdateCheckService.driftedLocally(
            currentContentHash: "sha256:same",
            installedContentHash: "sha256:same"
        ))
        XCTAssertTrue(UpdateCheckService.driftedLocally(
            currentContentHash: "sha256:new",
            installedContentHash: "sha256:old"
        ))

        let skill = insertSkill(slug: "drift", repo: "fixture://repo", path: "skills/drift")
        let directory = tempDir + "/store/skills/drift"
        try fileService.writeFile(at: directory + "/SKILL.md", content: "pristine")
        let hasher = makeContentHasher()
        var origin = try XCTUnwrap(skill.installedOrigin); origin.contentHash = try hasher.stableContentHash(at: directory)
        skill.installedOrigin = origin
        let service = makeService()
        XCTAssertFalse(try service.driftedLocally(skill: skill))
        try fileService.writeFile(at: directory + "/SKILL.md", content: "locally edited")
        XCTAssertTrue(try service.driftedLocally(skill: skill))
        try fileService.deleteFile(at: directory + "/SKILL.md"); XCTAssertThrowsError(
            try service.driftedLocally(skill: skill)) {
            XCTAssertEqual($0 as? UpdateCheckError, .unsafeSkillDirectory("drift"))
        }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertFalse(UpdateCheckSchedule.isDue(frequency: .off, lastAutoCheckAt: nil, now: now))
        XCTAssertTrue(UpdateCheckSchedule.isDue(frequency: .daily, lastAutoCheckAt: nil, now: now))
        XCTAssertFalse(UpdateCheckSchedule.isDue(
            frequency: .daily,
            lastAutoCheckAt: now.addingTimeInterval(-(24 * 60 * 60) + 1),
            now: now
        ))
        XCTAssertTrue(UpdateCheckSchedule.isDue(
            frequency: .daily,
            lastAutoCheckAt: now.addingTimeInterval(-(24 * 60 * 60)),
            now: now
        ))
        XCTAssertFalse(UpdateCheckSchedule.isDue(
            frequency: .weekly,
            lastAutoCheckAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 1),
            now: now
        ))
        XCTAssertTrue(UpdateCheckSchedule.isDue(
            frequency: .weekly,
            lastAutoCheckAt: now.addingTimeInterval(-(7 * 24 * 60 * 60)),
            now: now
        ))
    }
}
