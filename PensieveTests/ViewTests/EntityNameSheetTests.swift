import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class EntityNameSheetTests: XCTestCase {
    func testTakenNameShowsCaptionDisablesActionAndRejectsReturnUntilCorrected() async throws {
        for action in ["Add", "Rename"] { try await checkSheet(action) }
        // A subsequent store save must not reach a query left behind by the closed hosts.
        let next = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        next.mainContext.insert(Pensieve.Category(name: "After closing the sheets"))
        try next.mainContext.save()
        XCTAssertEqual(try next.mainContext.fetchCount(FetchDescriptor<Pensieve.Category>()), 1)
    }

    private func checkSheet(_ action: String) async throws {
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(Pensieve.Category(name: "Writing"))
        let renamed = Pensieve.Category(name: "Spare")
        container.mainContext.insert(renamed)
        try container.mainContext.save()
        let categories = try container.mainContext.fetch(FetchDescriptor<Pensieve.Category>())
        var commits: [String] = []
        let host = NSHostingView(rootView: AnyView(EntityNameSheet(
            title: "\(action) Category", fieldLabel: "Category Name", actionTitle: action, initialName: "Free",
            validate: { CategoryName.validationMessage($0, among: categories,
                excluding: action == "Rename" ? renamed.id : nil) }, onCommit: { commits.append($0) }
        )
            .buttonStyle(RenderedViewTestSupport.AvailabilityStyle())))
        let window = mount(host)
        defer {
            // Unmount the field and its validation context before releasing the container.
            host.rootView = AnyView(EmptyView())
            host.layoutSubtreeIfNeeded()
            window.close()
            window.contentView = nil
            withExtendedLifetime(container) {}
        }
        await TestWait.until(failureMessage: "The name field must mount") { !self.fields(in: host).isEmpty }
        let field = try XCTUnwrap(fields(in: host).first)
        await TestWait.until(failureMessage: "A free name starts enabled") {
            RenderedViewTestSupport.buttonIsEnabled(action, in: host) == true
        }
        for name in ["Writing", "WRITING", "writing", " \tWrItInG "] {
            set("Free", in: field)
            await TestWait.until(failureMessage: "A free name clears validation") {
                !self.strings(in: host).contains("A category named “Writing” already exists.")
            }
            set(name, in: field)
            await TestWait.until(failureMessage: "A taken name must show its inline explanation",
                diagnostics: { self.strings(in: host).description }, {
                self.strings(in: host).contains("A category named “Writing” already exists.")
                    && RenderedViewTestSupport.buttonIsEnabled(action, in: host) == false
            })
            guard self.strings(in: host).contains("A category named “Writing” already exists."),
                  RenderedViewTestSupport.buttonIsEnabled(action, in: host) == false else { return }
            try pressReturn(in: field, window: window)
            XCTAssertTrue(commits.isEmpty, "\(action): \(name)")
        }
        let corrected = action == "Rename" ? "sPaRe" : "New Name"
        set(" \(corrected) ", in: field)
        await TestWait.until(failureMessage: "A free name must clear the caption and enable the action") {
            !self.strings(in: host).contains("A category named “Writing” already exists.")
                && RenderedViewTestSupport.buttonIsEnabled(action, in: host) == true
        }
        try pressReturn(in: field, window: window)
        await TestWait.until(failureMessage: "Return must submit the corrected trimmed name") { commits == [corrected] }
    }

    private func mount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        return window
    }

    private func strings(in host: NSView) -> [String] {
        RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
            .flatMap { RenderedViewTestSupport.strings(in: $0) }
    }

    private func fields(in root: NSView) -> [NSTextField] {
        [root].compactMap { $0 as? NSTextField } + root.subviews.flatMap(fields(in:))
    }

    private func set(_ name: String, in field: NSTextField) {
        field.stringValue = name
        field.delegate?.controlTextDidChange?(Notification(name: NSTextField.textDidChangeNotification, object: field))
    }

    private func pressReturn(in field: NSTextField, window: NSWindow) throws {
        window.makeFirstResponder(field)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        window.sendEvent(event)
    }
}
