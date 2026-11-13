import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    func hostSheet(_ model: UpdatesViewModel, fixture: UpdateReviewFixture) async throws -> NSWindow {
        let root = NavigationSplitView {
            Color.clear.navigationSplitViewColumnWidth(180)
        } content: {
            Color.clear.navigationSplitViewColumnWidth(280)
        } detail: {
            Color.clear.toolbar {
                ToolbarItem(placement: .primaryAction) { Button("New Skill", systemImage: "plus", action: {}) }
            }
        }
        .sheet(isPresented: Binding(get: { model.isPresented }, set: { model.isPresented = $0 })) {
            UpdatesView(model: model, onViewChanges: { _ in })
        }
        .modelContainer(fixture.container)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        main.toolbarStyle = .unified
        main.isReleasedWhenClosed = false
        main.animationBehavior = .none
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = .all
        main.contentView = host
        main.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: true)
        main.orderFront(nil)
        addTeardownBlock { [weak main] in
            await Self.closeSheetHost(main, model: model)
        }
        return main
    }

    static func closeSheetHost(_ main: NSWindow?, model: UpdatesViewModel) async {
        let sheet = main?.attachedSheet
        model.isPresented = false
        guard let main, main.contentView != nil else { return }
        await TestWait.until(failureMessage: "The dismissed sheet did not detach before host cleanup",
                             diagnostics: { "main=\(main.frame), sheet=\(String(describing: main.attachedSheet?.frame))" }, {
            main.attachedSheet == nil
        })
        sheet?.contentView = nil
        main.close()
        main.contentView = nil
        main.toolbar = nil
    }

    func attachedSheet(to main: NSWindow, model: UpdatesViewModel) async throws -> NSWindow {
        await TestWait.until(failureMessage: "The production Updates sheet did not attach and settle") {
            main.attachedSheet != nil && model.loadPhase != .idle && !model.isLoading
                && !(main.attachedSheet?.contentView?.bounds.isEmpty ?? true)
        }
        let sheet = try XCTUnwrap(main.attachedSheet)
        sheet.animationBehavior = .none
        return sheet
    }

    func completion(for skill: Skill) throws -> SkillUpdateCompletion {
        SkillUpdateCompletion(skillID: skill.id, name: skill.name, skillDescription: skill.skillDescription,
                              installedOriginData: try XCTUnwrap(skill.installedOriginData), updatedAt: Date())
    }
    func assertFrameCopy(_ shown: UpdatesSheetPresentation) {
        XCTAssertEqual(shown.title, "Skill Updates Available")
        XCTAssertEqual(shown.subtitle, "Review the changes before updating.")
        XCTAssertEqual(shown.selectionSources.map(\.wrappedValue), [true, false], "Sources carry the native mixed state")
        XCTAssertEqual(shown.selectionLabel, "1 of 2 selected")
        XCTAssertEqual(shown.rows.map(\.name), ["Plain", "Drifted"])
        XCTAssertEqual(shown.rows.map(\.source), [" — example/repository", " — example/repository"])
        XCTAssertEqual(shown.rows.map(\.commits), ["1111111 → 2222222", "1111111 → 2222222"])
        XCTAssertNil(shown.rows[0].localEditsCopy)
        XCTAssertEqual(shown.rows[1].localEditsCopy, "You have local edits to this skill. Updating replaces them.")
        XCTAssertEqual(shown.rows[1].replaceTitle, "Replace my local edits")
        XCTAssertFalse(shown.rows[1].replacementConfirmed)
        XCTAssertTrue(shown.rows.allSatisfy { $0.changesTitle == "View Changes" && $0.changesEnabled })
    }

    func assertSelectionBindings(_ model: UpdatesViewModel, rows: [UpdatesRow], library: SkillLibraryViewModel) {
        let unknown = rows[0]
        XCTAssertEqual(ViewChangesPresentation.subtitle(unknown), "example/repository · 1111111 → 2222222")
        assertSelectionObservesRows(model, rows: rows, library: library)
        let sources = UpdatesSheetPresentation(model).selectionSources
        sources[1].wrappedValue = true
        XCTAssertTrue(sources[1].wrappedValue, "A collection binding reads the accepted model change")
        sources[1].wrappedValue = false
        model.isApplying = true
        sources[0].wrappedValue = false
        XCTAssertTrue(sources[0].wrappedValue, "A rejected write cannot change the checkbox's model value")
        model.isApplying = false
    }

    func assertSelectionObservesRows(_ model: UpdatesViewModel, rows: [UpdatesRow], library: SkillLibraryViewModel) {
        let readers: [(String, () -> Void)] = [
            ("selectable rows", { _ = model.selectableSkillIDs }),
            ("selected count", { _ = model.selectedCount }),
            ("Update enabled", { _ = model.canApply }),
            ("row selectable", { _ = model.isSelectable(rows[0]) }),
            ("loaded hand-off", { model.present(selecting: rows[0].id, library: library) })
        ]
        for (name, read) in readers {
            model.rows = rows
            let changes = UpdateReviewRecorder<Bool>()
            withObservationTracking(read, onChange: { changes.append(true) })
            model.rows = [rows[1]]
            XCTAssertEqual(changes.values, [true], "\(name) must observe row removal")
            XCTAssertEqual(model.selectedCount, 0)
            XCTAssertFalse(model.canApply)
            XCTAssertFalse(model.isSelectable(rows[0]))
        }
        model.rows = rows
    }

}

