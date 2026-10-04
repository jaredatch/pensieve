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
            FileServiceErrorAssertions.hiddenCopyTemporary(error, destination: destination, code: ENOENT)
        }
        XCTAssertFalse(files.fileExists(at: destination))
        XCTAssertEqual(try files.readFile(at: source), "Keep source bytes")
        XCTAssertEqual(try files.listDirectory(at: root), ["source"])
    }

    /// Audit every direct no-follow open/openat in app and daemon sources, including nested argument calls.
    /// Only flags containing O_DIRECTORY exempt an open from regular-file admission. Standalone
    /// comments are ignored; aliases and computed flags remain outside this textual audit.
    func testNoFollowNonblockingAdmissionHasOneImplementation() throws {
        let admissions = try noFollowAdmissions(in: sourceRoot)
        XCTAssertEqual(admissions.regular,
                       [sourceRoot.appendingPathComponent("Pensieve/Services/FileService+BoundedRead.swift").path],
                       "Regular-file descriptor admission must have one implementation: \(admissions.regular)")
        XCTAssertEqual(admissions.directories,
                       [sourceRoot.appendingPathComponent("Pensieve/Services/FileService+DirectoryCopy.swift").path],
                       "Only the held source directory needs separate admission")
    }

    func testAdmissionGuardCountsNoFollowFamilyFlagsInScratchCopy() throws {
        let scratch = try copyAdmissionSources()
        let path = scratch.appendingPathComponent("Pensieve/Services/FileService+DirectoryCopy.swift").path
        try files.writeFile(at: path, content: files.readFile(at: path) + """

        func secondOpen(_ path: String) { _ = open(path, O_RDONLY | O_NOFOLLOW_ANY) } // PLAN43_C11_FLAG_MUTATION
        """)
        XCTAssertEqual(try files.readFile(at: path).components(separatedBy: "PLAN43_C11_FLAG_MUTATION").count - 1, 1)
        let admissions = try noFollowAdmissions(in: scratch)
        XCTAssertEqual(admissions.regular.count, 2, "The second open must fail the single-implementation guard")
        XCTAssertTrue(admissions.regular.contains(path))
    }

    func testAdmissionGuardScansDaemonMainInScratchCopy() throws {
        let scratch = try copyAdmissionSources()
        let path = scratch.appendingPathComponent("PensieveDaemon/main.swift").path
        try files.writeFile(at: path, content: files.readFile(at: path) + """

        func secondOpen(_ path: String) { _ = open(path, O_RDONLY | O_NOFOLLOW) } // PLAN43_C11_DAEMON_MUTATION
        """)
        XCTAssertEqual(try files.readFile(at: path).components(separatedBy: "PLAN43_C11_DAEMON_MUTATION").count - 1, 1)
        let admissions = try noFollowAdmissions(in: scratch)
        XCTAssertEqual(admissions.regular.count, 2, "The daemon open must fail the single-implementation guard")
        XCTAssertTrue(admissions.regular.contains(path))
    }

    func testCreatedTemporaryIsRemovedThroughHeldDirectoryWhenStatFails() throws {
        let parent = root + "/parent"
        let parked = root + "/parked"
        let name = ".pensieve-copy-\(UUID().uuidString).tmp"
        try files.createDirectory(at: parent)
        let directory = open(parent, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        var inspected: Int32?
        XCTAssertThrowsError(try FileService.openRegularFile(
            at: name, relativeTo: directory, creatingWithPermissions: 0o600, reportingPath: parent + "/" + name,
            inspect: { descriptor, status in
                inspected = descriptor
                XCTAssertEqual(Darwin.fstat(descriptor, status), 0)
                XCTAssertEqual(status.pointee.st_mode & S_IFMT, S_IFREG)
                // Replace only the fixture's parent path; cleanup must use the held directory.
                do {
                    try self.files.replaceItem(at: parked, with: parent)
                    try self.files.writeFile(at: parent + "/" + name, content: "unrelated replacement")
                } catch { XCTFail("Fixture setup: \(error)") }
                errno = EIO
                return -1
            }
        )) { error in
            self.assertPOSIX(error, code: EIO, operation: "fstat", path: parent + "/" + name)
        }
        let descriptor = try XCTUnwrap(inspected, "The injected fstat must run after exclusive creation")
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF, "The failed admission must close its descriptor")
        XCTAssertEqual(try files.listDirectory(at: parked), [], "The created UUID temporary must be removed")
        XCTAssertEqual(try files.readFile(at: parent + "/" + name), "unrelated replacement")
        let (retry, _) = try FileService.openRegularFile(at: name, relativeTo: directory, creatingWithPermissions: 0o600)
        close(retry)
        XCTAssertTrue(files.isRegularFile(at: parked + "/" + name), "Exclusive creation can retry after cleanup")
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func copyAdmissionSources() throws -> URL {
        let scratch = URL(fileURLWithPath: root).appendingPathComponent("source-copy")
        for relative in ["Pensieve/Services/FileService+BoundedRead.swift",
                         "Pensieve/Services/FileService+DirectoryCopy.swift", "PensieveDaemon/main.swift"] {
            let destination = scratch.appendingPathComponent(relative)
            try files.createDirectory(at: destination.deletingLastPathComponent().path)
            try files.copyFile(at: sourceRoot.appendingPathComponent(relative).path, to: destination.path)
        }
        return scratch
    }

    private func noFollowAdmissions(in sourceRoot: URL) throws -> (regular: [String], directories: [String]) {
        var matches: [String] = []
        var directoryMatches: [String] = []
        let sources = try ["Pensieve", "PensieveDaemon"].flatMap {
            try swiftSources(in: sourceRoot.appendingPathComponent($0).path)
        }
        for path in sources {
            let source = try files.readFile(at: path).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for flags in try openFlags(in: source)
                where flags.range(of: #"\bO_NOFOLLOW\w*"#, options: .regularExpression) != nil {
                if flags.range(of: #"\bO_DIRECTORY\b"#, options: .regularExpression) != nil {
                    directoryMatches.append(path)
                } else {
                    matches.append(path)
                }
            }
        }
        return (matches, directoryMatches)
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
