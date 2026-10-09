import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Pensieve

extension ConflictResolutionModelTests {
    func bodyItem(slug: String) -> ConflictItem {
        ConflictItem(path: "skills/\(slug)/SKILL.md", kind: .body,
                     thisMachine: Data("this body".utf8), otherMachine: Data("other body".utf8))
    }

    /// Read the mounted sheet: grouping assertions alone cannot detect a separate history parser.
    func assertHistoryAction(path: String, slug: String, available: Bool, fixture: ConflictHistoryFixture) async {
        do {
            let context = fixture.context
            for skill in try context.fetch(FetchDescriptor<Skill>()) { context.delete(skill) }
            context.insert(Skill(name: "Indexed Skill", directoryName: slug))
            try context.save()
            let engine = StubResolutionEngine()
            engine.inspections = [.conflicts(ConflictSet(items: [
                ConflictItem(path: path, kind: .body, thisMachine: nil, otherMachine: nil)
            ]))]
            let host = NSHostingView(rootView: AnyView(ConflictResolutionView(model: makeModel(engine: engine),
                onDismiss: {}).environment(fixture.runtime)
                .modelContainer(context.container).environment(\.modelContext, context)))
            fixture.window.contentView = host
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

/// One isolated runtime and hidden window per owning test, reused across its path cases.
@MainActor
final class ConflictHistoryFixture {
    let context: ModelContext
    let runtime: AppRuntime
    let window: NSWindow
    private let files: GitFailureFixture

    init(test: ConflictResolutionModelTests) throws {
        context = try test.makeContext()
        files = try GitFailureFixture()
        do {
            runtime = try AppRuntime(container: context.container,
                scheduler: SyncScheduler(startAutomatically: false, backgroundSyncEnabled: { false }),
                defaults: test.isolatedDefaults("conflict-history"), paths: files.paths,
                gitUsabilityProbe: { .licenseNotAccepted })
        } catch {
            try? files.remove()
            throw error
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }

    func remove() throws {
        window.close()
        try files.remove()
    }
}
