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
            let budget = defaults.object(forKey: storageKey) == nil
                ? defaultValue : defaults.integer(forKey: storageKey)
            guard budget > 0 else { continue }
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

    static func rows(paths: DeployPaths) -> [Self] { [
        Self(platform: .claudeCode, kind: "Skills", path: paths.userSkillsRoot(for: .claudeCode) ?? ""),
        Self(platform: .grok, kind: "Skills", path: paths.userSkillsRoot(for: .grok) ?? ""),
        Self(platform: .cursor, kind: "Rules", path: paths.cursorUserRulesDirectory)
    ] }
}

struct PlatformSettingsView: View {
    @Environment(AppRuntime.self) private var runtime
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
                ForEach(PlatformPathSetting.rows(paths: runtime.paths.deployPaths)) { setting in
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
