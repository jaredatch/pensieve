import SwiftUI
import SwiftData
import Sparkle
import AppKit

enum TestHostGuard {
    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}

/// The process entry point. `SceneBuilder` rejects control-flow statements, so the test-host guard
/// cannot live inside one `App`'s scene body — instead the guard picks WHICH App runs (PLAN-24 / 24.1):
/// under XCTest the inert `PensieveTestHostApp` (one placeholder scene, no runtime, no Sparkle, no
/// cleanups, no launch signal); otherwise the untouched production `PensieveApp`.
@main
enum PensieveMain {
    static func main() {
        if TestHostGuard.isActive() {
            PensieveTestHostApp.main()
        } else {
            PensieveApp.main()
        }
    }
}

/// The XCTest app host. Installs the real `PensieveAppDelegate` via the adaptor (so the in-process
/// guard test observes the genuine delegate, whose `runtime` nothing ever assigns) and renders exactly
/// one inert scene — no model container, no runtime environment, no commands, no Settings, no
/// MenuBarExtra.
struct PensieveTestHostApp: App {
    @NSApplicationDelegateAdaptor(PensieveAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Pensieve", id: "main") {
            Text("Pensieve test host")
        }
    }
}

struct PensieveApp: App {
    @NSApplicationDelegateAdaptor(PensieveAppDelegate.self) private var appDelegate

    private let updaterDelegate: UpdaterDelegate
    /// nil in dogfood mode: Sparkle's controller is never constructed there.
    private let updaterController: SPUStandardUpdaterController?
    private let runtime: AppRuntime

    init() {
        WindowPolicy.apply()
        SkillInstallService.cleanupScratchRoot()
        SkillInstallService.cleanupVendorTemps()
        UpdateCheckService.cleanupScratchRoot()
        UpstreamHistoryService.cleanupScratchRoot()

        let updaterDelegate = UpdaterDelegate()
        self.updaterDelegate = updaterDelegate
        updaterController = DogfoodMode.isActive ? nil : SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        do {
            runtime = try AppRuntime()
        } catch {
            fatalError("Unable to initialize Pensieve's data store: \(error.localizedDescription)")
        }
        appDelegate.runtime = runtime
        runtime.library.unsavedChangesPresenter = UnsavedChangesAlert.present

        LaunchSignaler().signalLaunch()
    }

    static func makeContentView(runtime: AppRuntime) -> ContentView {
        ContentView(
            installService: runtime.updatesViewModelOperations.skillInstallService,
            notifier: runtime.syncStateNotifier,
            echoRegistrar: runtime.syncWriteEchoRegistrar,
            bodyWriteRegistration: runtime.syncBodyWriteRegistration,
            updatesModel: runtime.updates
        )
    }

    var body: some Scene {
        WindowGroup("Pensieve", id: "main") {
            Self.makeContentView(runtime: runtime)
                .environment(runtime)
        }
        .modelContainer(runtime.container)
        .defaultSize(width: 1280, height: 850)
        .commands {
            // ⌘N creates a skill (PLAN-29 / 29.4-m): this group REPLACES the WindowGroup's
            // standard New group, retiring New Window ⌘N in a single-window app. It comes first so the
            // GitHub group's `after: .newItem` placement below still lands. The create sheet is presented
            // by `ContentView` off `library.showCreateSheet`; a shortcut on the toolbar's New Skill menu
            // item is never a key equivalent, so the menu bar owns it.
            CommandGroup(replacing: .newItem) {
                NewSkillCommand(library: runtime.library)

                Divider()

                ImportFromFolderCommand(library: runtime.library)
            }

            GitHubInstallCommands(library: runtime.library, runtime: runtime)

            CommandGroup(after: .saveItem) {
                SaveSkillCommand(library: runtime.library)
                ExportSkillCommand()
                Divider()
                DeleteSkillCommand()
            }

            if let updaterController {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") {
                        updaterController.checkForUpdates(nil)
                    }
                }
            }
        }

        ViewChangesScene(model: runtime.viewChanges, library: runtime.library,
                         updates: runtime.updates, container: runtime.container)

        Settings {
            SettingsView()
                .environment(runtime)
        }
        .modelContainer(runtime.container)

        MenuBarExtra("Pensieve", image: "MenuBarGlyph") {
            PensieveMenuBarView()
                .environment(runtime)
        }
    }
}

private struct PensieveMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppRuntime.self) private var runtime
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true

    var body: some View {
        Label(syncTitle, systemImage: syncSymbol)
        if let detail = syncDetail {
            Text(detail)
                .foregroundStyle(.secondary)
        }
        Toggle("Background sync", isOn: $backgroundSyncEnabled)
            .onChange(of: backgroundSyncEnabled) { _, _ in
                runtime.scheduler.backgroundPreferenceChanged()
            }
        Divider()
        Button("Open Pensieve") {
            WindowPolicy.showMainWindow(among: NSApp.windows) { openWindow(id: "main") }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Sync Now") {
            runtime.syncModel.syncNow()
        }
        .disabled(!runtime.syncModel.canSyncNow)
        Divider()
        Button("Quit Pensieve") {
            NSApplication.shared.terminate(nil)
        }

        #if DEBUG
        Divider()
        Text("Launch work runs: \(runtime.launchWorkInvocationCount)")
        #endif
    }

    private var syncTitle: String {
        switch runtime.syncModel.state {
        case .idle: return "Ready to sync"
        case .syncing: return "Syncing…"
        case .synced: return "Synced"
        case .conflicted: return "Conflict needs attention"
        case .error: return "Sync failed"
        case .unconfigured: return "Sync not configured"
        }
    }

    private var syncSymbol: String {
        switch runtime.syncModel.state {
        case .synced: return "checkmark.circle"
        case .conflicted, .error: return "exclamationmark.triangle"
        case .unconfigured: return "arrow.triangle.branch"
        case .idle, .syncing: return "arrow.triangle.2.circlepath"
        }
    }

    private var syncDetail: String? {
        switch runtime.syncModel.state {
        case let .synced(at):
            return "Last synced " + at.formatted(date: .omitted, time: .shortened)
        case let .error(message):
            return message
        case let .conflicted(paths):
            return "\(paths.count) item\(paths.count == 1 ? "" : "s")"
        default:
            return nil
        }
    }
}

