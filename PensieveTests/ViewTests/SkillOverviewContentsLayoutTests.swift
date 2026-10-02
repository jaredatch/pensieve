import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

/// The Overview's Contents row at more than one column width (#4): the bar fills the space between the file
/// column and the count, so the count stays right-aligned under `tokens per file` however wide the column is.
/// Read from the rendered pixels: the bar is the longest unbroken run of ink on the row's middle line (the file
/// name and the count break into glyphs), so the check holds under any accent color, Graphite included.
@MainActor
final class SkillOverviewContentsLayoutTests: XCTestCase {
    func testTheBarFillsBetweenTheFileAndTheCountAtEveryWidth() throws {
        for width in [CGFloat(612), 900] {
            let span = try XCTUnwrap(barSpan(width: width), "no bar drawn at \(width)")
            // 200 file column + 16 gap, then the bar, then 16 gap + the 56 count column.
            XCTAssertEqual(span.lowerBound, 216, accuracy: 1, "the bar starts after the file column at \(width)")
            XCTAssertEqual(span.upperBound, width - 72, accuracy: 1, "the bar reaches the count column at \(width)")
        }
    }

    /// The horizontal extent, in points, of the longest run of non-white pixels on the bar's middle line.
    private func barSpan(width: CGFloat) -> ClosedRange<CGFloat>? {
        let row = SkillOverviewPresentation.ContentsRow(relativePath: "SKILL.md", tokens: 18_857, share: 1)
        let renderer = ImageRenderer(content: ContentsRowView(row: row)
            .frame(width: width)
            .background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        let midY = image.height / 2
        var best: ClosedRange<Int>?
        var start: Int?
        for x in 0...image.width {
            let offset = midY * image.bytesPerRow + x * bytesPerPixel
            let inked = x < image.width && (0..<3).contains { Int(bytes[offset + $0]) < 235 }
            if inked, start == nil { start = x }
            if !inked, let first = start {
                if (x - first) > (best.map { $0.count } ?? 0) { best = first...(x - 1) }
                start = nil
            }
        }
        return best.map { CGFloat($0.lowerBound) / 2...CGFloat($0.upperBound + 1) / 2 }
    }
}
