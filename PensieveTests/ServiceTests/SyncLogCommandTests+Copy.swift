import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
extension SyncLogCommandTests {
    func testConflictWindowErrorCanBeSelectedAndRuns() async throws {
        let h = try SyncLogCommandFixture()
        let runtime = try await SyncFailureViewFixture(reason: "fixture")
        defer { try? h.disk.remove(); runtime.cleanup() }
        let model = h.window(h.git(.windowReturn), installer: nil)
        let window = SyncFailureViewHost.mount(AnyView(ConflictResolutionView(model: model, onDismiss: {})
            .environment(runtime.runtime).modelContainer(h.container)))
        defer { SyncFailureViewHost.close(window) }
        await TestWait.until(failureMessage: "Conflict error did not render") {
            SyncFailureViewHost.texts(in: window.contentView!).contains { $0.contains("in Terminal for the details.") }
        }
        let texts = SyncFailureViewHost.texts(in: window.contentView!)
        let rendered = texts.first { $0.contains("in Terminal for the details.") } ?? ""
        h.assertMessage(rendered, endsWith: SyncLogCommandFixture.sentence(
            Bundle.main.bundlePath + "/Contents/Helpers/pensieve"))
        XCTAssertEqual(selectable(rendered, in: window.contentView!), true)
        XCTAssertEqual(selectable("Resolve sync conflicts", in: window.contentView!), false)
        let popover = SyncFailureViewHost.mount(AnyView(SyncFailurePopover(reason: rendered, canSyncNow: true,
            onSync: {}, onOpenSyncSettings: {})))
        defer { SyncFailureViewHost.close(popover) }
        await TestWait.until(failureMessage: "Popover reason did not render") {
            SyncFailureViewHost.texts(in: popover.contentView!).contains(rendered)
        }
        XCTAssertEqual(selectable(rendered, in: popover.contentView!), true)
        await h.assertRuns(rendered)
    }

    // A selectable rendered Text owns SwiftUI's selection child. Inspect that live subtree,
    // with the popover and headline as positive and negative controls for SDK changes.
    private func selectable(_ text: String, in host: NSView) -> Bool? {
        func hasSelectionChild(_ node: _ViewDebug.Data) -> Bool {
            let mirror = Mirror(reflecting: node)
            let properties = mirror.descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
            if let value = properties[.value],
               String(reflecting: type(of: value)) == "SwiftUI.SelectableTextChildView" { return true }
            let children = mirror.descendant("childData") as? [_ViewDebug.Data] ?? []
            return children.contains(where: hasSelectionChild)
        }
        for node in RenderedViewTestSupport.nodes(in: host) {
            let properties = Mirror(reflecting: node).descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
            guard let value = properties[.value] as? Text,
                  RenderedViewTestSupport.strings(in: value).contains(text) else { continue }
            return hasSelectionChild(node)
        }
        return nil
    }
}
