import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    func hostSheet(_ model: UpdatesViewModel, fixture: UpdateReviewFixture) -> NSWindow {
        let root = Color.clear.sheet(isPresented: Binding(get: { model.isPresented }, set: { model.isPresented = $0 })) {
            UpdatesView(model: model, onViewChanges: { _ in })
        }.modelContainer(fixture.container)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentView = NSHostingView(rootView: root)
        main.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: true)
        main.orderFront(nil)
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
        XCTAssertEqual(shown.selection, .mixed)
        XCTAssertEqual(shown.selectionLabel, "1 of 2 selected")
        XCTAssertEqual(shown.rows.map(\.name), ["Plain", "Drifted"])
        XCTAssertEqual(shown.rows.map(\.source), [" — example/repository", " — example/repository"])
        XCTAssertEqual(shown.rows.map(\.commits), ["1111111 → 2222222", "1111111 → 2222222"])
        XCTAssertEqual(shown.rows.map(\.age), ["", ""], "Install time is not the installed commit date")
        XCTAssertNil(shown.rows[0].localEditsCopy)
        XCTAssertEqual(shown.rows[1].localEditsCopy, "You have local edits to this skill. Updating replaces them.")
        XCTAssertEqual(shown.rows[1].replaceTitle, "Replace my local edits")
        XCTAssertFalse(shown.rows[1].replacementConfirmed)
        XCTAssertTrue(shown.rows.allSatisfy { $0.changesTitle == "View Changes" && $0.changesEnabled })
    }

    func assertCommitDatesAndSelectionBindings(_ model: UpdatesViewModel, rows: [UpdatesRow]) {
        let unknown = rows[0]
        XCTAssertEqual(ViewChangesPresentation.subtitle(unknown), "example/repository · 1111111 → 2222222")
        for (date, copy) in [(0.0, "3 days newer"), (2 * 86_400.0, "1 day newer")] {
            let known = UpdatesRow(
                id: unknown.id, skillName: unknown.skillName, slug: unknown.slug,
                installedCommitDate: Date(timeIntervalSince1970: date), installedCommit: unknown.installedCommit,
                updateDate: unknown.updateDate, upstreamCommit: unknown.upstreamCommit, upstreamTree: unknown.upstreamTree,
                repositoryDisplay: unknown.repositoryDisplay, repositoryPath: unknown.repositoryPath,
                driftedLocally: false, compareURL: unknown.compareURL
            )
            model.rows[0] = known
            XCTAssertEqual(UpdatesSheetPresentation(model).rows[0].age, " · " + copy)
            XCTAssertEqual(ViewChangesPresentation.subtitle(known), "example/repository · 1111111 → 2222222 · " + copy)
        }
        model.rows[0] = unknown
        let sources = UpdatesSheetPresentation(model).selectionSources
        sources[1].wrappedValue = true
        XCTAssertTrue(sources[1].wrappedValue, "A collection binding reads the accepted model change")
        sources[1].wrappedValue = false
        model.isApplying = true
        sources[0].wrappedValue = false
        XCTAssertTrue(sources[0].wrappedValue, "A rejected write cannot change the checkbox's model value")
        model.isApplying = false
    }

}
