import Darwin
import XCTest
@testable import Pensieve

final class PreviewImageLoaderTests: XCTestCase {
    private var root = ""
    private var skillDirectory = ""
    private var spy = PreviewImageFileSpy()
    private var png = Data()

    override func setUpWithError() throws {
        spy = PreviewImageFileSpy()
        root = spy.files.realPath(at: NSTemporaryDirectory()) + "/preview-images-" + UUID().uuidString
        skillDirectory = root + "/skill"
        try spy.files.createDirectory(at: skillDirectory + "/assets")
        png = try PreviewImageFixture.png()
        try spy.files.writeData(at: skillDirectory + "/assets/red image.png", data: png)
        try spy.files.writeData(at: root + "/outside.png", data: png)
    }

    override func tearDownWithError() throws { try spy.files.deleteDirectory(at: root) }

    func testDataRelativeAndContainedFileImagesDecode() throws {
        let loader = PreviewImageLoader(fileService: spy)
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        let percentURL = "data:image/png," + png.map { String(format: "%%%02X", $0) }.joined()
        let urls = [URL(string: dataURL)!, URL(string: percentURL)!,
                    URL(string: "assets/red%20image.png")!, URL(string: "assets/../assets/red%20image.png")!,
                    URL(fileURLWithPath: skillDirectory + "/assets/red image.png")]
        for url in urls {
            let image = try loader.loadImage(at: url, skillDirectory: skillDirectory)
            XCTAssertEqual(image.width, 32, url.absoluteString)
            XCTAssertEqual(image.height, 24, url.absoluteString)
        }
        XCTAssertEqual(spy.reads.count, 3)
        XCTAssertTrue(spy.reads.allSatisfy { $0.limit == 4 * 1_024 * 1_024 && $0.root == skillDirectory })
        XCTAssertEqual(spy.bytesRead, png.count * 3)
        XCTAssertEqual(try loader.loadImage(at: URL(string: dataURL)!, skillDirectory: nil).width, 32)
    }

    func testRemoteEscapingAndOtherSchemesNeverReachFileReads() throws {
        let loader = PreviewImageLoader(fileService: spy)
        let sources = ["https://preview.example/image.png", "http://preview.example/image.png",
                       "ftp://preview.example/image.png", "javascript:alert(1)", "custom:assets/red.png",
                       "//preview.example/image.png", "../outside.png", "%2e%2e/outside.png",
                       "assets/../../outside.png", "assets/%2e%2e/%2e%2e/outside.png",
                       URL(fileURLWithPath: root + "/outside.png").absoluteString,
                       "file://preview.example" + skillDirectory + "/assets/red%20image.png"]
        for source in sources {
            XCTAssertThrowsError(try loader.loadImage(at: URL(string: source)!, skillDirectory: skillDirectory), source)
        }
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "assets/red%20image.png")!, skillDirectory: nil))
        XCTAssertEqual(spy.reads.count, 0)
        XCTAssertEqual(spy.bytesRead, 0)
    }

    func testLinkedAndSpecialLeavesAreRefusedBeforeAnyBytesAreRead() throws {
        try spy.files.createSymlink(at: skillDirectory + "/linked.png", pointingTo: skillDirectory + "/assets/red image.png")
        XCTAssertEqual(mkfifo(skillDirectory + "/pipe.png", 0o600), 0)
        try spy.files.createDirectory(at: skillDirectory + "/directory.png")
        let loader = PreviewImageLoader(fileService: spy)
        for leaf in ["linked.png", "pipe.png", "directory.png", "missing.png"] {
            XCTAssertThrowsError(try loader.loadImage(at: URL(string: leaf)!, skillDirectory: skillDirectory), leaf)
        }
        XCTAssertEqual(spy.reads.count, 4)
        XCTAssertEqual(spy.bytesRead, 0)
    }

    func testParentLinkCannotReadAnOutsideImageAndSkillRootLinksAreRefused() throws {
        try spy.files.createSymlink(at: skillDirectory + "/escape", pointingTo: root)
        let loader = PreviewImageLoader(fileService: spy)
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "escape/outside.png")!, skillDirectory: skillDirectory))
        XCTAssertEqual(spy.reads.count, 1)
        XCTAssertEqual(spy.bytesRead, 0, "The opened descriptor must be contained before its first read")
        try spy.files.createSymlink(at: root + "/alias", pointingTo: skillDirectory)
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "assets/red%20image.png")!, skillDirectory: root + "/alias"))
        XCTAssertEqual(spy.reads.count, 1)
    }

    func testContainedFolderLinkLoadsButLinkedImageLeafStillRefusesBytes() throws {
        try spy.files.createSymlink(at: skillDirectory + "/alias", pointingTo: skillDirectory + "/assets")
        try spy.files.createSymlink(at: skillDirectory + "/assets/linked.png",
                                    pointingTo: skillDirectory + "/assets/red image.png")
        let loader = PreviewImageLoader(fileService: spy)
        let image = try loader.loadImage(at: URL(string: "alias/red%20image.png")!, skillDirectory: skillDirectory)
        XCTAssertEqual(image.width, 32)
        let before = spy.bytesRead
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "alias/linked.png")!, skillDirectory: skillDirectory))
        XCTAssertEqual(spy.bytesRead, before)
    }

    func testUnreadableInvalidAndOversizedImagesAreRefused() throws {
        let loader = PreviewImageLoader(fileService: spy)
        spy.unreadablePath = skillDirectory + "/assets/red image.png"
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "assets/red%20image.png")!, skillDirectory: skillDirectory))
        XCTAssertEqual(spy.bytesRead, 0)
        try spy.files.writeData(at: skillDirectory + "/invalid.png", data: Data("not an image".utf8))
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "invalid.png")!, skillDirectory: skillDirectory))
        let bytesBeforeOversized = spy.bytesRead
        // A real sparse file is rejected from fstat, without consuming its contents.
        let oversized = skillDirectory + "/large.png"
        try spy.files.writeData(at: oversized, data: png)
        let descriptor = open(oversized, O_WRONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(ftruncate(descriptor, off_t(4 * 1_024 * 1_024 + 1)), 0)
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "large.png")!, skillDirectory: skillDirectory))
        XCTAssertEqual(spy.bytesRead, bytesBeforeOversized)
        let invalidData = ["data:image/png;base64,not-base64!", "data:image/png,%XX", "data:text/plain;base64,AAAA",
                           "data:image/png;base64," + Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1).base64EncodedString()]
        for source in invalidData {
            XCTAssertThrowsError(try loader.loadImage(at: URL(string: source)!, skillDirectory: skillDirectory))
        }
    }
}
