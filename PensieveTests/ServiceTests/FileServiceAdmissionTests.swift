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

    func testAdmissionErrorsNamePlainAndDirectoryRelativeCalls() throws {
        let missing = root + "/missing"
        let operations: [() throws -> Void] = [
            { _ = try self.files.readRegularFileData(at: missing, maximumBytes: 1_024) },
            { try self.files.copyFile(at: missing, to: self.root + "/destination") },
            { try self.files.touchRegularFile(at: missing, date: Date()) }
        ]
        for operation in operations {
            XCTAssertThrowsError(try operation()) { error in
                self.assertPOSIX(error, code: ENOENT, operation: "open", path: missing)
                XCTAssertEqual((error as NSError).userInfo[NSFilePathErrorKey] as? String, missing)
                XCTAssertEqual(error.localizedDescription, "open(\(missing)): " + String(cString: strerror(ENOENT)))
            }
        }
        let directory = open(root, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { close(directory) }
        XCTAssertThrowsError(try FileService.openRegularFile(at: "missing", relativeTo: directory, reportingPath: missing)) {
            self.assertPOSIX($0, code: ENOENT, operation: "openat", path: missing)
            XCTAssertEqual($0.localizedDescription, "openat(\(missing)): " + String(cString: strerror(ENOENT)))
        }
    }

    func testCopyCreationErrorNamesTheHiddenSiblingTemporary() throws {
        let source = root + "/source"
        let destination = root + "/missing/destination"
        try files.writeFile(at: source, content: "Keep source bytes")
        XCTAssertThrowsError(try files.copyFile(at: source, to: destination)) { error in
            self.assertPOSIX(error, code: ENOENT, operation: "create", path: destination)
            let temporary = (error as NSError).userInfo[NSFilePathErrorKey] as? String ?? ""
            XCTAssertTrue(temporary.hasPrefix(self.root + "/missing/.pensieve-copy-"), temporary)
            XCTAssertTrue(temporary.hasSuffix(".tmp"), temporary)
            XCTAssertEqual(error.localizedDescription, "open(\(temporary)): " + String(cString: strerror(ENOENT)))
        }
        XCTAssertFalse(files.fileExists(at: destination))
        XCTAssertEqual(try files.readFile(at: source), "Keep source bytes")
        XCTAssertEqual(try files.listDirectory(at: root), ["source"])
    }

    /// Audit every direct no-follow open/openat in app sources, including nested argument calls.
    /// Only flags containing O_DIRECTORY exempt an open from regular-file admission. Standalone
    /// comments are ignored; aliases and computed flags remain outside this textual audit.
    func testNoFollowNonblockingAdmissionHasOneImplementation() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var matches: [String] = []
        var directoryMatches: [String] = []
        let directoryCopyPath = sourceRoot.appendingPathComponent("Pensieve/Services/FileService+DirectoryCopy.swift").path
        for path in try swiftSources(in: sourceRoot.appendingPathComponent("Pensieve").path) {
            let source = try files.readFile(at: path).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for flags in try openFlags(in: source) where flags.range(of: #"\bO_NOFOLLOW\b"#, options: .regularExpression) != nil {
                if flags.range(of: #"\bO_DIRECTORY\b"#, options: .regularExpression) != nil {
                    directoryMatches.append(path)
                } else {
                    matches.append(path)
                }
            }
        }
        XCTAssertEqual(matches, [sourceRoot.appendingPathComponent("Pensieve/Services/FileService+BoundedRead.swift").path],
                       "Regular-file descriptor admission must have one implementation: \(matches)")
        XCTAssertEqual(directoryMatches, [directoryCopyPath], "Only the held source directory needs separate admission")
    }

    private func openFlags(in source: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"\b(open(?:at)?)\s*\("#)
        let text = source as NSString
        return pattern.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let flagIndex = text.substring(with: match.range(at: 1)) == "openat" ? 2 : 1
            var depth = 1
            var argument = 0
            var start = NSMaxRange(match.range)
            for offset in start..<text.length {
                switch text.character(at: offset) {
                case 40: depth += 1 // (
                case 41: depth -= 1 // )
                default: break
                }
                let argumentEnd = depth == 0 || (depth == 1 && text.character(at: offset) == 44)
                if argumentEnd {
                    if argument == flagIndex { return text.substring(with: NSRange(location: start, length: offset - start)) }
                    argument += 1
                    start = offset + 1
                }
                if depth == 0 { break }
            }
            return nil
        }
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
