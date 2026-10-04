import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Pensieve

final class PreviewImagePolicyTests: XCTestCase {
    func testRejectedTypesAndDeclaredPixelBoundsNeverReachDecoder() throws {
        let pixel = try PreviewImageFixture.decodedPNG()
        let tiff = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixel, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let cases = [tiff as Data, try declaredPNG(width: 16_385, height: 1),
                     try declaredPNG(width: 1, height: 16_385), try declaredPNG(width: 5_001, height: 5_000)]
        for data in cases {
            var decodes = 0
            let loader = PreviewImageLoader(decode: { _ in decodes += 1; return pixel })
            let url = try XCTUnwrap(URL(string: "data:image/png;base64," + data.base64EncodedString()))
            XCTAssertThrowsError(try loader.loadImage(at: url, skillDirectory: nil))
            XCTAssertEqual(decodes, 0, "Rejected metadata must never reach pixel decoding")
        }
    }

    func testPixelBoundsIncludeExactLimitsAndUseActualImageType() throws {
        let pixel = try PreviewImageFixture.decodedPNG()
        for size in [(16_384, 1), (1, 16_384), (5_000, 5_000)] {
            var decodes = 0
            let data = try declaredPNG(width: size.0, height: size.1)
            let loader = PreviewImageLoader(decode: { _ in decodes += 1; return pixel })
            let url = try XCTUnwrap(URL(string: "data:image/mislabeled;base64," + data.base64EncodedString()))
            XCTAssertEqual(try loader.loadImage(at: url, skillDirectory: nil).width, pixel.width)
            XCTAssertEqual(decodes, 1)
        }
    }

    func testAllFiveAllowedTypesDecodeFromSniffedBytes() throws {
        let pixel = try PreviewImageFixture.decodedPNG()
        for type in [UTType.png, .jpeg, .gif, .heic] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, pixel, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination), type.identifier)
            try assertDecoded(data as Data)
        }
        try assertDecoded(PreviewImagePolicyFixtures.webP)
    }

    private func assertDecoded(_ data: Data) throws {
        let url = try XCTUnwrap(URL(string: "data:image/mislabeled;base64," + data.base64EncodedString()))
        let image = try PreviewImageLoader().loadImage(at: url, skillDirectory: nil)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 24)
    }

    /// Valid compressed fixtures carry their complete declared pixel data. The injected decoder
    /// records admission without allocating those dimensions during this metadata-only test.
    private func declaredPNG(width: Int, height: Int) throws -> Data {
        let data = try PreviewImagePolicyFixtures.png(width: width, height: height)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, width)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, height)
        return data
    }
}
