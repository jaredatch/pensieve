import SwiftUI

struct PlatformTokenBudgetSetting: Identifiable, Equatable {
    enum Budget: Equatable {
        case editable(storageKey: String, defaultValue: Int)
        case unlimited
    }

    let platform: PlatformTarget
    let budget: Budget

    var id: PlatformTarget { platform }

    static let rows: [Self] = [
        Self(
            platform: .claudeCode,
            budget: .editable(
                storageKey: "claudeCodeTokenBudget",
                defaultValue: Constants.defaultClaudeCodeTokenBudget
            )
        ),
        Self(
            platform: .grok,
            budget: .editable(storageKey: "grokTokenBudget", defaultValue: Constants.defaultGrokTokenBudget)
        ),
        Self(
            platform: .cursor,
            budget: .editable(storageKey: "cursorTokenBudget", defaultValue: Constants.defaultCursorTokenBudget)
        ),
        Self(platform: .codex, budget: .unlimited)
    ]

    static func values(defaults: UserDefaults = .standard) -> [PlatformTarget: Int] {
        var values: [PlatformTarget: Int] = [:]
        for setting in rows {
            guard case let .editable(storageKey, defaultValue) = setting.budget else { continue }
            let storedValue = defaults.object(forKey: storageKey)
            let budget = storedValue == nil ? defaultValue : storedValue as? Int
            guard let budget, budget > 0 else { continue }
            values[setting.platform] = budget
        }
        return values
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
    var body: some View {
        Form {
            Section("Token Budgets") {
                ForEach(PlatformTokenBudgetSetting.rows) { setting in
                    switch setting.budget {
                    case let .editable(storageKey, defaultValue):
                        EditableTokenBudgetRow(
                            platform: setting.platform,
                            storageKey: storageKey,
                            defaultValue: defaultValue
                        )
                    case .unlimited:
                        HStack {
                            Text(setting.platform.displayName)
                            Spacer()
                            Text("Unlimited")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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

private struct EditableTokenBudgetRow: View {
    let platform: PlatformTarget
    @AppStorage private var budget: Int

    init(platform: PlatformTarget, storageKey: String, defaultValue: Int) {
        self.platform = platform
        _budget = AppStorage(wrappedValue: defaultValue, storageKey)
    }

    var body: some View {
        HStack {
            Text(platform.displayName)
            Spacer()
            TextField("", value: $budget, format: .number)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
            Text("tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
