import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testSelectedFileRowDrawsNoCustomFill() throws {
        let file = try XCTUnwrap(PinnedSkillDiff(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "selected.md", kind: .modified, content: .text(old: "old\n", new: "new\n"))
        ], unreadFileCount: 0, bytesRead: 8)).files.first)
        let width = DesignTokens.changesSidebarWidth - 4 * DesignTokens.changesSidebarInset
        let renderer = ImageRenderer(content: ViewChangesFileRow(file: file)
            .frame(width: width).environment(\.colorScheme, .light))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rowPixels(image)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 },
                      "The row must render visible content before checking its background")
        let corner = (image.width / 2 + image.width * 4) * 4 + 3
        XCTAssertEqual(pixels[corner], 0, "The selected row must draw no custom fill; native List owns selection")
    }

    func testFileListHasChangedFilesAccessibilityLabel() throws {
        // SwiftUI's virtual accessibility element is not the raw NSTableView getter in this host.
        // Guard the user-facing declaration; the Planner drives the outside-client tree.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try FileService().readFile(at: root.appendingPathComponent(
            "Pensieve/Views/InstallViews/ViewChangesView.swift").path)
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Changed Files\")"),
                      "The file List needs its own Changed Files accessibility label")
    }

    func rowPixels(_ image: CGImage) throws -> [UInt8] {
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
