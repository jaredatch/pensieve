import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

/// The detail header's vertical rhythm against the Overview frames (#22): a linked skill's header runs from
/// the toolbar to 16 below its tags row, on 8 pt gaps with the repo row a 16 pt box. The frames put the banner
/// 143 below the toolbar with a 13 pt tags row; the token field sets 14, so the app's header is 144.
@MainActor
final class SkillDetailHeaderLayoutTests: XCTestCase {
    func testALinkedSkillsHeaderMatchesTheFramesRhythm() {
        let base = NSTemporaryDirectory() + "SkillDetailHeaderLayoutTests-\(UUID().uuidString)"
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: FileService(), baseDir: base))
        let skill = Skill(name: "basecamp", directoryName: "basecamp")
        skill.skillDescription = String(repeating: "Interact with Basecamp via the Basecamp CLI. ", count: 8)
        let provenance = SkillProvenance(installedAt: nil, updatedAt: nil, trackedRef: "main", shortCommit: "d3cc757",
                                         repositoryURL: URL(string: "https://github.com/basecamp/basecamp-cli"),
                                         skillURL: nil, localEditNote: nil, checkError: nil, updateAvailable: false)
        let header = SkillDetailHeader(skill: skill, provenance: provenance, tagsInUse: [], syncConflicted: false,
                                       canResolve: false,
                                       driftError: nil, isChecking: false, library: library,
                                       onResolve: {}, onCommitTags: { _ in })
        let host = NSHostingView(rootView: header.frame(width: 644))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 644, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let title = NSHostingView(rootView: Text("basecamp").font(DesignTokens.detailTitle)).fittingSize.height
        // 16 top · title · 8 · repo 16 · 8 · two description lines 32 · 8 · tags 14 · 16 below.
        let expected = 16 + title + 8 + 16 + 8 + 32 + 8 + 14 + 16
        XCTAssertEqual(host.fittingSize.height, expected, accuracy: 0.5)
    }

    func testExpandedDescriptionUsesItsNaturalHeightInsideOnlyTheColumnScroller() throws {
        let fixture = host(descriptionLayout(expanded: true))
        defer { fixture.window.close() }
        let scroller = try XCTUnwrap(scrollViews(in: fixture.host).first)

        XCTAssertEqual(scrollViews(in: fixture.host).count, 1)
        XCTAssertGreaterThan(scrollRange(of: scroller), 100)
    }

    func testExpandingALongDescriptionDoesNotMoveTheSplitViewOrResizeItsWindow() throws {
        let model = DescriptionExpansionModel()
        let fixture = hostSplitView(model: model, placement: .insideColumnScroller)
        defer { fixture.window.close() }
        let originalFrame = fixture.window.frame
        let originalColumns = try XCTUnwrap(
            waitForColumnFrames(in: fixture.window, count: 3),
            "split-view columns did not finish their initial layout"
        )

        model.expanded = true
        XCTAssertTrue(TestWait.until(poll: {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
        }, condition: {
            guard let probe = pageProbe(in: fixture.window),
                  let scroller = nearestScrollView(to: probe) else { return false }
            return scrollRange(of: scroller) > 100
        }), "expanded description layout did not settle")
        let expandedColumns = try XCTUnwrap(
            waitForColumnFrames(in: fixture.window, count: 3),
            "split-view columns did not finish their expanded layout"
        )

        XCTAssertEqual(fixture.window.frame, originalFrame)
        for role in SplitColumnRole.allCases {
            assertEqual(expandedColumns[role], originalColumns[role], role: role)
        }
    }

    private func descriptionLayout(expanded: Bool) -> AnyView {
        AnyView(SkillDetailScrollLayout(skillID: UUID(), contentOwnsScroller: false) {
            SkillDescriptionText(text: Self.longDescription, expanded: expanded)
                .padding(.horizontal, Spacing.lg)
        } tabContent: {
            Color.clear.frame(height: 40)
        })
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

    private func hostSplitView(
        model: DescriptionExpansionModel,
        placement: DescriptionPlacement
    ) -> (controller: NSHostingController<DescriptionSplitViewHarness>, window: NSWindow) {
        let controller = NSHostingController(rootView: DescriptionSplitViewHarness(model: model, placement: placement))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        _ = waitForColumnFrames(in: window, count: 3)
        return (controller, window)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = [view].compactMap { $0 as? NSScrollView }
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    private func scrollRange(of scrollView: NSScrollView) -> CGFloat {
        max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
    }

    private func waitForColumnFrames(
        in window: NSWindow,
        count: Int,
        timeout: Duration = .seconds(30)
    ) -> [SplitColumnRole: NSRect]? {
        var frames: [SplitColumnRole: NSRect] = [:]
        let complete = TestWait.until(timeout: timeout, poll: {
            window.contentView?.layoutSubtreeIfNeeded()
        }, condition: {
            frames = splitColumnProbes(in: window).reduce(into: [:]) { result, probe in
                guard let contentView = window.contentView else { return }
                result[probe.role] = probe.convert(probe.bounds, to: contentView)
            }
            return frames.count == count
        })
        return complete ? frames : nil
    }

    private func splitColumnProbes(in window: NSWindow) -> [SplitColumnProbeView] {
        guard let contentView = window.contentView else { return [] }
        return views(in: contentView).compactMap { $0 as? SplitColumnProbeView }
    }

    private func pageProbe(in window: NSWindow) -> DescriptionPageProbeView? {
        guard let contentView = window.contentView else { return nil }
        return views(in: contentView).compactMap { $0 as? DescriptionPageProbeView }.first
    }

    private func nearestScrollView(to view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }

    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    private func assertEqual(_ actual: NSRect?, _ expected: NSRect?, role: SplitColumnRole) {
        guard let actual, let expected else {
            XCTFail("Missing \(role) column frame")
            return
        }
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.5, "\(role) moved horizontally")
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.5, "\(role) moved vertically")
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "\(role) changed width")
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, "\(role) changed height")
    }

    private static var longDescription: String {
        (1...40).map { "Line \($0): a long skill description expands with the rest of the detail page." }
            .joined(separator: "\n")
    }
}

