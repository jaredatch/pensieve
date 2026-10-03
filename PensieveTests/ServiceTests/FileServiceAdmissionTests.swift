import Darwin
import XCTest
@testable import Pensieve

final class FileServiceAdmissionTests: XCTestCase {
    private let files = FileService()
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "FileServiceAdmission-\(UUID().uuidString)"
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws {
        try files.deleteDirectory(at: root)
    }

    func testCopyReadAndTouchUseTheSameRegularLeafAdmissionErrors() throws {
        let directory = root + "/directory"
        let fifo = root + "/fifo"
        let link = root + "/link"
        try files.createDirectory(at: directory)
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try files.writeFile(at: root + "/regular", content: "Regular")
        try files.createSymlink(at: link, pointingTo: root + "/regular")
        let candidates: [(String, Int32)] = [
            (directory, EISDIR), (fifo, EFTYPE), (link, ELOOP), (root + "/missing", ENOENT), ("/dev/null", EFTYPE)
        ]
        for (path, code) in candidates {
            let destination = root + "/destination"
            XCTAssertThrowsError(try files.copyFile(at: path, to: destination)) { error in
                self.assertPOSIX(error, code: code, operation: "copy", path: path)
            }
            XCTAssertFalse(files.fileExists(at: destination), "A refused source must not create a destination")
            XCTAssertThrowsError(try files.readRegularFileData(at: path, maximumBytes: 1_024)) { error in
                self.assertPOSIX(error, code: code, operation: "read", path: path)
            }
            XCTAssertThrowsError(try files.touchRegularFile(at: path, date: Date())) { error in
                self.assertPOSIX(error, code: code, operation: "touch", path: path)
            }
        }
    }

    func testCopyPreservesBinaryBytesModeAndExistingDestinationBehavior() throws {
        let source = root + "/source/file"
        let destination = root + "/copied"
        let bytes = Data([0x00, 0xFF, 0x80, 0x41, 0x0A])
        try files.writeData(at: source, data: bytes)
        // Fixture-only mode setup and inspection, independent of the production copy implementation.
        XCTAssertEqual(chmod(source, 0o751), 0)
        try files.writeFile(at: destination, content: "Replace this destination")
        try files.createSymlink(at: root + "/source-alias", pointingTo: root + "/source")

        try files.copyFile(at: root + "/source-alias/file", to: destination)

        XCTAssertEqual(try files.readRegularFileData(at: destination, maximumBytes: bytes.count), bytes)
        var status = stat()
        XCTAssertEqual(lstat(destination, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o751)
    }

    /// Audit direct open calls spelling both safety flags, including line breaks and either flag
    /// order. Standalone comments are ignored. This catches ordinary admission copies, not aliases,
    /// computed flags or arbitrary Swift syntax. Source enumeration and reads use FileService.
    func testNoFollowNonblockingAdmissionHasOneImplementation() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(
            pattern: #"\bopen\s*\((?=[^)]*\bO_NOFOLLOW\b)(?=[^)]*\bO_NONBLOCK\b)[^)]*\)"#
        )
        var matches: [String] = []
        for path in try swiftSources(in: sourceRoot.appendingPathComponent("Pensieve").path) {
            let source = try files.readFile(at: path).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            matches += pattern.matches(in: source, range: range).map { _ in path }
        }
        XCTAssertEqual(matches.count, 1, "Regular-file descriptor admission must have one implementation: \(matches)")
    }

    private func assertPOSIX(_ error: Error, code: Int32, operation: String, path: String) {
        let failure = error as NSError
        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain, "\(operation): \(path)")
        XCTAssertEqual(failure.code, Int(code), "\(operation) admission: \(path)")
    }

    private func swiftSources(in directory: String) throws -> [String] {
        var result: [String] = []
        for name in try files.listDirectory(at: directory) {
            let path = directory + "/" + name
            if files.directoryExists(at: path) {
                result += try swiftSources(in: path)
            } else if name.hasSuffix(".swift") {
                result.append(path)
            }
        }
        return result
    }
}
