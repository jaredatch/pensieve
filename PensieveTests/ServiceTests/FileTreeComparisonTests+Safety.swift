import Darwin
import XCTest
@testable import Pensieve

extension FileTreeComparisonTests {
    func testUpstreamSymlinksAtRootAndNestedDepthRefuseBeforeReading() throws {
        try files.writeFile(at: root + "/sentinel", content: "do not read me")
        for relative in ["link", "nested/deeper/link"] {
            try files.createSymlink(at: new + "/" + relative, pointingTo: root + "/sentinel")
            var reads = 0
            XCTAssertThrowsError(try compare { if case .read = $0 { reads += 1 } }) { error in
                XCTAssertTrue(error.localizedDescription.contains(relative))
            }
            XCTAssertEqual(reads, 0)
            try files.deleteFile(at: new + "/" + relative)
        }
    }

    func testLocalNestedAndDanglingLinksRefuseBeforeReading() throws {
        for target in [root + "/sentinel", root + "/missing"] {
            try files.writeFile(at: root + "/sentinel", content: "do not read me")
            let path = old + "/nested/deeper/link"
            try files.createSymlink(at: path, pointingTo: target)
            var reads = 0
            XCTAssertThrowsError(try compare { if case .read = $0 { reads += 1 } }) { error in
                XCTAssertTrue(error.localizedDescription.contains(path))
            }
            XCTAssertEqual(reads, 0)
            try files.deleteFile(at: path)
        }
    }

    func testLocalFIFORefusesWithoutBlocking() throws {
        let path = old + "/fifo"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try compare()) { error in XCTAssertTrue(error.localizedDescription.contains(path)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testLocalSocketRefusesBeforeReading() throws {
        // sockaddr_un's path buffer is shorter than this Mac's per-user temp prefix plus our UUID.
        try files.deleteDirectory(at: root)
        root = "/tmp/ComparisonSocket-\(UUID().uuidString)"
        try files.createDirectory(at: old)
        try files.createDirectory(at: new)
        let path = old + "/socket"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array((path + "\0").utf8)
        XCTAssertLessThanOrEqual(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        XCTAssertEqual(result, 0)
        XCTAssertThrowsError(try compare()) { error in XCTAssertTrue(error.localizedDescription.contains(path)) }
    }

    func testUnreadableLocalFolderNamesPath() throws {
        let path = old + "/unreadable"
        try files.createDirectory(at: path)
        XCTAssertEqual(chmod(path, 0), 0)
        defer { XCTAssertEqual(chmod(path, 0o700), 0) }
        XCTAssertThrowsError(try compare()) { error in XCTAssertTrue(error.localizedDescription.contains(path)) }
    }

    func testDisappearingAndSymlinkSubstitutedDirectoriesFailWithPath() throws {
        for replaceWithLink in [false, true] {
            let path = old + "/disappears"
            try files.writeFile(at: path + "/file", content: "old")
            var mutated = false
            XCTAssertThrowsError(try compare { event in
                if case let .directory(directory) = event, directory == path {
                    try self.files.deleteDirectory(at: path)
                    if replaceWithLink { try self.files.createSymlink(at: path, pointingTo: self.new) }
                    mutated = true
                }
            }) { error in XCTAssertTrue(error.localizedDescription.contains(path)) }
            XCTAssertTrue(mutated)
            if replaceWithLink { try files.deleteFile(at: path) }
        }
    }

    func testLeafSubstitutedAfterWalkNeverReadsThroughLinkOrFIFO() throws {
        for substituteFIFO in [false, true] {
            let path = old + "/file"
            try files.writeFile(at: path, content: "old")
            var reads = 0
            var mutated = false
            XCTAssertThrowsError(try compare { event in
                if case let .directory(directory) = event, directory == self.new {
                    try self.files.deleteFile(at: path)
                    if substituteFIFO {
                        XCTAssertEqual(mkfifo(path, 0o600), 0)
                    } else {
                        try self.files.createSymlink(at: path, pointingTo: self.root + "/missing")
                    }
                    mutated = true
                }
                if case .read = event { reads += 1 }
            }) { error in XCTAssertTrue(error.localizedDescription.contains(path)) }
            XCTAssertTrue(mutated)
            XCTAssertEqual(reads, 0)
            try files.deleteFile(at: path)
        }
    }
}
