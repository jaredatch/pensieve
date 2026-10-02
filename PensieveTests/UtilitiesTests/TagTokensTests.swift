import XCTest
@testable import Pensieve

final class TagTokensTests: XCTestCase {
    func testNormalizeTrimsDropsEmptiesAndDedupesCaseInsensitively() {
        XCTAssertEqual(
            TagTokens.normalize(["  swift ", "", "Swift", "review", "REVIEW "]),
            ["review", "swift"]
        )
    }

    func testNormalizeSortsWithTheManifestComparator() {
        XCTAssertEqual(TagTokens.normalize(["b", "a", "c"]), ["a", "b", "c"])
        XCTAssertEqual(TagTokens.normalize(["b", "A"]), ["A", "b"])
    }

    func testCommitDecisionUntouchedAdoptsStoreTouchedWins() {
        XCTAssertEqual(
            TagTokens.commitDecision(baseline: ["alpha"], edited: ["alpha"], stored: ["alpha"]),
            .nothing
        )
        XCTAssertEqual(
            TagTokens.commitDecision(baseline: ["alpha"], edited: ["alpha"], stored: ["alpha", "beta"]),
            .adoptStored
        )
        XCTAssertEqual(
            TagTokens.commitDecision(
                baseline: ["alpha"], edited: ["alpha", "gamma"], stored: ["alpha", "beta"]
            ),
            .commit(["alpha", "gamma"])
        )
        XCTAssertEqual(
            TagTokens.commitDecision(
                baseline: ["alpha"], edited: ["alpha", " beta "], stored: ["alpha", "beta"]
            ),
            .nothing
        )
    }

    func testCompletionsPrefixCaseInsensitiveExcludingPresentSorted() {
        XCTAssertEqual(
            TagTokens.completions(
                for: "SW", inUse: ["Swift", "swiftui", "review", "sw"], excluding: ["sw"]
            ),
            ["Swift", "swiftui"]
        )
    }

    func testCompletionsEmptyForBlankPrefix() {
        XCTAssertEqual(TagTokens.completions(for: "   ", inUse: ["Swift"], excluding: []), [])
    }
}
