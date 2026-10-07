import SwiftUI

enum SkillSizeBudgetSetting {
    static let storageKey = "skillSizeTokenBudget"

    static func value(defaults: UserDefaults = .standard) -> Int {
        if defaults.object(forKey: storageKey) != nil {
            return defaults.integer(forKey: storageKey)
        }
        // Preserve a customized Claude Code budget until the user sets the shared budget.
        if defaults.object(forKey: "claudeCodeTokenBudget") != nil {
            let legacy = defaults.integer(forKey: "claudeCodeTokenBudget")
            if legacy != 2_500 { return legacy }
        }
        return Constants.defaultSkillSizeTokenBudget
    }
}

struct PlatformPathSetting: Identifiable, Equatable {
    let platform: PlatformTarget
    let kind: String
    let path: String

    var id: PlatformTarget { platform }
    var label: String { "\(platform.displayName) \(kind)" }

    static let rows: [Self] = [
        Self(platform: .claudeCode, kind: "Skills", path: Constants.claudeCodeUserSkillsDir),
        Self(platform: .grok, kind: "Skills", path: Constants.grokUserSkillsDir),
        Self(platform: .cursor, kind: "Rules", path: Constants.cursorUserRulesDir)
    ]
}

struct PlatformSettingsView: View {
    @AppStorage private var budget: Int

    init(defaults: UserDefaults = .standard) {
        _budget = AppStorage(wrappedValue: SkillSizeBudgetSetting.value(defaults: defaults),
                             SkillSizeBudgetSetting.storageKey, store: defaults)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Budget")
                    Spacer()
                    TextField("", value: $budget, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Text("tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Skill Size")
            } footer: {
                Text("The Overview tab warns when a deployed skill's instructions get near this size. It never blocks a deploy.")
            }

            Section("Platform Paths") {
                ForEach(PlatformPathSetting.rows) { setting in
                    LabeledContent(setting.label) {
                        Text(setting.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
