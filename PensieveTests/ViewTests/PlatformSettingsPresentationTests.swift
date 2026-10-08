import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

final class PlatformSettingsPresentationTests: XCTestCase {
    @MainActor
    func testSettingsShowsOneSkillSizeBudgetAndAdvisoryFooter() async throws {
        let defaults = try isolatedDefaults()
        defaults.set(6_100, forKey: "claudeCodeTokenBudget")
        let host = NSHostingView(rootView: PlatformSettingsView(defaults: defaults)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                            failureMessage: "Settings renders the shared skill-size budget") {
            (try? self.renderedText(in: host).contains("Skill Size")) == true
        }
        let fields = textFields(in: host)
        XCTAssertEqual(fields.count, 1, "Settings must have exactly one budget field")
        XCTAssertEqual(try XCTUnwrap(fields.first).stringValue.filter(\.isNumber), "6100",
                       "Settings displays the carried-over budget")
        let text = try renderedText(in: host)
        XCTAssertTrue(text.contains("Budget"))
        XCTAssertTrue(text.contains("tokens"))
        XCTAssertTrue(text.contains("The Overview tab warns when a deployed skill's instructions get near this size."), text)
        XCTAssertTrue(text.contains("It never blocks a deploy."), text)
        XCTAssertTrue(text.contains("Platform Paths"))
        XCTAssertFalse(text.contains("Unlimited"))
        XCTAssertFalse(text.contains("Token Budgets"))
    }

    func testGrokPathRowFollowsClaudeCodeAndShowsItsUserSkillsFolder() {
        XCTAssertEqual(PlatformPathSetting.rows.map(\.platform), [.claudeCode, .grok, .cursor])
        guard let grok = PlatformPathSetting.rows.first(where: { $0.platform == .grok }) else {
            return XCTFail("Grok is missing from Platform Paths")
        }
        XCTAssertEqual(grok.label, "Grok Skills")
        XCTAssertEqual(grok.path, Constants.grokUserSkillsDir)
    }

    func testBudgetDefaultsTo5000Tokens() throws {
        XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: try isolatedDefaults()), 5_000)
    }

    func testCustomClaudeBudgetCarriesOverIncludingDisabledValues() throws {
        let defaults = try isolatedDefaults()
        for value in [6_100, 0, -100] {
            defaults.set(value, forKey: "claudeCodeTokenBudget")
            XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: defaults), value)
        }
    }

    func testOldClaudeDefaultDoesNotCarryOver() throws {
        let defaults = try isolatedDefaults()
        defaults.set(2_500, forKey: "claudeCodeTokenBudget")
        XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: defaults), 5_000)
    }

    func testGrokAndCursorBudgetsDoNotCarryOver() throws {
        let defaults = try isolatedDefaults()
        for key in ["grokTokenBudget", "cursorTokenBudget"] {
            defaults.set(123, forKey: key)
            XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: defaults), 5_000, key)
            defaults.removeObject(forKey: key)
        }
    }

    func testNewBudgetWinsOverAllLegacyValues() throws {
        let defaults = try isolatedDefaults()
        defaults.set(6_100, forKey: "claudeCodeTokenBudget")
        defaults.set(100, forKey: "grokTokenBudget")
        defaults.set(200, forKey: "cursorTokenBudget")
        for value in [7_000, 2_500, 0, -100] {
            defaults.set(value, forKey: SkillSizeBudgetSetting.storageKey)
            XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: defaults), value)
        }
    }

    func testBudgetReadsSettingsAgainAfterAnEdit() throws {
        let defaults = try isolatedDefaults()
        for value in [5_100, 5_200] {
            defaults.set(value, forKey: SkillSizeBudgetSetting.storageKey)
            XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: defaults), value)
        }
    }

    func testZeroBudgetIsPreservedToDisableWarnings() throws {
        try assertStoredBudget(0, expected: 0)
    }

    func testNegativeBudgetIsPreservedToDisableWarnings() throws {
        try assertStoredBudget(-2_500, expected: -2_500)
    }

    func testStringBudgetDisablesWarnings() throws {
        try assertStoredBudget("junk", expected: 0)
    }

    func testNumericStringAndFractionalBudgetsMatchSettings() throws {
        for value: Any in ["2500", 2_500.5] {
            try assertStoredBudget(value, expected: 2_500)
        }
    }

    private func assertStoredBudget(_ value: Any, expected: Int,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let defaults = try isolatedDefaults()
        defaults.set(value, forKey: SkillSizeBudgetSetting.storageKey)
        XCTAssertEqual(SkillSizeBudgetSetting.value(defaults: defaults), expected, file: file, line: line)
    }

    @MainActor
    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil }
            ?? view.subviews.flatMap { textFields(in: $0) }
    }

    // Recognize the real 2x render because SwiftUI's virtual accessibility children are absent in the test host.
    @MainActor
    private func renderedText(in host: NSView) throws -> String {
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