// MARK: - App-wide Notifications

extension Notification.Name {
    static let importSkills = Notification.Name("com.jaredatch.pensieve.importSkills")
}

private struct AddSkillFromGitHubActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct DeleteSelectedSkillActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SkillDetailWindowIsKeyKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var addSkillFromGitHub: (() -> Void)? {
        get { self[AddSkillFromGitHubActionKey.self] }
        set { self[AddSkillFromGitHubActionKey.self] = newValue }
    }

    var deleteSelectedSkill: (() -> Void)? {
        get { self[DeleteSelectedSkillActionKey.self] }
        set { self[DeleteSelectedSkillActionKey.self] = newValue }
    }

    /// Whether the window showing the skill is key — false while a sheet in it (New Skill, a confirmation,
    /// the unsaved-changes sheet) holds the keyboard.
    var skillDetailWindowIsKey: Bool? {
        get { self[SkillDetailWindowIsKeyKey.self] }
        set { self[SkillDetailWindowIsKeyKey.self] = newValue }
    }
}

/// The File › New Skill item as a `View`, so its enabled state observes the library. This wrapper
/// remains from macOS 14, when a `Commands` body did not track `@Observable` reads (that arrived in
/// macOS 15), but a view body did.
private struct NewSkillCommand: View {
    let library: SkillLibraryViewModel

    var body: some View {
        Button("New Skill") {
            library.showCreateSheet = true
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(library.addsFenced)
    }
}

/// File › Save (⌘S) writes the unsaved draft. Its `View` wrapper remains from macOS 14 to observe
/// the library, like New Skill above. Disabled while nothing is unsaved, and while the unsaved-changes
/// sheet is up: a ⌘S under the sheet would answer the question out from under it and make Don't Save keep the
/// changes (batch Layer-2).
private struct SaveSkillCommand: View {
    let library: SkillLibraryViewModel

    var body: some View {
        Button("Save") {
            library.saveUnsavedDrafts()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(isDisabled)
    }

    /// The fingerprint is not observed (see `lastWrittenBody`), so a move under a retained draft — an external
    /// change, a Revert, the app's own write — re-evaluates the enabled state through these two signals.
    @MainActor private var isDisabled: Bool {
        _ = library.reloadToken
        _ = library.appWriteRevision
        return !library.hasUnsavedChanges || library.pendingUnsavedChanges != nil
    }
}

/// When File › Delete Skill (⌘⌫) is enabled: a skill is shown and its window is key. Under a sheet the item
/// stands down, so ⌘⌫ reaches the sheet's text field as delete-to-line-start (34.2-m).
enum DeleteSkillCommandRule {
    static func isEnabled(hasAction: Bool, windowIsKey: Bool?) -> Bool {
        hasAction && windowIsKey == true
    }
}

/// File › Delete Skill (⌘⌫): the toolbar's Delete moved into the More menu, whose items are never key
/// equivalents, so the shortcut lives here and reaches the shown skill through a focused value
/// the detail sets while one skill is on screen. Disabled with no skill shown, and while a sheet in that window
/// is key (`DeleteSkillCommandRule`).
private struct DeleteSkillCommand: View {
    @FocusedValue(\.deleteSelectedSkill) private var deleteSelectedSkill
    @FocusedValue(\.skillDetailWindowIsKey) private var detailWindowIsKey

    var body: some View {
        Button("Delete Skill") {
            deleteSelectedSkill?()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!DeleteSkillCommandRule.isEnabled(hasAction: deleteSelectedSkill != nil,
                                                    windowIsKey: detailWindowIsKey))
    }
}

/// File › Import from Folder… as a `View`, for the same reason as `NewSkillCommand`.
/// Observed by ContentView.importFromFolder (PLAN-30 / 30.2).
private struct ImportFromFolderCommand: View {
    let library: SkillLibraryViewModel

    var body: some View {
        Button("Import from Folder…") {
            NotificationCenter.default.post(name: .importSkills, object: nil)
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(library.addsFenced)
    }
}

private struct GitHubInstallCommands: Commands {
    let library: SkillLibraryViewModel
    let runtime: AppRuntime

    var body: some Commands {
        CommandGroup(after: .newItem) {
            GitHubInstallCommand(library: library)
            CheckAllSkillUpdatesCommand(runtime: runtime)
        }
    }
}

/// The focused value is nil with no key window; the fence disables the item for the same reason
/// as `NewSkillCommand`.
private struct GitHubInstallCommand: View {
    let library: SkillLibraryViewModel
    @FocusedValue(\.addSkillFromGitHub) private var addSkillFromGitHub

    var body: some View {
        Button("Add Skill from GitHub…") {
            addSkillFromGitHub?()
        }
        .disabled(addSkillFromGitHub == nil || library.addsFenced)
    }
}

final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannelPolicy.allowedChannels(
            betaOptIn: defaults.bool(forKey: UpdateChannelPolicy.betaUpdatesEnabledKey)
        )
    }
}
