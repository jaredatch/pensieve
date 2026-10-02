import XCTest
@testable import Pensieve

/// The strip's tabs (PLAN-34 / 34.2, the fourth at 34.4): declaration order, title case, stable identifiers.
final class DetailTabTests: XCTestCase {
    func testTheStripOrderIsDeclarationOrder() {
        XCTAssertEqual(DetailTab.allCases.map(\.title), ["Overview", "Deployments", "Content", "History"])
    }

    func testEveryTabHasATitleCaseTitle() {
        for tab in DetailTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertEqual(tab.title.first.map { $0.isUppercase }, true, tab.title)
        }
    }

    func testRawValuesAreStableIdentifiers() {
        for tab in DetailTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
            XCTAssertEqual(tab.rawValue, tab.rawValue.lowercased())
        }
    }

    func testThereAreFourTabs() {
        XCTAssertEqual(DetailTab.allCases.count, 4)
    }
}
