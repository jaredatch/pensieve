import SwiftData
import SwiftUI

struct CommandLineSettingsSection: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var context
    @Environment(\.controlActiveState) private var activeState
    @State private var confirmsReplacement = false

    private var links: CommandLineSettingsModel { runtime.commandLineSettings }
    private var skill: BundledSkillModel { runtime.bundledSkill }

    var body: some View {
        Section {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Command line tool")
                    HStack(spacing: Spacing.xs) {
                        if links.status != .absent {
                            Image(systemName: links.status.hasProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(links.status.hasProblem ? .orange : .green)
                        }
                        Text(links.error ?? links.status.message).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer(minLength: Spacing.sm)
                ForEach(links.status.actions, id: \.rawValue) { action in
                    Button(actionTitle(action)) { Task { await links.perform(action) } }
                        .disabled(links.isWorking || isOccupied)
                        .accessibilityLabel(actionTitle(action) + " command line tool")
                }
            }
            .frame(minHeight: DesignTokens.commandLineRowContentHeight)
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("pensieve skill")
                    HStack(spacing: Spacing.xs) {
                        if skill.state == .installed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Text(skill.error ?? skill.message).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Spacer(minLength: Spacing.sm)
                switch skill.state {
                case .absent:
                    Button("Add to Library") { Task { await skill.add(context: context) } }
                        .disabled(runtime.library.addsFenced || skill.isWorking)
                case .installed: EmptyView()
                case .update:
                    Button("Update") { Task { await skill.update(context: context) } }
                        .disabled(runtime.library.addsFenced || skill.isWorking)
                case .edited:
                    Button("Replace…") { confirmsReplacement = true }
                        .disabled(runtime.library.addsFenced || skill.isWorking)
                }
            }
            .frame(minHeight: DesignTokens.commandLineRowContentHeight)
            .help(runtime.library.addFenceReason ?? "")
        } header: {
            Text("Command Line")
        } footer: {
            Text("Install links pensieve into /usr/local/bin so you and your agents can run it in any terminal. "
                + "macOS asks for your password. The skill teaches agents how to use it.")
        }
        .task { await refresh() }
        .onChange(of: activeState) { _, _ in Task { await refresh() } }
        .alert("Replace your pensieve skill?", isPresented: $confirmsReplacement) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) { Task { await skill.update(context: context, replaceEdits: true) } }
        } message: {
            Text("This replaces your saved edits with the skill bundled with this app.")
        }
    }

    private var isOccupied: Bool { links.status.hasProblem && links.status.action == .install }

    private func actionTitle(_ action: CommandLinkAction) -> String {
        switch action {
        case .install: return "Install…"
        case .uninstall: return "Uninstall…"
        case .repair: return "Repair…"
        }
    }

    private func refresh() async {
        await links.refresh()
        await skill.refresh(context: context)
    }
}
