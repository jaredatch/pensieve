import AppKit
import Observation
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillDetailScrollLayoutTests: XCTestCase {
    func testTheColumnScrollViewContainsBothTheChromeAndTabContent() throws {
        let layout = SkillDetailScrollLayout(
            skillID: UUID(),
            contentOwnsScroller: false
        ) {
            DetailScrollProbe(role: .chrome).frame(height: 80)
        } tabContent: {
            DetailScrollProbe(role: .content).frame(height: 800)
        }

        let fixture = host(AnyView(layout))
        defer { fixture.window.close() }
        let probes = probeViews(in: fixture.host)
        let chrome = try XCTUnwrap(probes.first { $0.role == .chrome })
        let content = try XCTUnwrap(probes.first { $0.role == .content })
        let chromeScroller = try XCTUnwrap(nearestScrollView(to: chrome))

        XCTAssertTrue(chromeScroller === nearestScrollView(to: content))
        XCTAssertEqual(scrollViews(in: fixture.host).count, 1)
    }

    func testSourcePresentationsKeepTheirScrollerOutOfTheColumnScroller() throws {
        let fixture = sourceLayout(chromeHeight: 80)
        defer { fixture.window.close() }
        let probes = probeViews(in: fixture.host)
        let chrome = try XCTUnwrap(probes.first { $0.role == .chrome })
        let content = try XCTUnwrap(probes.first { $0.role == .content })
        let columnScroller = try XCTUnwrap(nearestScrollView(to: chrome))
        let sourceScroller = try XCTUnwrap(nearestScrollView(to: content))

        XCTAssertFalse(columnScroller === sourceScroller)
        XCTAssertEqual(scrollViews(in: fixture.host).count, 2)
        XCTAssertLessThanOrEqual(scrollRange(of: columnScroller), 0.5)
    }

    func testSkillSourcePresentationUsesItsOwnScroller() {
        let presentation = SkillContentPresentation.resolve(
            selectedFile: "SKILL.md", requestedMode: .source, inventory: .empty
        )

        XCTAssertTrue(DetailView.contentOwnsScroller(tab: .content, presentation: presentation))
    }

    func testNonMarkdownPresentationUsesItsOwnScroller() {
        var inventory = SkillBundleInventory()
        inventory.files = [
            .init(relativePath: "SKILL.md", bytes: 10, tokens: 3),
            .init(relativePath: "scripts/x.sh", bytes: 10, tokens: 3)
        ]
        let presentation = SkillContentPresentation.resolve(
            selectedFile: "scripts/x.sh", requestedMode: .rendered, inventory: inventory
        )

        XCTAssertTrue(DetailView.contentOwnsScroller(tab: .content, presentation: presentation))
    }

    func testOverviewDoesNotUseTheRetainedSourcePresentationsScroller() {
        let presentation = SkillContentPresentation.resolve(
            selectedFile: "SKILL.md", requestedMode: .source, inventory: .empty
        )

        XCTAssertFalse(DetailView.contentOwnsScroller(tab: .overview, presentation: presentation))
    }

    func testDraftLeaveGuardUsesTheSkillFileSourceCondition() {
        let skillSource = SkillContentPresentation.resolve(
            selectedFile: "SKILL.md", requestedMode: .source, inventory: .empty
        )
        let skillRendered = SkillContentPresentation.resolve(
            selectedFile: "SKILL.md", requestedMode: .rendered, inventory: .empty
        )
        var inventory = SkillBundleInventory()
        inventory.files = [
            .init(relativePath: "SKILL.md", bytes: 10, tokens: 3),
            .init(relativePath: "scripts/x.sh", bytes: 10, tokens: 3)
        ]
        let otherFileRequestedRendered = SkillContentPresentation.resolve(
            selectedFile: "scripts/x.sh", requestedMode: .rendered, inventory: inventory
        )

        XCTAssertTrue(DetailView.isEditingSkillSource(tab: .content, presentation: skillSource))
        XCTAssertFalse(DetailView.isEditingSkillSource(tab: .content, presentation: skillRendered))
        XCTAssertFalse(DetailView.isEditingSkillSource(tab: .overview, presentation: skillSource))
        XCTAssertTrue(DetailView.contentOwnsScroller(tab: .content, presentation: otherFileRequestedRendered))
        XCTAssertFalse(DetailView.isEditingSkillSource(tab: .content, presentation: otherFileRequestedRendered))
    }

    func testChangingScrollOwnershipKeepsTheChromeIdentity() throws {
        let model = DetailScrollIdentityModel()
        let fixture = host(AnyView(DetailScrollIdentityHarness(model: model)))
        defer { fixture.window.close() }
        let originalProbes = probeViews(in: fixture.host)
        let originalChrome = try XCTUnwrap(originalProbes.first { $0.role == .chrome })
        let originalContent = try XCTUnwrap(originalProbes.first { $0.role == .content })

        model.contentMode = .source
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        fixture.host.layoutSubtreeIfNeeded()
        let updatedProbes = probeViews(in: fixture.host)
        let updatedChrome = try XCTUnwrap(updatedProbes.first { $0.role == .chrome })
        let updatedContent = try XCTUnwrap(updatedProbes.first { $0.role == .content })

        XCTAssertTrue(originalChrome === updatedChrome)
        XCTAssertTrue(originalContent === updatedContent)
    }

}