extension UpdatesSheetTests {
    func rowHost(_ model: UpdatesViewModel, index: Int, fixture: UpdateReviewFixture) -> NSHostingView<AnyView> {
        let shown = UpdatesSheetPresentation(model).rows[index]
        let host = NSHostingView(rootView: AnyView(UpdatesRowView(
            model: model, shown: shown, context: fixture.context, onViewChanges: { _ in }
        ).frame(width: DesignTokens.updatesSheetWidth)))
        mountRenderHost(host)
        return host
    }

    func sheetRenderHost(_ model: UpdatesViewModel, fixture: UpdateReviewFixture) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(UpdatesView(model: model, onViewChanges: { _ in })
            .modelContainer(fixture.container).buttonStyle(RenderedViewTestSupport.AvailabilityStyle())))
        mountRenderHost(host)
        return host
    }

    private func mountRenderHost(_ host: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: host.fittingSize.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock {
            await MainActor.run {
                host.rootView = AnyView(EmptyView())
                window.close()
                window.contentView = nil
            }
        }
    }

    func renderedStrings(_ host: NSView) -> [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }.flatMap(RenderedViewTestSupport.strings)
    }

    func textFrame(_ string: String, in host: NSView, contains: Bool = false) throws -> CGRect {
        let matches = RenderedViewTestSupport.layoutValues(in: host).filter { element in
            guard let text = element.value as? Text else { return false }
            let strings = RenderedViewTestSupport.strings(in: text)
            return contains ? strings.joined().contains(string) : strings == [string]
        }
        let element = try XCTUnwrap(matches.first { $0.hasOwnFrame } ?? matches.first,
                                   "The mounted view must render \(string); got \(renderedStrings(host))")
        return try XCTUnwrap(element.frame, "Rendered text must carry its layout frame")
    }

    func labelFrame(in host: NSView) throws -> CGRect {
        let images = RenderedViewTestSupport.layoutValues(in: host).filter {
            ($0.value as? Image) == Image(systemName: "checkmark.circle.fill")
        }
        let icon = try XCTUnwrap(images.first { $0.hasOwnFrame } ?? images.first)
        return try textFrame("Updated", in: host).union(XCTUnwrap(icon.frame))
    }

    func assertUpdatedRow(_ host: NSView, name: String) throws -> CGRect {
        let strings = renderedStrings(host)
        XCTAssertTrue(strings.joined().contains(name), "The production row must render its name")
        XCTAssertEqual(strings.filter { $0 == "Updated" }.count, 1)
        XCTAssertFalse(strings.contains("View Changes"), "Updated replaces View Changes")
        let images = RenderedViewTestSupport.values(in: host).compactMap { $0 as? Image }
        XCTAssertTrue(images.contains(Image(systemName: "checkmark.circle.fill")),
                      "Updated must include its checkmark; images=\(images)")
        return try textFrame("Updated", in: host)
    }

    func assertDismissButton(_ title: String, enabled: Bool, model: UpdatesViewModel,
                             in host: NSHostingView<AnyView>) async throws {
        // Settle on row results and selection, independently of the dismiss button under test.
        let shown = UpdatesSheetPresentation(model)
        let expected = [shown.title] + [shown.selectionLabel].compactMap { $0 }
            + shown.rows.compactMap(\.statusText)
        await TestWait.until(failureMessage: "The sheet's rendered dismiss button must settle", diagnostics: {
            self.renderedStrings(host).description
        }, {
            let strings = self.renderedStrings(host)
            return expected.allSatisfy(strings.contains)
        })
        XCTAssertTrue(renderedStrings(host).contains("Skill Updates Available"))
        XCTAssertTrue(renderedStrings(host).contains(title), "The dismiss button must read \(title)")
        XCTAssertEqual(RenderedViewTestSupport.buttonIsEnabled(title, in: host), enabled)
        XCTAssertFalse(renderedStrings(host).contains(title == "Close" ? "Cancel" : "Close"))
    }

    func renderedButtonEnabled(_ title: String, in root: NSView) throws -> Bool {
        // Native button styles consume Button itself; its rendered title inherits the
        // enabled environment after the production control's disabled modifier.
        let titles = RenderedViewTestSupport.layoutValues(in: root).filter {
            guard let text = $0.value as? Text else { return false }
            return RenderedViewTestSupport.strings(in: text) == [title]
        }
        let label = try XCTUnwrap(titles.first { $0.hasOwnFrame } ?? titles.first,
                                  "The mounted row must render the \(title) button")
        return try XCTUnwrap(label.isEnabled, "The rendered button must carry its enabled environment")
    }
}
