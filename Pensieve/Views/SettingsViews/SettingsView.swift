import SwiftUI

struct SettingsView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var modelContext
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            SyncSettingsView(model: runtime.paths.makeSyncSetupModel(context: modelContext))
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            PlatformSettingsView()
                .tabItem {
                    Label("Platforms", systemImage: "square.stack.3d.up")
                }

            GitHubSettingsView(credentialStore: runtime.paths.makeCredentialStore())
                .tabItem {
                    Label("GitHub", systemImage: "lock.shield")
                }
        }
        .frame(width: 500, height: 350)
    }
}