extension SkillDetailScrollLayoutTests {
    func testOverviewDeploymentsAndBothHistoriesDoNotOwnVerticalScrollViews() throws {
        let skill = Skill(name: "Example", directoryName: "example")
        let views: [(String, AnyView)] = [
            ("Overview", AnyView(SkillOverviewTab(
                skill: skill,
                snapshot: DetailContentSnapshot(),
                provenance: nil,
                installedCount: 0,
                now: Date(),
                homeDirectory: TestPaths.homeDirectory, skillsDirectory: TestPaths.skillsDir
            ))),
            ("Deployments", try deploymentsTab())
        ] + (try historyTabs())

        for (name, view) in views {
            let fixture = host(view)
            XCTAssertEqual(scrollViews(in: fixture.host).count, 0, "\(name) owns a vertical scroll view")
            fixture.window.close()
        }
    }

    private func deploymentsTab() throws -> AnyView {
        let base = TestTemporaryDirectory.path + "SkillDetailScrollLayoutTests-\(UUID().uuidString)"
        let fileService = DeployRecordingFileService()
        let platformVM = PlatformViewModel(
            fileService: fileService,
            linkService: TestPaths.linkService(fileService: fileService),
            cursorCompiler: TestPaths.cursorCompiler(fileService: fileService),
            agentDetection: EmptyMachineDetection(),
            deployStateStore: DeployStateStore(fileService: fileService, appSupportDir: base),
            skillsDirectory: TestPaths.skillsDir
        )
        let dependencies = DeployIntentDependencies(
            identity: InertMachineIdentity(),
            stateService: InertMachineStateService(),
            root: base,
            writeManifest: { _ in },
            notifier: {},
            lockPath: base + "/sync.lock",
            lockProvider: { _ in nil }
        )
        let container = try AppRuntime.makeContainer(
            configuration: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AnyView(SkillDeploymentsTab(
            skill: Skill(name: "Example", directoryName: "example"),
            snapshot: DetailContentSnapshot(),
            statusIsCurrent: true,
            projects: [],
            platformVM: platformVM,
            addsFenced: false,
            intentDependencies: dependencies,
            machineStates: [],
            localMachineID: InertMachineIdentity.value,
            homeDirectory: TestPaths.homeDirectory,
            onAddProject: {}
        ).modelContainer(container))
    }

    private func historyTabs() throws -> [(String, AnyView)] {
        let base = TestTemporaryDirectory.path + "SkillDetailScrollLayoutTests-\(UUID().uuidString)"
        let skill = Skill(name: "Example", directoryName: "example")
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: FileService(), baseDir: base),
            fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir), manifestRoot: TestPaths.storeRoot
        )
        let history = UpstreamHistoryViewModel(
            readOperation: { _, _, _ in historyResult() },
            localEditsOperation: { _, _, _ in .none },
            localDirectory: { _ in base }
        )
        let installedSkill = installedHistorySkill()
        let installedOrigin = try XCTUnwrap(installedSkill.installedOrigin)
        return [
            ("Authored History", AnyView(SkillHistoryTab(
                skill: skill,
                currentBody: "",
                library: library,
                upstreamHistory: history,
                localRevision: .initial,
                onOpenUpdates: {},
                onUpdateCheck: { _ in },
                git: TestPaths.git,
                store: SkillStore(fileService: FileService(), baseDir: TestPaths.skillsDir),
                workingDir: base
            ))),
            ("Installed History", AnyView(InstalledSkillHistoryView(
                skill: installedSkill, currentBody: "", origin: installedOrigin, updateAvailable: false,
                localRevision: .initial, onOpenUpdates: {}, onUpdateCheck: { _ in }, history: history
            )))
        ]
    }

    func testPreviewOnlyOwnsAScrollViewWhenItsCallerRequestsOne() {
        let sheetFixture = host(AnyView(SkillPreviewView(markdownBody: "# Preview")))
        defer { sheetFixture.window.close() }
        XCTAssertEqual(scrollViews(in: sheetFixture.host).count, 1)

        let detailFixture = host(AnyView(SkillPreviewView(markdownBody: "# Preview", scrolls: false)))
        defer { detailFixture.window.close() }
        XCTAssertEqual(scrollViews(in: detailFixture.host).count, 0)
    }

    func testChangingSkillsReturnsTheColumnToItsInitialScrollPosition() throws {
        let model = DetailScrollIdentityModel()
        let fixture = host(AnyView(DetailScrollIdentityHarness(model: model)))
        defer { fixture.window.close() }
        let initialProbes = probeViews(in: fixture.host)
        let initialChrome = try XCTUnwrap(initialProbes.first { $0.role == .chrome })
        let initialContent = try XCTUnwrap(initialProbes.first { $0.role == .content })
        let initialScroller = try XCTUnwrap(scrollViews(in: fixture.host).first)
        let initialOrigin = initialScroller.contentView.bounds.origin
        initialScroller.contentView.scroll(to: NSPoint(x: initialOrigin.x, y: initialOrigin.y + 160))
        initialScroller.reflectScrolledClipView(initialScroller.contentView)
        XCTAssertNotEqual(initialScroller.contentView.bounds.origin.y, initialOrigin.y)

        model.skillID = UUID()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        fixture.host.layoutSubtreeIfNeeded()
        let resetScroller = try XCTUnwrap(scrollViews(in: fixture.host).first)
        let resetProbes = probeViews(in: fixture.host)

        XCTAssertEqual(resetScroller.contentView.bounds.origin.y, initialOrigin.y, accuracy: 0.5)
        XCTAssertTrue(initialChrome === resetProbes.first { $0.role == .chrome })
        XCTAssertTrue(initialContent === resetProbes.first { $0.role == .content })
    }

    private func host(_ view: AnyView) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 640, height: 480)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func sourceLayout(
        chromeHeight: CGFloat
    ) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let layout = SkillDetailScrollLayout(
            skillID: UUID(),
            contentOwnsScroller: true
        ) {
            DetailScrollProbe(role: .chrome).frame(height: chromeHeight)
        } tabContent: {
            DetailSourceScrollerProbe()
                .frame(maxHeight: .infinity)
        }
        return host(AnyView(layout))
    }

    private func scrollRange(of scrollView: NSScrollView) -> CGFloat {
        max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = [view].compactMap { $0 as? NSScrollView }
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    private func probeViews(in view: NSView) -> [DetailScrollProbeView] {
        let own = [view].compactMap { $0 as? DetailScrollProbeView }
        return own + view.subviews.flatMap(probeViews(in:))
    }

    private func nearestScrollView(to view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }
}

