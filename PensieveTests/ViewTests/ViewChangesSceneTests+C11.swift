import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testLongFileRowKeepsFullCountsAtFrameSidebarWidth() throws {
        let path = "scripts-with-a-very-long-folder-name-TAIL/comment-with-an-extremely-long-filename.swift"
        let preview = PinnedSkillDiff(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: path, kind: .modified, content: .text(
                old: String(repeating: "old\n", count: 1_234), new: String(repeating: "new\n", count: 1_234)))
        ], unreadFileCount: 0, bytesRead: 9_872))
        let file = try XCTUnwrap(preview.files.first)
        XCTAssertEqual(file.linesAdded, 1_234)
        XCTAssertEqual(file.linesRemoved, 1_234)
        let width = DesignTokens.changesSidebarWidth - 4 * DesignTokens.changesSidebarInset
        let renderer = ImageRenderer(content: ViewChangesFileRow(file: file)
            .frame(width: width).background(Color.white)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rowPixels(image)
        let added = try countBounds(image: image, pixels: pixels, scale: renderer.scale, added: true)
        let removed = try countBounds(image: image, pixels: pixels, scale: renderer.scale, added: false)
        let row = CGRect(x: 0, y: 0, width: width, height: DesignTokens.changesNestedFileRowHeight)
            .insetBy(dx: DesignTokens.changesFileRowHorizontalPadding, dy: 0)
        XCTAssertTrue(row.contains(added), "The additions' frame must fit fully inside the row: \(added)")
        XCTAssertTrue(row.contains(removed), "The deletions' frame must fit fully inside the row: \(removed)")
        XCTAssertLessThan(added.maxX, removed.minX, "Counts must keep separate, non-overlapping frames")
        // Independent CoreText ink geometry for the complete count strings at the frame's 11 pt font.
        for (bounds, text) in [(added, "+1,234"), (removed, "−1,234")] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
            let fullWidth = CTLineGetImageBounds(line, nil).width
            XCTAssertEqual(bounds.width, fullWidth, accuracy: 1,
                           "The full \(text) must render without truncation at the token-derived sidebar width")
        }
    }

    private func countBounds(image: CGImage, pixels: [UInt8], scale: CGFloat, added: Bool) throws -> CGRect {
        var bounds = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                let isCount = added ? green > red + 30 && green > blue + 30 : red > green + 30 && red > blue + 30
                if isCount {
                    bounds = bounds.union(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale,
                                                 width: 1 / scale, height: 1 / scale))
                }
            }
        }
        XCTAssertFalse(bounds.isNull, "The row must render visible \(added ? "addition" : "deletion") count pixels")
        guard !bounds.isNull else { throw CocoaError(.coderInvalidValue) }
        return bounds
    }
}
