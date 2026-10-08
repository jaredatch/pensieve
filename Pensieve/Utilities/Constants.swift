import Foundation
import SwiftUI

// MARK: - Spacing (4pt grid)

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
}

/// Path/config constants live in the SwiftUI-free `PathConstants` (PLAN-12 / 12.1). `Constants`
/// re-exports them so app call sites keep the `Constants.` spelling with zero churn; daemon-compiled
/// shared files reference `PathConstants` directly.
/// Static members share PathConstants' classification in script/runtime-path-members.json.
enum Constants {
    static var homeDirectory: String { PathConstants.homeDirectory }
    static var pensieveBaseDir: String { PathConstants.pensieveBaseDir }
    static var pensieveSkillsDir: String { PathConstants.pensieveSkillsDir }
    static var pensieveAppSupportDir: String { PathConstants.pensieveAppSupportDir }
    static var gitAskpassHelperPath: String { PathConstants.gitAskpassHelperPath }
    static var claudeCodeUserSkillsDir: String { PathConstants.claudeCodeUserSkillsDir }
    static var grokUserSkillsDir: String { PathConstants.grokUserSkillsDir }
    static var codexUserSkillsDir: String { PathConstants.codexUserSkillsDir }
    static var openClawUserSkillsDir: String { PathConstants.openClawUserSkillsDir }
    static var hermesUserSkillsDir: String { PathConstants.hermesUserSkillsDir }
    static var hermesDefaultCategory: String { PathConstants.hermesDefaultCategory }
    static var cursorUserRulesDir: String { PathConstants.cursorUserRulesDir }
    static var claudeCodeProjectSkillsRel: String { PathConstants.claudeCodeProjectSkillsRel }
    static var grokProjectSkillsRel: String { PathConstants.grokProjectSkillsRel }
    static var codexAgentsRel: String { PathConstants.codexAgentsRel }
    static var defaultClaudeCodeTokenBudget: Int { PathConstants.defaultClaudeCodeTokenBudget }
    static var defaultGrokTokenBudget: Int { PathConstants.defaultGrokTokenBudget }
    static var defaultCursorTokenBudget: Int { PathConstants.defaultCursorTokenBudget }
    static var defaultCodexTokenBudget: Int { PathConstants.defaultCodexTokenBudget }
    static var charsPerToken: Int { PathConstants.charsPerToken }
}