private enum DetailScrollProbeRole {
    case chrome
    case content
}

private final class DetailScrollProbeView: NSView {
    let role: DetailScrollProbeRole

    init(role: DetailScrollProbeRole) {
        self.role = role
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private struct DetailScrollProbe: NSViewRepresentable {
    let role: DetailScrollProbeRole

    func makeNSView(context: Context) -> DetailScrollProbeView {
        DetailScrollProbeView(role: role)
    }

    func updateNSView(_ nsView: DetailScrollProbeView, context: Context) {}
}

private struct DetailSourceScrollerProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let document = DetailScrollProbeView(role: .content)
        document.frame = NSRect(x: 0, y: 0, width: 100, height: 800)
        scrollView.documentView = document
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

@MainActor
@Observable
private final class DetailScrollIdentityModel {
    var skillID = UUID()
    var contentMode: SkillContentPresentation.Mode = .rendered
}

@MainActor
private struct DetailScrollIdentityHarness: View {
    @Bindable var model: DetailScrollIdentityModel

    var body: some View {
        SkillDetailScrollLayout(
            skillID: model.skillID,
            contentOwnsScroller: model.contentMode == .source
        ) {
            DetailScrollProbe(role: .chrome).frame(height: 80)
        } tabContent: {
            DetailScrollProbe(role: .content).frame(height: 1_200)
        }
    }
}
