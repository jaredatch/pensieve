import SwiftData
import XCTest
@testable import Pensieve

extension UpdatesViewModelTests {
    func testRowSurfacesUnavailableSourceForUnparseableOrigin() throws {
        let skill = insertUpdateSkill(slug: "unparseable-origin")
        var origin = try XCTUnwrap(skill.installedOrigin)
        origin.repo = "not a GitHub repository"
        skill.installedOrigin = origin

        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)

        XCTAssertEqual(row.repositoryDisplay, "")
        XCTAssertEqual(row.repositoryPath, "skills/unparseable-origin")
        XCTAssertNil(row.compareURL)
    }

    func testCompareURLRejectsNonSHACommitCoordinates() throws {
        let skill = insertUpdateSkill(slug: "compare-shape")
        let origin = try XCTUnwrap(skill.installedOrigin)

        XCTAssertNotNil(UpdatesViewModel.compareURL(
            origin: origin,
            upstreamCommit: String(repeating: "a", count: 40)
        ))
        var malicious = origin
        malicious.installedCommit = "../../../evil/repo"
        XCTAssertNil(UpdatesViewModel.compareURL(
            origin: malicious,
            upstreamCommit: String(repeating: "b", count: 40)
        ))
        XCTAssertNil(UpdatesViewModel.compareURL(
            origin: origin,
            upstreamCommit: String(repeating: "ａ", count: 40)
        ))
    }

    func testViewChangesRejectsUpstreamSymlink() throws {
        let fixture = try prepareRealPinnedUpdate()
        let skillFile = fixture.repository + "/skills/vendor/SKILL.md"
        try fileService.deleteFile(at: skillFile)
        try fileService.createSymlink(at: skillFile, pointingTo: "/etc/passwd")
        let symlinkCommit = try commit(fixture.repository, message: "symlink update")
        let source = try fixture.service.fetch(
            repo: fixture.repository,
            ref: nil,
            path: "skills/vendor",
            credential: nil
        )
        let candidate = try XCTUnwrap(source.candidates.first)
        fixture.skill.upstreamCommit = symlinkCommit
        fixture.skill.upstreamTree = candidate.treeHash
        try context.save()

        XCTAssertThrowsError(
            try fixture.service.previewUpdate(PinnedSkillUpdate(skill: fixture.skill))
        ) { error in
            guard case SkillInstallError.unavailableCandidate = error else {
                return XCTFail("expected unavailable symlink candidate, got \(error)")
            }
        }
    }

    func testApplyRevalidatesDriftAtVendorBoundary() throws {
        let fixture = try prepareRealPinnedUpdate()
        let update = try PinnedSkillUpdate(skill: fixture.skill)
        let installedFile = fixture.storeRoot + "/skills/vendor/SKILL.md"
        try fileService.writeFile(
            at: installedFile,
            content: "---\nname: Local\ndescription: Edited\n---\nlocal edit\n"
        )

        XCTAssertThrowsError(
            try fixture.service.applyUpdate(
                update,
                allowLocalOverwrite: false,
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? SkillUpdateFlowError, .localEditsRequireConfirmation)
        }
        XCTAssertTrue(try fileService.readFile(at: installedFile).contains("local edit"))
    }

    func testApplyRejectsPinChangedAfterRowLoaded() async throws {
        let fixture = try prepareRealPinnedUpdate()
        let model = makeRealModel(fixture: fixture)
        await model.loadAndReport(context: context)
        fixture.skill.upstreamCommit = String(repeating: "9", count: 40)
        try context.save()

        await model.applySelectedAndReport(context: context)

        let row = try XCTUnwrap(model.rows.first)
        guard case let .failed(message, offersRecheck) = model.status(for: row) else {
            return XCTFail("a changed persisted pin must fail the displayed row")
        }
        XCTAssertEqual(message, SkillUpdateFlowError.repositoryChangedMessage)
        XCTAssertTrue(offersRecheck)
        XCTAssertTrue(
            try fileService.readFile(at: fixture.storeRoot + "/skills/vendor/SKILL.md")
                .contains("old body")
        )
    }
}
