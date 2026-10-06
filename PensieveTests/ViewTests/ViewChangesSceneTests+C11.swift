import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    private var rowRenderScale: CGFloat { 4 }
    func testLongFileRowKeepsFullCountsAcrossProposedWidthsAndMiddleTruncatesName() throws {
        let folder = "scripts-with-a-very-long-folder-name-TAIL/"
        let name = "comment-with-an-extremely-long-filename.swift"
        let file = try longCountFile(path: folder + name)
        XCTAssertEqual(file.linesAdded, 1_234)
        XCTAssertEqual(file.linesRemoved, 1_234)
        for width in [0, 64, 128, DesignTokens.changesSidebarWidth, DesignTokens.changesSidebarWidth * 2] {
            let image = try renderLongRow(file, width: width)
            let pixels = try rowPixels(image)
            let added = try countBounds(image: image, pixels: pixels, added: true)
            let removed = try countBounds(image: image, pixels: pixels, added: false)
            XCTAssertLessThan(added.maxX, removed.minX, "Counts keep separate frames at proposed width \(width)")
            // Independent CoreText ink geometry of the complete count strings at the spec's 11 pt font.
            for (bounds, text) in [(added, "+1,234"), (removed, "−1,234")] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
                XCTAssertEqual(bounds.width, CTLineGetImageBounds(line, nil).width, accuracy: 1,
                               "The full \(text) must render without truncation at proposed width \(width)")
            }
        }
        let width = DesignTokens.changesSidebarWidth - 4 * DesignTokens.changesSidebarInset
        let original = try renderLongRow(file, width: width)
        for changedName in ["project-with-an-extremely-long-filename.swift", "comment-with-an-extremely-long-filename.zzzzz"] {
            let changed = try renderLongRow(longCountFile(path: folder + changedName), width: width)
            XCTAssertEqual(original.width, changed.width)
            XCTAssertEqual(original.height, changed.height)
            let originalPixels = try rowPixels(original), changedPixels = try rowPixels(changed)
            _ = try countBounds(image: original, pixels: originalPixels, added: true)
            _ = try countBounds(image: changed, pixels: changedPixels, added: true)
            XCTAssertTrue(zip(originalPixels, changedPixels).contains { abs(Int($0) - Int($1)) > 4 },
                          "Middle truncation must retain both the filename's beginning and suffix: \(changedName)")
        }
    }

    private func longCountFile(path: String) throws -> PinnedSkillFileDiff {
        try XCTUnwrap(PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: path, kind: .modified, content: .text(
                old: String(repeating: "old\n", count: 1_234), new: String(repeating: "new\n", count: 1_234)))
        ], unreadFileCount: 0, bytesRead: 9_872)).files.first)
    }

    private func renderLongRow(_ file: PinnedSkillFileDiff, width: CGFloat) throws -> CGImage {
        // Capture overflow around tiny proposed widths; this tests intrinsic counts, not native cell geometry.
        let renderer = ImageRenderer(content: ViewChangesFileRow(file: file).frame(width: width)
            .padding(.horizontal, DesignTokens.changesSidebarWidth).background(Color.white)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = rowRenderScale
        return try XCTUnwrap(renderer.cgImage)
    }

    private func countBounds(image: CGImage, pixels: [UInt8], added: Bool) throws -> CGRect {
        var bounds = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                let isCount = added ? green > red + 30 && green > blue + 30 : red > green + 30 && red > blue + 30
                if isCount { bounds = bounds.union(CGRect(x: CGFloat(x) / rowRenderScale, y: CGFloat(y) / rowRenderScale,
                                                       width: 1 / rowRenderScale, height: 1 / rowRenderScale)) }
            }
        }
        XCTAssertFalse(bounds.isNull, "The row must render visible \(added ? "addition" : "deletion") count pixels")
        guard !bounds.isNull else { throw CocoaError(.coderInvalidValue) }
        return bounds
    }

    private func rowPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
