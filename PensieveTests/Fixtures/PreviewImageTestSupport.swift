import AppKit
import Darwin
import ImageIO
import XCTest
@testable import Pensieve

enum PreviewImageFixture {
    static func decodedPNG() throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try png() as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    static func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                             bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Models both bounded-read variants on a temporary tree. Records the actual descriptor callbacks,
/// refusing an explicitly modeled unreadable path before reading. Other filesystem operations forward
/// to FileService. It does not perform network I/O or model permission failures via host privileges.
final class PreviewImageFileSpy: FileServiceProtocol {
    struct Read {
        let path: String
        let limit: Int
        let root: String
    }

    let files = FileService()
    var unreadablePath: String?
    private(set) var writes: [String] = []
    private let lock = NSLock()
    private var recordedReads: [Read] = []
    private var recordedBytes = 0
    var reads: [Read] { lock.withLock { recordedReads } }
    var bytesRead: Int { lock.withLock { recordedBytes } }

    func readRegularFileData(at path: String, maximumBytes: Int, containedIn directory: String) throws -> Data {
        lock.withLock { recordedReads.append(Read(path: path, limit: maximumBytes, root: directory)) }
        if let unreadablePath,
           URL(fileURLWithPath: path).standardizedFileURL == URL(fileURLWithPath: unreadablePath).standardizedFileURL {
            throw CocoaError(.fileReadNoPermission)
        }
        return try files.readRegularFileData(at: path, maximumBytes: maximumBytes, read: { descriptor, buffer, count in
            let result = Darwin.read(descriptor, buffer, count)
            if result > 0 { self.lock.withLock { self.recordedBytes += result } }
            return result
        }, containedIn: directory)
    }

    func readRegularFileData(at path: String, maximumBytes: Int) throws -> Data {
        XCTFail("Preview image read omitted its containment guard")
        throw CocoaError(.featureUnsupported)
    }
    func readFile(at path: String) throws -> String { try files.readFile(at: path) }
    func writeFile(at path: String, content: String) throws {
        writes.append(path)
        try files.writeFile(at: path, content: content)
    }
    func deleteFile(at path: String) throws { try files.deleteFile(at: path) }
    func fileExists(at path: String) -> Bool { files.fileExists(at: path) }
    func isExecutableFile(at path: String) -> Bool { files.isExecutableFile(at: path) }
    func directoryExists(at path: String) -> Bool { files.directoryExists(at: path) }
    func listDirectory(at path: String) throws -> [String] { try files.listDirectory(at: path) }
    func createDirectory(at path: String) throws { try files.createDirectory(at: path) }
    func deleteDirectory(at path: String) throws { try files.deleteDirectory(at: path) }
    func createSymlink(at path: String, pointingTo target: String) throws {
        try files.createSymlink(at: path, pointingTo: target)
    }
    func symlinkTarget(at path: String) throws -> String { try files.symlinkTarget(at: path) }
    func isSymlink(at path: String) -> Bool { files.isSymlink(at: path) }
    func isRegularFile(at path: String) -> Bool { files.isRegularFile(at: path) }
    func contentsHash(at path: String) throws -> String { try files.contentsHash(at: path) }
}
