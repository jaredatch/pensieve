import XCTest
@testable import Pensieve

final class TokenCounterTests: XCTestCase {
    func testEstimateBasic() {
        // 20 chars → 5 tokens
        let text = "Hello World, testing!" // 21 chars
        XCTAssertEqual(TokenCounter.estimate(text), 5)
    }

    func testEstimateEmpty() {
        XCTAssertEqual(TokenCounter.estimate(""), 0)
    }

    func testBudgetStatusOk() {
        let text = String(repeating: "a", count: 400) // 100 tokens
        let status = TokenCounter.budgetStatus(text: text, budget: 200)
        if case .ok(let tokens, let budget) = status {
            XCTAssertEqual(tokens, 100)
            XCTAssertEqual(budget, 200)
        } else {
            XCTFail("Expected .ok")
        }
    }

    func testBudgetStatusWarning() {
        let text = String(repeating: "a", count: 3600) // 900 tokens
        let status = TokenCounter.budgetStatus(text: text, budget: 1000)
        if case .warning(let tokens, _) = status {
            XCTAssertEqual(tokens, 900)
        } else {
            XCTFail("Expected .warning, got \(status)")
        }
    }

    func testBudgetStatusExceeded() {
        let text = String(repeating: "a", count: 8000) // 2000 tokens
        let status = TokenCounter.budgetStatus(text: text, budget: 1000)
        if case .exceeded(let tokens, _) = status {
            XCTAssertEqual(tokens, 2000)
        } else {
            XCTFail("Expected .exceeded")
        }
    }

    func testTokenAndTextBudgetChecksAgreeAtBoundaries() {
        for tokens in [799, 800, 801, 1_000, 1_001] {
            let text = String(repeating: "a", count: tokens * Constants.charsPerToken)

            XCTAssertEqual(TokenCounter.budgetStatus(tokens: tokens, budget: 1_000),
                           TokenCounter.budgetStatus(text: text, budget: 1_000))
        }
    }

    func testBudgetStatusHandlesIntegerLimitsWithoutOverflow() {
        let budget = Int.max
        let threshold = 7_378_697_629_483_820_645

        XCTAssertEqual(TokenCounter.budgetStatus(tokens: 100, budget: budget), .ok(tokens: 100, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: threshold, budget: budget), .ok(tokens: threshold, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: threshold + 1, budget: budget),
                       .warning(tokens: threshold + 1, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: budget, budget: budget), .warning(tokens: budget, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: Int.max, budget: Int.max - 1),
                       .exceeded(tokens: Int.max, budget: Int.max - 1))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: Int.min, budget: Int.min), .ok(tokens: Int.min, budget: Int.min))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: 0, budget: Int.min), .exceeded(tokens: 0, budget: Int.min))
    }

    func testOrdinaryBudgetKeepsStrictFlooredBoundaries() {
        let budget = 2_503

        XCTAssertEqual(TokenCounter.budgetStatus(tokens: 2_001, budget: budget), .ok(tokens: 2_001, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: 2_002, budget: budget), .ok(tokens: 2_002, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: 2_003, budget: budget), .warning(tokens: 2_003, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: budget, budget: budget), .warning(tokens: budget, budget: budget))
        XCTAssertEqual(TokenCounter.budgetStatus(tokens: budget + 1, budget: budget),
                       .exceeded(tokens: budget + 1, budget: budget))
    }
}
