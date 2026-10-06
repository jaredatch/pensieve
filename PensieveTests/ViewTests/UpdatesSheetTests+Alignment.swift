import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension UpdatesSheetTests {
    func assertLocalEditsColumn(_ model: UpdatesViewModel, fixture: UpdateReviewFixture) throws {
        let shown = try XCTUnwrap(UpdatesSheetPresentation(model).rows.first { $0.localEditsCopy != nil })
        let renderer = ImageRenderer(content: UpdatesRowView(model: model, shown: shown, context: fixture.context,
                                                             onViewChanges: { _ in })
            .frame(width: DesignTokens.updatesSheetWidth).background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try alignmentPixels(image)
        let nameTop = DesignTokens.updatesRowPadding.top + DesignTokens.updatesRowBodyTop
        let nameBottom = nameTop + DesignTokens.updatesRowNameLineHeight
        let bodyMinimum = DesignTokens.updatesRowPadding.leading + DesignTokens.updatesRowBodyOffset
        var nameLeft = CGFloat.infinity, panelLeft = CGFloat.infinity
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                let pointX = CGFloat(x) / renderer.scale, pointY = CGFloat(y) / renderer.scale
                if pointY >= nameBottom + DesignTokens.updatesCheckboxHeight, red > green + 3, green > blue + 3 {
                    panelLeft = min(panelLeft, pointX)
                }
                let neutralInk = max(red, green, blue) < 160 && max(red, green, blue) - min(red, green, blue) < 10
                if pointY >= nameTop, pointY < nameBottom, pointX >= bodyMinimum, neutralInk {
                    nameLeft = min(nameLeft, pointX)
                }
            }
        }
        XCTAssertTrue(nameLeft.isFinite, "The rendered name must have visible ink in its first line")
        XCTAssertTrue(panelLeft.isFinite, "The rendered local-edits panel must have visible orange fill")
        XCTAssertEqual(panelLeft, nameLeft, accuracy: 2,
                       "Local-edits panel left=\(panelLeft), name ink left=\(nameLeft): they must share a column")
    }

    private func alignmentPixels(_ image: CGImage) throws -> [UInt8] {
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
