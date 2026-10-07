import Foundation

extension SkillOverviewPresentation {
    /// Raw values define the card and tooltip priority, independently of the triangle's severity.
    private enum ContextWarning: Int {
        case codexName
        case budgetExceeded
        case claudeDescription
        case claudeCompaction
        case cursorAlwaysOn
        case budgetNear

        var severity: WarningSeverity {
            self == .codexName || self == .budgetExceeded ? .exceeded : .warning
        }

        func detail(budget: String) -> String {
            switch self {
            case .codexName: "Codex skips it: name too long"
            case .budgetExceeded: "over the \(budget)-token budget"
            case .claudeDescription: "Claude Code cuts the description"
            case .claudeCompaction: "past Claude Code's 5,000-token cutoff"
            case .cursorAlwaysOn: "loads into every Cursor chat"
            case .budgetNear: "near the \(budget)-token budget"
            }
        }

        func tooltip(budget: String) -> String {
            switch self {
            case .codexName: "Codex skips this skill: its name is over 64 characters."
            case .budgetExceeded: "Over the \(budget)-token budget."
            case .claudeDescription:
                "Claude Code cuts off descriptions over 1,536 characters (description plus when_to_use)."
            case .claudeCompaction: "After compaction, Claude Code keeps only the first 5,000 tokens."
            case .cursorAlwaysOn: "Cursor loads this always-on rule into every chat."
            case .budgetNear: "Near the \(budget)-token budget."
            }
        }
    }

    static func contextCost(snapshot: DetailContentSnapshot, budget: Int, locale: Locale) -> Stat {
        var warnings = agentWarnings(snapshot: snapshot)
        let deployed = snapshot.macStatus.values.contains(true)
            || snapshot.projectStatus.values.contains { $0.values.contains(true) }
        var budgetWarning: ContextWarning?
        if deployed && budget > 0 {
            switch TokenCounter.budgetStatus(tokens: snapshot.tokenCount, budget: budget) {
            case .ok: break
            case .warning: budgetWarning = .budgetNear
            case .exceeded: budgetWarning = .budgetExceeded
            }
        }
        if let budgetWarning { warnings.append(budgetWarning) }
        warnings.sort { $0.rawValue < $1.rawValue }
        // Keep the compaction explanation in the tooltip, but don't repeat a budget warning on the card.
        let shown = warnings.first { $0 != .claudeCompaction || budgetWarning == nil }
        let formattedBudget = budget.formatted(.number.locale(locale))
        let tooltip = warnings.map { $0.tooltip(budget: formattedBudget) }.joined(separator: "\n")
        return Stat(label: "Context cost", value: snapshot.tokenCount.formatted(.number.locale(locale)),
                    detail: shown?.detail(budget: formattedBudget) ?? "tokens when loaded",
                    warningSeverity: shown?.severity,
                    tooltip: warnings.isEmpty ? nil : tooltip)
    }

    private static func agentWarnings(snapshot: DetailContentSnapshot) -> [ContextWarning] {
        AgentSkillLimit.known.compactMap { limit in
            guard snapshot.isDeployed(to: limit.platform) else { return nil }
            switch limit.kind {
            case .nameCharacters:
                // Codex's Rust chars() counts Unicode scalars, including each scalar in a combining sequence.
                return snapshot.frontmatterName.unicodeScalars.count > limit.maximum ? .codexName : nil
            case .descriptionCharacters:
                let characters = snapshot.frontmatterDescription.count + snapshot.frontmatterWhenToUse.count
                return characters > limit.maximum ? .claudeDescription : nil
            case .compactionTokens:
                return snapshot.tokenCount > limit.maximum ? .claudeCompaction : nil
            case .alwaysOnTokens:
                return snapshot.cursorAlwaysApply && snapshot.tokenCount > limit.maximum ? .cursorAlwaysOn : nil
            }
        }
    }
}
