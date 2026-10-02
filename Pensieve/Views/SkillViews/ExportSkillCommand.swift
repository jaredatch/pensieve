import SwiftUI

private struct ExportSelectedSkillActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportSelectedSkill: (() -> Void)? {
        get { self[ExportSelectedSkillActionKey.self] }
        set { self[ExportSelectedSkillActionKey.self] = newValue }
    }
}

/// Export shares Delete's focus rule: one shown skill, in a key window with no sheet holding focus.
struct ExportSkillCommand: View {
    @FocusedValue(\.exportSelectedSkill) private var exportSelectedSkill
    @FocusedValue(\.skillDetailWindowIsKey) private var detailWindowIsKey

    var body: some View {
        Button("Export SKILL.md…") { exportSelectedSkill?() }
            .disabled(!DeleteSkillCommandRule.isEnabled(hasAction: exportSelectedSkill != nil,
                                                        windowIsKey: detailWindowIsKey))
    }
}
