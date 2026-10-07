import AppKit
import CoreText
import SwiftUI
import Vision
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testLongFileHeaderAndPermissionsFitAtTheMinimumWindowWidth() throws {
        let file = PinnedSkillFileDiff(change: FileTreeChange(path: String(repeating: "long-folder/", count: 12) + "script.swift",
            kind: .modified, content: .text(old: "old\n", new: "new\n"), permissions: .init(old: 0o644, new: 0o755)),
            result: UnifiedDiff(old: String(repeating: "old\n", count: 1_234),
                                new: String(repeating: "new\n", count: 5_678)))
        let width = DesignTokens.changesWindowWidth - DesignTokens.changesSidebarWidth - 1
        let renderer = ImageRenderer(content: ViewChangesFileHeader(file: file).frame(width: width)
            .padding(.horizontal, 100).padding(.vertical, 40).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = rowRenderScale
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rowPixels(image)
        var pathBounds = CGRect.null
        var inkBounds = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                if max(red, green, blue) < 220 {
                    let pixel = CGRect(x: CGFloat(x) / rowRenderScale, y: CGFloat(y) / rowRenderScale,
                                       width: 1 / rowRenderScale, height: 1 / rowRenderScale)
                    inkBounds = inkBounds.union(pixel)
                    if max(red, green, blue) < 80 { pathBounds = pathBounds.union(pixel) }
                }
            }
        }
        let text = try recognizedText(image)
        for part in ["5678 additions", "1234 deletions", "Permissions changed from 0644 to 0755", "script.swift"] {
            XCTAssertTrue(text.contains(part),
                          "Header must render every summary part and the path at minimum width: \(part); saw \(text)")
        }
        XCTAssertFalse(inkBounds.isNull, "A rendered-size check must contain visible text")
        XCTAssertGreaterThanOrEqual(inkBounds.minX, 100, "The file header must not overflow its detail column")
        XCTAssertLessThanOrEqual(inkBounds.maxX, 100 + width, "The file header must not overflow its detail column")
        XCTAssertGreaterThanOrEqual(inkBounds.minY, 40, "The header frame must contain both summary lines")
        XCTAssertLessThanOrEqual(inkBounds.maxY, CGFloat(image.height) / rowRenderScale - 40,
                                 "The header frame must contain both summary lines")
        XCTAssertFalse(pathBounds.isNull, "The file path must remain visible")
        XCTAssertGreaterThanOrEqual(pathBounds.width, 120, "The path must keep a readable minimum beside the permission suffix")
        try assertGrowingHeaderContainsItsText(file: file, width: width)
        let renamed = PinnedSkillFileDiff(change: FileTreeChange(
            path: String(repeating: "long-folder/", count: 12) + "renamed.zzzzz",
            kind: .modified, content: file.content, permissions: file.permissions), result: file.diff)
        let renamedRenderer = ImageRenderer(content: ViewChangesFileHeader(file: renamed).frame(width: width)
            .padding(.horizontal, 100).padding(.vertical, 40).background(Color.white).environment(\.colorScheme, .light))
        renamedRenderer.scale = rowRenderScale
        let renamedImage = try XCTUnwrap(renamedRenderer.cgImage)
        XCTAssertEqual(renamedImage.width, image.width)
        XCTAssertEqual(renamedImage.height, image.height)
        let renamedPixels = try rowPixels(renamedImage)
        XCTAssertTrue(zip(pixels, renamedPixels).contains { abs(Int($0) - Int($1)) > 4 },
                      "The long path's filename must stay readable beside its permission suffix")
    }

    private func assertGrowingHeaderContainsItsText(file: PinnedSkillFileDiff, width: CGFloat) throws {
        let single = ImageRenderer(content: ViewChangesFileHeader(file: PinnedSkillFileDiff(
            change: FileTreeChange(path: "short", kind: .added, content: .binary), result: nil)).frame(width: width))
        single.scale = rowRenderScale
        XCTAssertEqual(CGFloat(try XCTUnwrap(single.cgImage).height) / rowRenderScale, 29,
                       "A single-line file header keeps the 29-point height")
        // A narrower detail column and inherited text spacing make both summary lines exceed 29 points.
        let wrapped = ImageRenderer(content: ViewChangesFileHeader(file: file)
            .frame(width: width - DesignTokens.changesSidebarWidth).lineSpacing(8)
            .padding(.vertical, 40).background(Color.white).environment(\.colorScheme, .light))
        wrapped.scale = rowRenderScale
        let wrappedImage = try XCTUnwrap(wrapped.cgImage)
        let wrappedPixels = try rowPixels(wrappedImage)
        var wrappedBounds = CGRect.null
        for y in 0..<wrappedImage.height {
            for x in 0..<wrappedImage.width {
                let offset = (y * wrappedImage.width + x) * 4
                if max(wrappedPixels[offset], wrappedPixels[offset + 1], wrappedPixels[offset + 2]) < 220 {
                    wrappedBounds = wrappedBounds.union(CGRect(x: CGFloat(x) / rowRenderScale,
                        y: CGFloat(y) / rowRenderScale, width: 1 / rowRenderScale, height: 1 / rowRenderScale))
                }
            }
        }
        XCTAssertFalse(wrappedBounds.isNull, "The wrapped header must render visible text")
        XCTAssertGreaterThanOrEqual(wrappedBounds.minY, 40, "The header frame must contain both summary lines")
        XCTAssertLessThanOrEqual(wrappedBounds.maxY, CGFloat(wrappedImage.height) / rowRenderScale - 40,
                                 "The header frame must contain both summary lines")
        XCTAssertTrue(try recognizedText(wrappedImage).contains("Permissions changed from 0644 to 0755"))
    }

    func testBinaryModeSidebarKeepsNameFolderAndMarkerAtMinimumWidth() throws {
        let folder = "scripts-with-a-very-long-folder-name-TAIL/"
        let name = "comment-with-an-extremely-long-filename.swift"
        let file = PinnedSkillFileDiff(change: FileTreeChange(path: folder + name,
            kind: .modified, content: .binary, permissions: .init(old: 0o644, new: 0o755)), result: nil)
        let width = DesignTokens.changesSidebarWidth - 4 * DesignTokens.changesSidebarInset
        let image = try renderLongRow(file, width: width)
        let text = try recognizedText(image)
        for part in ["co", "swift", "scripts", "TAIL", "Binary"] {
            XCTAssertTrue(text.contains(part), "Sidebar must keep the filename, folder and marker readable: \(part); saw \(text)")
        }
        let pixels = try rowPixels(image)
        var bounds = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 220 {
                    bounds = bounds.union(CGRect(x: CGFloat(x) / rowRenderScale, y: CGFloat(y) / rowRenderScale,
                                                width: 1 / rowRenderScale, height: 1 / rowRenderScale))
                }
            }
        }
        XCTAssertFalse(bounds.isNull, "The sidebar size check needs visible pixels")
        XCTAssertGreaterThanOrEqual(bounds.minX, DesignTokens.changesSidebarWidth)
        XCTAssertLessThanOrEqual(bounds.maxX, DesignTokens.changesSidebarWidth + width,
                                 "The binary/mode marker must not push the path outside the sidebar")
    }

    private func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

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
