import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppRuntime.self) private var runtime
    @AppStorage("pensieveSkillsDir") private var skillsDir = Constants.pensieveSkillsDir
    @AppStorage(UpdateChannelPolicy.betaUpdatesEnabledKey) private var betaUpdatesEnabled = false
    @AppStorage(UpdateCheckSchedule.frequencyKey) private var updateCheckFrequency =
        UpdateCheckFrequency.weekly.rawValue
    @AppStorage(MachineDisplayName.defaultsKey) private var machineDisplayName = ""
    @State private var machineDisplayNamePlaceholder = "Mac"
    @State private var loginItem = LoginItemModel()

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Skills Directory") {
                    HStack {
                        Text(skillsDir)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button("Reset") {
                            skillsDir = Constants.pensieveSkillsDir
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Behavior") {
                TextField(
                    "Machine name",
                    text: $machineDisplayName,
                    prompt: Text(machineDisplayNamePlaceholder)
                )
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                Toggle("Receive beta updates", isOn: $betaUpdatesEnabled)
                if loginItem.requiresApproval {
                    HStack(spacing: Spacing.sm) {
                        Text("Launch at login needs approval in Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            loginItem.openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Skill Updates") {
                HStack(spacing: Spacing.md) {
                    Picker("Check for skill updates", selection: $updateCheckFrequency) {
                        ForEach(UpdateCheckFrequency.allCases) { frequency in
                            Text(frequency.title).tag(frequency.rawValue)
                        }
                    }

                    Button("Check Now") {
                        runtime.checkForSkillUpdatesFromSettings()
                    }
                    .disabled(runtime.updateCheckInFlight)
                }

                HStack(spacing: Spacing.sm) {
                    if runtime.updateCheckInFlight {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking…")
                    } else if let error = runtime.updateCheckError {
                        Text("Last check failed: \(error)")
                    } else if let date = runtime.lastUpdateCheckStartedAt {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Not checked yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            machineDisplayNamePlaceholder = MachineDisplayName.publishedFallback(
                hostName: MachineDisplayName.currentHostName()
            )
            loginItem.refresh()
        }
        .alert("Launch at login", isPresented: Binding(
            get: { loginItem.errorMessage != nil },
            set: { if !$0 { loginItem.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginItem.errorMessage ?? "")
        }
    }
}
