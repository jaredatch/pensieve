import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testAccessibilityPressSelectsAFileOnceAndArrowKeysMoveSelection() async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("accessible-files")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = ViewChangesViewModel(library: fixture.library, operations: fixture.operations(rows: [row]))
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "accessible preview did not load") { model.state != .loading }
        let window = makeWindow(id: "accessible-files")
        defer { window.close() }
        let host = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library, onClose: {})
            .modelContainer(fixture.container))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let element = try XCTUnwrap(accessibilityElement(id: "changes-file-scripts/setup.sh", in: host),
                                   "The file row must expose an accessibility action")
        XCTAssertEqual(element.accessibilityLabel(), "setup.sh, scripts, 1 addition, 0 deletions")
        XCTAssertNotEqual(element.accessibilityRole(), .unknown)
        XCTAssertTrue(element.accessibilityPerformPress(), "Press must perform the row's selection action")
        XCTAssertEqual(model.selectedFilePath, "scripts/setup.sh")
        await TestWait.until(failureMessage: "pressed row was not marked selected") { element.isAccessibilitySelected() }
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f700}",
            charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126))
        window.sendEvent(up)
        XCTAssertEqual(model.selectedFilePath, "SKILL.md", "Arrow keys must move the file selection")
    }

    func assertVisibleHeading(in window: NSWindow) throws {
        let heading = try XCTUnwrap(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue.contains("changes-heading")
        }?.view, "The hidden window title is metadata; the heading must have visible toolbar content")
        XCTAssertFalse(heading.isHidden)
        XCTAssertGreaterThan(heading.alphaValue, 0)
        XCTAssertGreaterThan(heading.bounds.height, 20, "Both heading lines must occupy visible toolbar space")
        let github = try XCTUnwrap(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue.contains("changes-github")
        }?.view)
        XCTAssertLessThan(heading.convert(heading.bounds, to: nil).maxX, github.convert(github.bounds, to: nil).minX)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertEqual(heading.convert(heading.bounds, to: nil).midY,
                       close.convert(close.bounds, to: nil).midY, accuracy: 8)
    }

    private func accessibilityElement(id: String, in root: NSView) -> (any NSAccessibilityProtocol)? {
        var pending: [Any] = [root]
        pending.append(contentsOf: NSAccessibility.unignoredChildrenForOnlyChild(from: root))
        var visited: Set<ObjectIdentifier> = []
        while let candidate = pending.popLast() {
            guard let object = candidate as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let element = candidate as? NSAccessibilityProtocol {
                if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                   element.accessibilityIdentifier() == id { return element }
                pending.append(contentsOf: element.accessibilityChildren() ?? [])
            }
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return nil
    }
}
