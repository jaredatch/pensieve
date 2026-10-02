import XCTest
@testable import Pensieve

final class LineDiffTests: XCTestCase {
    func testIdenticalInputsAreAllUnchanged() {
        let rows = LineDiffView.alignedRows(this: "alpha\nbeta\ngamma",
                                           other: "alpha\nbeta\ngamma")

        XCTAssertEqual(rows, [
            DiffRow(this: "alpha", other: "alpha", changed: false),
            DiffRow(this: "beta", other: "beta", changed: false),
            DiffRow(this: "gamma", other: "gamma", changed: false)
        ])
        XCTAssertTrue(rows.allSatisfy { !$0.changed })
    }

    func testOneLineChangeIsOneChangedPair() {
        let rows = LineDiffView.alignedRows(this: "alpha\nold\ngamma",
                                           other: "alpha\nnew\ngamma")
        let changedRows = rows.filter(\.changed)

        XCTAssertEqual(changedRows, [
            DiffRow(this: "old", other: "new", changed: true)
        ])
        XCTAssertEqual(changedRows.count, 1)
        XCTAssertNotNil(changedRows[0].this)
        XCTAssertNotNil(changedRows[0].other)
    }

    func testPureInsertionHasNilThisSide() {
        let rows = LineDiffView.alignedRows(this: "alpha\ngamma",
                                           other: "alpha\nbeta\ngamma")

        XCTAssertTrue(rows.contains(DiffRow(this: nil, other: "beta", changed: true)))
    }

    func testPureDeletionHasNilOtherSide() {
        let rows = LineDiffView.alignedRows(this: "alpha\nbeta\ngamma",
                                           other: "alpha\ngamma")

        XCTAssertTrue(rows.contains(DiffRow(this: "beta", other: nil, changed: true)))
    }
}
