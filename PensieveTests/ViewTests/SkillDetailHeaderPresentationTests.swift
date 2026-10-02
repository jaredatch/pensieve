import XCTest
@testable import Pensieve

/// The header's provenance path and the banner's title (PLAN-34 / 34.2).
final class SkillDetailHeaderPresentationTests: XCTestCase {
    private func provenance(repositoryURL: URL?) -> SkillProvenance {
        SkillProvenance(installedAt: nil, updatedAt: nil, trackedRef: "main", shortCommit: nil, repositoryURL: repositoryURL,
                        skillURL: nil, localEditNote: nil, checkError: nil, updateAvailable: false)
    }

    func testRepositoryPathIsOwnerSlashRepo() {
        XCTAssertEqual(SkillDetailHeaderPresentation.repositoryPath(
            provenance(repositoryURL: URL(string: "https://github.com/basecamp/basecamp-cli"))), "basecamp/basecamp-cli")
        XCTAssertEqual(SkillDetailHeaderPresentation.repositoryPath(
            provenance(repositoryURL: URL(string: "https://github.com/basecamp/basecamp-cli/"))), "basecamp/basecamp-cli")
    }

    func testUnlinkedHasNoPath() {
        XCTAssertNil(SkillDetailHeaderPresentation.repositoryPath(provenance(repositoryURL: nil)))
        XCTAssertNil(SkillDetailHeaderPresentation.repositoryPath(provenance(repositoryURL: URL(string: "https://github.com/"))))
    }

    func testBannerTitleNamesTheUpstreamDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12))!
        XCTAssertEqual(SkillUpdateAvailableBanner.title(upstreamDate: date, locale: Locale(identifier: "en_US")),
                       "Update available · Sep 10")
    }

    func testBannerTitleWithoutADate() {
        XCTAssertEqual(SkillUpdateAvailableBanner.title(upstreamDate: nil), "Update available")
    }

    func testTheCheckLineShowsCheckingOverTheLastError() {
        XCTAssertEqual(SkillDetailHeaderPresentation.checkLine(isChecking: true, checkError: "boom"), .checking)
    }

    func testTheCheckLineShowsAFailedCheck() {
        XCTAssertEqual(SkillDetailHeaderPresentation.checkLine(isChecking: false, checkError: "boom"), .failed("boom"))
    }

    func testTheCheckLineIsAbsentWithNoCheck() {
        XCTAssertNil(SkillDetailHeaderPresentation.checkLine(isChecking: false, checkError: nil))
    }
}
