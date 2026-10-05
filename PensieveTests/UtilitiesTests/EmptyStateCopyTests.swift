import XCTest
@testable import Pensieve

/// The empty states' copy from the Sketch frames: Mail's "No … Selected" for a detail column with
/// nothing selected, and the no-results title with the query on its own line in curly quotes.
final class EmptyStateCopyTests: XCTestCase {
    func testNoSelectionTitleNamesEachSectionsEntity() {
        let titles = SidebarSection.allCases.map(EmptyStateCopy.noSelectionTitle)
        XCTAssertEqual(titles, [
            "No Skill Selected",
            "No Project Selected",
            "No Category Selected",
            "No Tag Selected",
            "No Machine Selected"
        ])
    }

    func testSearchTitlePutsTheTrimmedQueryInCurlyQuotesOnItsOwnLine() {
        XCTAssertEqual(EmptyStateCopy.searchTitle("  pdf tools \n"), "No Results for\n\u{201C}pdf tools\u{201D}")
    }

    func testSearchDescriptionMatchesTheFrame() {
        XCTAssertEqual(EmptyStateCopy.searchDescription, "Check the spelling or try a new search.")
    }
}
