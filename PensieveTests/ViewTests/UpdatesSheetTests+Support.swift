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
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = .all
        main.contentView = host
        main.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: true)
        main.orderFront(nil)
        addTeardownBlock {
            await MainActor.run {
                if let sheet = main.attachedSheet { main.endSheet(sheet); sheet.close(); sheet.contentView = nil }
                main.close()
                main.contentView = nil
                main.toolbar = nil
            }
        }
        return main
    }

    func attachedSheet(to main: NSWindow, model: UpdatesViewModel) async throws -> NSWindow {
        await TestWait.until(failureMessage: "The production Updates sheet did not attach and settle") {
            main.attachedSheet != nil && model.loadPhase != .idle && !model.isLoading
                && !(main.attachedSheet?.contentView?.bounds.isEmpty ?? true)
        }
        return try XCTUnwrap(main.attachedSheet)
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
