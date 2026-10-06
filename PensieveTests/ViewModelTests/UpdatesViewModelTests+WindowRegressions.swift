import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testBrokenUnrelatedSkillDoesNotFailPinnedPreview() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let broken = Skill(name: "Broken", directoryName: "missing-folder")
        broken.installedOrigin = fixture.skill.installedOrigin
        broken.updateAvailable = true
        broken.upstreamCommit = fixture.skill.upstreamCommit
        broken.upstreamTree = fixture.skill.upstreamTree
        broken.upstreamCommitDate = fixture.skill.upstreamCommitDate
        context.insert(broken)
        try context.save()
        let (window, _) = makeRealWindow(fixture: fixture)
        window.open(skillID: fixture.skill.id, context: context)
        await windowLoaded(window)
        XCTAssertTrue(window.canUpdate, "An unrelated broken folder must never enter this preview's drift check")
    }

}
