import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func bodyItem(slug: String) -> ConflictItem {
        ConflictItem(path: "skills/\(slug)/SKILL.md", kind: .body,
                     thisMachine: Data("this body".utf8), otherMachine: Data("other body".utf8))
    }

    /// Read the mounted sheet: grouping assertions alone cannot detect a separate history parser.
    func assertHistoryAction(path: String, slug: String, available: Bool) async {
        do {
            let context = try makeContext()
            let fixture = try GitFailureFixture()
            defer { try? fixture.remove() }
            let runtime = try AppRuntime(container: context.container,
                scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                defaults: isolatedDefaults("conflict-history"), paths: fixture.paths, gitUsabilityProbe: { .licenseNotAccepted })
            await runtime.bootstrapTask.value
            context.insert(Skill(name: "Indexed Skill", directoryName: slug))
            try context.save()
            let engine = StubResolutionEngine()
            engine.inspections = [.conflicts(ConflictSet(items: [
                ConflictItem(path: path, kind: .body, thisMachine: nil, otherMachine: nil)
            ]))]
            let host = NSHostingView(rootView: AnyView(ConflictResolutionView(model: makeModel(engine: engine),
                onDismiss: {}).environment(runtime)
                .modelContainer(context.container).environment(\.modelContext, context)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            func strings() -> [String] {
                RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                    .flatMap { RenderedViewTestSupport.strings(in: $0) }
            }
            await TestWait.until(timeout: .seconds(TestWait.firstRenderTimeoutSeconds),
                                 failureMessage: "The conflict card must render before checking its history action") {
                strings().contains("Body differs")
            }
            XCTAssertEqual(strings().contains("See history"), available, "History lookup for \(path)")
        } catch {
            XCTFail("Could not mount the conflict sheet: \(error)")
        }
    }
}
