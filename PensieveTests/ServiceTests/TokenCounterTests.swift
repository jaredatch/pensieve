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
}
