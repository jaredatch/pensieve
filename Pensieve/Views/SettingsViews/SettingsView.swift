import SwiftUI

struct SettingsView: View {
    @Environment(AppRuntime.self) private var runtime
    var body: some View {
        @Bindable var runtime = runtime
        TabView(selection: $runtime.selectedSettingsTab) {
            GeneralSettingsView()
                .tag(AppRuntime.SettingsTab.general)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            SyncSettingsView()
                .tag(AppRuntime.SettingsTab.sync)
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            PlatformSettingsView()
                .tag(AppRuntime.SettingsTab.platforms)
                .tabItem {
                    Label("Platforms", systemImage: "square.stack.3d.up")
                }

            GitHubSettingsView(credentialStore: runtime.paths.makeCredentialStore())
                .tag(AppRuntime.SettingsTab.github)
                .tabItem {
                    Label("GitHub", systemImage: "lock.shield")
                }
        }
        .frame(width: 500, height: 350)
    }
}
