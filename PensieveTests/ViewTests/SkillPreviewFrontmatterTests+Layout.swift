import SwiftUI
import XCTest
@testable import Pensieve

extension SkillPreviewFrontmatterTests {
    func testLayoutKeepsFiniteSizesWithinEveryWidthProposal() throws {
        for width: CGFloat? in [0, 1, 43, 52, 160, 612, nil, .infinity] {
            let probe = FrontmatterLayoutProbe(width: width)
            let renderer = ImageRenderer(content: ProbedFrontmatterLayout(probe: probe) {
                Text(String(repeating: "LongKey", count: 40))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
                Text("A value that needs enough room to remain readable.")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.markdownTableCellHorizontal)
            })
            _ = renderer.cgImage
            let size = try XCTUnwrap(probe.sizes.last)
            XCTAssertTrue(size.width.isFinite && size.height.isFinite, "Proposal: \(String(describing: width))")
            if let width, width.isFinite { XCTAssertLessThanOrEqual(size.width, width) }
            XCTAssertLessThan(size.height, 2_000, "Narrow probes must not return runaway heights")
            XCTAssertGreaterThanOrEqual(size.height, 0)
        }
    }

    func testLayoutHandlesAnOrphanCellAndEmptyContent() throws {
        for count in [1, 3, 0] {
            let probe = FrontmatterLayoutProbe(width: 612)
            let renderer = ImageRenderer(content: ProbedFrontmatterLayout(probe: probe) {
                ForEach(0..<count, id: \.self) { index in Text("Cell \(index)") }
            })
            _ = renderer.cgImage
            let size = try XCTUnwrap(probe.sizes.last)
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            if count == 0 {
                XCTAssertEqual(size, .zero)
            } else {
                XCTAssertGreaterThan(size.height, 0, "The orphan cell still has a row")
            }
        }
    }
}

private final class FrontmatterLayoutProbe {
    let width: CGFloat?
    var sizes: [CGSize] = []

    init(width: CGFloat?) { self.width = width }
}

/// Exercise the production Layout protocol with exact probes and arbitrary subview counts.
private struct ProbedFrontmatterLayout: Layout {
    let probe: FrontmatterLayoutProbe
    private let layout = FrontmatterTableLayout()

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = layout.sizeThatFits(proposal: ProposedViewSize(width: probe.width, height: nil),
                                      subviews: subviews, cache: &cache)
        probe.sizes.append(size)
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}