@MainActor
@Observable
private final class DescriptionExpansionModel {
    var expanded = false
}

private enum DescriptionPlacement {
    case insideColumnScroller
    case aboveColumnScroller
}

private enum SplitColumnRole: CaseIterable {
    case sidebar
    case content
    case detail
}

@MainActor
private struct DescriptionSplitViewHarness: View {
    @Bindable var model: DescriptionExpansionModel
    let placement: DescriptionPlacement

    var body: some View {
        NavigationSplitView {
            column(.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        } content: {
            column(.content)
                .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
        } detail: {
            detail
                .overlay { SplitColumnProbe(role: .detail) }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private func column(_ role: SplitColumnRole) -> some View {
        SplitColumnProbe(role: role)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var detail: some View {
        switch placement {
        case .insideColumnScroller:
            pageLayout(showsDescription: true)
        case .aboveColumnScroller:
            VStack(spacing: 0) {
                description
                pageLayout(showsDescription: false)
            }
        }
    }

    private func pageLayout(showsDescription: Bool) -> some View {
        SkillDetailScrollLayout(skillID: Self.skillID, contentOwnsScroller: false) {
            if showsDescription { description }
        } tabContent: {
            DescriptionPageProbe().frame(height: 40)
        }
    }

    private var description: some View {
        SkillDescriptionText(text: Self.longDescription, expanded: model.expanded)
            .id(model.expanded)
            .padding(.horizontal, Spacing.lg)
    }

    private static let skillID = UUID()
    private static let longDescription = (1...40)
        .map { "Line \($0): a long skill description expands with the rest of the detail page." }
        .joined(separator: "\n")
}

private final class SplitColumnProbeView: NSView {
    let role: SplitColumnRole

    init(role: SplitColumnRole) {
        self.role = role
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private struct SplitColumnProbe: NSViewRepresentable {
    let role: SplitColumnRole

    func makeNSView(context: Context) -> SplitColumnProbeView {
        SplitColumnProbeView(role: role)
    }

    func updateNSView(_ nsView: SplitColumnProbeView, context: Context) {}
}

private final class DescriptionPageProbeView: NSView {}

private struct DescriptionPageProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> DescriptionPageProbeView { DescriptionPageProbeView() }
    func updateNSView(_ nsView: DescriptionPageProbeView, context: Context) {}
}
