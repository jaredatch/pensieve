import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

extension LibraryFenceControlsTests {
    func testProductionCategorySheetsRejectTakenNames() async throws {
        let fixture = try LibraryFenceFixture(defaults: isolatedDefaults())
        addTeardownBlock { @MainActor in await fixture.close() }
        await fixture.runtime.bootstrapTask.value
        let context = fixture.runtime.container.mainContext
        let spare = Pensieve.Category(name: "Spare")
        context.insert(Pensieve.Category(name: "Writing"))
        context.insert(spare)
        try context.save()
        for source in ["add", "list", "detail"] {
            fixture.mountCategoryNames(source, category: spare)
            if source != "add" {
                await TestWait.until(failureMessage: "The production \(source) Rename action must mount") {
                    fixture.renderedAction("Rename", in: fixture.host) != nil
                }
                try XCTUnwrap(fixture.renderedAction("Rename", in: fixture.host))()
                await TestWait.until(failureMessage: "The production \(source) Rename sheet must open") {
                    fixture.window.attachedSheet != nil
                }
            }
            let sheet = fixture.window.attachedSheet
            sheet?.animationBehavior = .none
            let root = try XCTUnwrap(sheet?.contentView ?? fixture.host)
            await TestWait.until(failureMessage: "The production \(source) name field must mount") {
                !Self.nameFields(in: root).isEmpty
            }
            let field = try XCTUnwrap(Self.nameFields(in: root).first)
            let action = source == "add" ? "Add" : "Rename"
            for name in ["Writing", "WRITING", "writing", " \tWrItInG "] {
                field.stringValue = name
                field.delegate?.controlTextDidChange?(Notification(name: NSTextField.textDidChangeNotification, object: field))
                await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                    failureMessage: "Production \(source): taken name \(name) must show its caption and turn \(action) off", {
                    let strings = RenderedViewTestSupport.values(in: root).compactMap { $0 as? Text }
                        .flatMap(RenderedViewTestSupport.strings)
                    return strings.contains("A category named “Writing” already exists.")
                        && RenderedControlInputs.controls(in: root).contains { $0.title == action && !$0.enabled }
                })
            }
            if sheet != nil {
                try XCTUnwrap(fixture.renderedAction("Cancel", in: root))()
                await TestWait.until(failureMessage: "Dismiss Rename before unmounting its queries") {
                    fixture.window.attachedSheet == nil
                }
            }
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Pensieve.Category>()).map(\.name).sorted(), ["Spare", "Writing"])
    }

    private static func nameFields(in root: NSView) -> [NSTextField] {
        [root].compactMap { $0 as? NSTextField }.filter { $0.isEditable } + root.subviews.flatMap(nameFields)
    }
}

extension LibraryFenceFixture {
    func mountCategoryNames(_ source: String, category: Pensieve.Category) {
        let runtime = runtime
        host.rootView = AnyView(NavigationStack {
            switch source {
            case "add":
                AddEntitySheet(kind: .category, notifier: {}, intentReconciler: { _ in BatchResult() }, onCreated: { _ in })
            case "list":
                CategoryListView(entitySelection: .constant(nil), searchText: .constant("Spare"),
                    platformVM: runtime.platformVM, manifestSaves: runtime.library.manifestSaves,
                    notifier: {}, onAdd: {}, library: runtime.library)
            default:
                CategoryDetailView(categoryID: category.id, platformVM: runtime.platformVM, library: runtime.library,
                    manifestSaves: runtime.library.manifestSaves, notifier: {}, onReveal: { _ in })
            }
        }.environment(runtime).modelContainer(runtime.container))
        host.layoutSubtreeIfNeeded()
    }

    /// Invoke only an action found in the mounted graph, including a list row's context menu.
    /// This follows SwiftUI composition without evaluating bodies or constructing replacement views.
    func renderedAction(_ title: String, in root: NSView) -> (@MainActor () -> Void)? {
        func find(_ value: Any, depth: Int) -> (@MainActor () -> Void)? {
            guard depth > 0 else { return nil }
            let mirror = Mirror(reflecting: value), type = String(reflecting: Swift.type(of: value))
            if type.hasPrefix("SwiftUI.Button<"), let label = mirror.descendant("label") {
                let texts = (label as? Text).map(RenderedViewTestSupport.strings)
                    ?? (Mirror(reflecting: label).descendant("title") as? Text).map(RenderedViewTestSupport.strings) ?? []
                if texts.contains(title) { return mirror.descendant("action", "closure") as? @MainActor () -> Void }
            }
            guard mirror.displayStyle != .class,
                  type.hasPrefix("SwiftUI.") || [.tuple, .enum, .optional].contains(mirror.displayStyle) else { return nil }
            return mirror.children.lazy.compactMap { find($0.value, depth: depth - 1) }.first
        }
        return RenderedViewTestSupport.values(in: root).lazy.compactMap { find($0, depth: 24) }.first
    }
}
