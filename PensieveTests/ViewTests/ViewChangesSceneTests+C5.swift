import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
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

}
