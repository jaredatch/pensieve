import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension AppRuntimeTests {
    func dismissLaunchWizard(in window: NSWindow) async throws {
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.animationBehavior = .none
        let root = try XCTUnwrap(sheet.contentView)
        func renderedStrings() -> [String] {
            RenderedViewTestSupport.values(in: root).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings)
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        await TestWait.until(failureMessage: "The launch wizard did not render its Skip action", diagnostics: {
            renderedStrings().description
        }, {
            renderedStrings().contains("Skip")
        })
        XCTAssertTrue(sheet.performKeyEquivalent(with: escape), "The launch wizard did not handle Escape for its Skip action")
        await TestWait.until(failureMessage: "The skipped launch wizard did not detach") {
            window.attachedSheet == nil
        }
    }

    final class StubWatcher: FileWatchServiceProtocol {
        var onChange: (String) -> Void = { _ in }
        var onStart: () -> Void = {}
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() -> Bool {
            onStart()
            startCount += 1
            return true
        }
        func stop() {
            stopCount += 1
        }
    }

    struct StubDetection: AgentDetectionServiceProtocol {
        func isInstalled(_ platform: PlatformTarget) -> Bool { false }
        func installedPlatforms() -> [PlatformTarget] { [] }
    }

    struct NoopDeployReconciler: DeployReconciling {
        func reconcile(root: String) throws -> ReconcileOutcome { ReconcileOutcome() }
    }

    final class RecordingDeployReconciler: DeployReconciling {
        private(set) var calls = 0
        func reconcile(root: String) throws -> ReconcileOutcome {
            calls += 1
            return ReconcileOutcome()
        }
    }

    struct NoopLedgerReconciler: CategoryReconcilerProtocol,
        IntentReconcilerProtocol {
        func reconcileWaitingRemovals(context: ModelContext) -> BatchResult { BatchResult() }
        func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
            reconcile(context: context)
        }
        func reconcile(context: ModelContext) -> BatchResult { BatchResult() }
    }

    final class RecordingLedgerReconciler: CategoryReconcilerProtocol,
        IntentReconcilerProtocol {
        func reconcileWaitingRemovals(context: ModelContext) -> BatchResult { BatchResult() }
        func reconcileRemovingProject(_ projectID: UUID, preservingProjects: Set<UUID>, context: ModelContext) -> BatchResult {
            reconcile(context: context)
        }
        private(set) var calls = 0
        func reconcile(context: ModelContext) -> BatchResult {
            calls += 1
            return BatchResult()
        }
    }

    @MainActor
    final class WindowModels {
        let library: SkillLibraryViewModel
        let platformVM: PlatformViewModel
        let syncModel: SyncModel
        init(runtime: AppRuntime) {
            library = runtime.library
            platformVM = runtime.platformVM
            syncModel = runtime.syncModel
        }
    }

    struct RuntimeHarness {
        let runtime: AppRuntime
        let context: ModelContext
        let watcher: StubWatcher
        let launchIngestLockPath: String
        let paths: AppRuntimePaths
    }

    func makeRuntime(
        defaultsLabel: String = "runtime",
        watcher: StubWatcher = StubWatcher(),
        manifestSaves: ManifestSaveModel? = nil,
        launchCalls: (() -> Void)? = nil,
        launchBackfill: ((ModelContext) -> Void)? = nil,
        launchOutcome: LaunchReconcileOutcome = LaunchReconcileOutcome(
            rebuild: RebuildResult(),
            migrationRan: false,
            ingestedHeadStamp: "launch"
        ),
        launchRetryOutcome: LaunchReconcileOutcome? = nil,
        launchRetryOutcomes: [LaunchReconcileOutcome]? = nil,
        launchAttempt: ((Bool) -> Void)? = nil,
        hasRemoteConfigured: (() -> Bool)? = nil,
        deployReconciler: DeployReconciling = NoopDeployReconciler(),
        categoryReconciler: CategoryReconcilerProtocol = NoopLedgerReconciler(),
        launchIngestLockPath: String? = nil
    ) throws -> RuntimeHarness {
        let paths = try AppRuntimePaths.temporary(named: "AppRuntimeTests")
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = try isolatedDefaults(defaultsLabel)
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir, storeRoot: TestPaths.storeRoot),
            fileWatchService: watcher, manifestRoot: manifestSaves?.root ?? TestPaths.storeRoot, manifestSaves: manifestSaves)
        let platformVM = neutralPlatformVM()
        let launchAttempts = Counter()
        let convergence = PostSyncConvergence(
            root: "/tmp/AppRuntimeTests", deployReconciler: deployReconciler,
            contextFactory: { ModelContext(container) }, categoryReconciler: categoryReconciler,
            intentReconciler: NoopLedgerReconciler(), auditLog: { _, _ in })
        let runtime = try AppRuntime(
            container: container,
            platformVM: platformVM,
            library: library,
            defaults: defaults,
            launchReconcile: { _, migrated in
                let launchAttemptCount = launchAttempts.increment() - 1
                launchCalls?()
                launchAttempt?(migrated)
                if launchAttemptCount > 0 {
                    if let launchRetryOutcomes {
                        return launchRetryOutcomes[min(launchAttemptCount - 1, launchRetryOutcomes.count - 1)]
                    }
                    if let launchRetryOutcome { return launchRetryOutcome }
                }
                return launchOutcome
            },
            launchBackfill: { launchBackfill?($0) },
            hasRemoteConfigured: hasRemoteConfigured,
            postSyncConvergence: convergence,
            launchIngestRetryNanoseconds: 10_000_000,
            launchIngestLockPath: launchIngestLockPath ?? paths.syncLockPath,
            paths: paths,
            gitUsabilityProbe: { .usable }
        )
        return RuntimeHarness(
            runtime: runtime,
            context: ModelContext(container), watcher: watcher,
            launchIngestLockPath: launchIngestLockPath ?? paths.syncLockPath, paths: paths)
    }

    func hostMainWindow(runtime: AppRuntime) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(PensieveApp.makeContentView(runtime: runtime)
            .environment(runtime).modelContainer(runtime.container)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func neutralPlatformVM() -> PlatformViewModel {
        return PlatformViewModel(
            linkService: TestPaths.linkService(fileService: FileService()),
            cursorCompiler: TestPaths.cursorCompiler(fileService: FileService()),
            agentDetection: StubDetection(),
            deployStateStore: .memoryBacked, skillsDirectory: TestPaths.skillsDir
        )
    }

}
