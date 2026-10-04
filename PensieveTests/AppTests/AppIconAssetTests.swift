import AppKit
import XCTest

/// The built app carries its own menu bar glyph instead of a stock SF Symbol.
final class AppIconAssetTests: XCTestCase {
    func testMenuBarGlyphIsAnEighteenPointTemplateImage() throws {
        let bundle = try XCTUnwrap(Bundle(url: try appBundleURL()))
        let glyph = try XCTUnwrap(bundle.image(forResource: "MenuBarGlyph"))
        XCTAssertTrue(glyph.isTemplate, "the menu bar tints only a template image")
        XCTAssertEqual(glyph.size, NSSize(width: 18, height: 18))
    }

    private func appBundleURL() throws -> URL {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            XCTFail("The suite runs hosted in Pensieve.app; Bundle.main is \(Bundle.main.bundleURL.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return Bundle.main.bundleURL
    }
}
