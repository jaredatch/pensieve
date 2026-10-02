import Foundation

enum TokenCounter {
    /// Estimate token count using char/4 heuristic.
    static func estimate(_ text: String) -> Int {
        text.count / Constants.charsPerToken
    }

    /// Check if a skill body exceeds a platform's token budget.
    static func budgetStatus(text: String, budget: Int) -> BudgetStatus {
        let tokens = estimate(text)
        if tokens > budget {
            return .exceeded(tokens: tokens, budget: budget)
        } else if tokens > budget * 80 / 100 {
            return .warning(tokens: tokens, budget: budget)
        } else {
            return .ok(tokens: tokens, budget: budget)
        }
    }

    enum BudgetStatus {
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
