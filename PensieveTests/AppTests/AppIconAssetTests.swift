import AppKit
import XCTest

/// The built app carries its own icon and menu bar glyph instead of a blank icon and a stock SF Symbol.
final class AppIconAssetTests: XCTestCase {
    func testInfoPlistNamesTheCompiledAppIcon() throws {
        let appURL = try appBundleURL()
        let info = try XCTUnwrap(Bundle(url: appURL)?.infoDictionary)
        XCTAssertEqual(info["CFBundleIconName"] as? String, "Pensieve")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "Pensieve")
        let icns = appURL.appendingPathComponent("Contents/Resources/Pensieve.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: icns.path), icns.path)
    }

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
