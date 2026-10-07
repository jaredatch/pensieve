import Foundation

enum TokenCounter {
    /// Estimate token count using char/4 heuristic.
    static func estimate(_ text: String) -> Int {
        text.count / Constants.charsPerToken
    }

    /// Check if a skill body exceeds its size budget.
    static func budgetStatus(text: String, budget: Int) -> BudgetStatus {
        budgetStatus(tokens: estimate(text), budget: budget)
    }

    /// Check an existing estimate against the same thresholds as the text estimate.
    static func budgetStatus(tokens: Int, budget: Int) -> BudgetStatus {
        // Compute floor(4/5 of the budget) without multiplying the full budget, even at Int's limits.
        let remainder = budget % 5
        let warningThreshold = budget / 5 * 4 + remainder * 4 / 5 - (remainder < 0 ? 1 : 0)
        if tokens > budget {
            return .exceeded(tokens: tokens, budget: budget)
        } else if tokens > warningThreshold {
            return .warning(tokens: tokens, budget: budget)
        } else {
            return .ok(tokens: tokens, budget: budget)
        }
    }

    enum BudgetStatus: Equatable {
        case ok(tokens: Int, budget: Int)
        case warning(tokens: Int, budget: Int)
        case exceeded(tokens: Int, budget: Int)

        var tokens: Int {
            switch self {
            case .ok(let t, _), .warning(let t, _), .exceeded(let t, _): t
            }
        }
    }
}
