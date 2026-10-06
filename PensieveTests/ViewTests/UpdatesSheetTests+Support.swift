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
}
