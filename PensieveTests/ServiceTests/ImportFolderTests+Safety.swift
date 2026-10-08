import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension ImportFolderTests {
    func testLinkedSelectedFolderCopiesItsTargetButSkipsInteriorLinksAndSpecialFiles() async throws {
        // UNIX sockets require a short system temp path; this entire fixture is removed at teardown.
        try files.deleteDirectory(at: root)
        root = TestTemporaryDirectory.systemPath + "IF-" + UUID().uuidString.prefix(8)
        let target = root + "/real"
        try files.writeFile(at: target + "/SKILL.md", content: body)
        try files.writeFile(at: target + "/scripts/regular", content: "regular bytes")
        try files.writeFile(at: root + "/outside", content: "outside sentinel")
        try files.writeFile(at: root + "/outside-folder/payload", content: "outside directory sentinel")
        try files.createSymlink(at: target + "/file-link", pointingTo: root + "/outside")
        try files.createSymlink(at: target + "/folder-link", pointingTo: root + "/outside-folder")
        let fifo = target + "/pipe"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let socket = try makeSocket(at: target + "/socket")
        defer { close(socket) }
        try files.createSymlink(at: sources + "/linked", pointingTo: target)
        let spy = ImportPublicationFileService()
        var readPaths: [String] = []
        spy.read = { descriptor, buffer, requested in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertEqual(fcntl(descriptor, F_GETPATH, &path), 0)
            readPaths.append(String(cString: path))
            return Darwin.read(descriptor, buffer, requested)
        }
        let model = model(using: spy)
        XCTAssertEqual(model.scanFolder(sources + "/linked"), .found(1))
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try boundedImportScan(fifo: fifo) {
            model.importSelected(context: ModelContext(container))
            return []
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.importedSkillCount, 1)
        XCTAssertEqual(try files.readFile(at: store + "/skills/folder/scripts/regular"), "regular bytes")
        XCTAssertFalse(readPaths.isEmpty, "A real regular-file copy must have run")
        XCTAssertTrue(readPaths.allSatisfy { $0 == files.realPath(at: target + "/scripts/regular") })
        let notices = ["Folder: Skipped file-link: a link.", "Folder: Skipped folder-link: a link.",
                       "Folder: Skipped pipe: a special file.", "Folder: Skipped socket: a special file."]
        XCTAssertEqual(Set(model.importNotices), Set(notices))
        for entry in ["file-link", "folder-link", "pipe", "socket"] {
            XCTAssertNil(try files.entryTypeWithoutFollowingLinks(at: store + "/skills/folder/" + entry))
        }
        XCTAssertEqual(try files.readFile(at: root + "/outside"), "outside sentinel")
        try await assertRendered(notices, model: model)
        try assertNoTemps()
    }

    func testLeafSubstitutedAfterInventoryIsSkippedWithoutReadingOrBlocking() throws {
        for kind in ["symlink", "fifo"] {
            let source = try source(kind)
            try files.writeFile(at: source + "/changing", content: "original")
            try files.writeFile(at: source + "/retained", content: "included")
            try files.writeFile(at: root + "/outside", content: "outside sentinel")
            let spy = ImportPublicationFileService()
            let guardFIFO = root + "/guard-fifo"
            if kind == "fifo" { XCTAssertEqual(mkfifo(guardFIFO, 0o600), 0) }
            var substituted = false
            spy.importCheckpoint = { checkpoint in
                if case .copying("changing") = checkpoint {
                    try self.files.deleteFile(at: source + "/changing")
                    if kind == "symlink" {
                        try self.files.createSymlink(at: source + "/changing", pointingTo: self.root + "/outside")
                    } else { XCTAssertEqual(Darwin.rename(guardFIFO, source + "/changing"), 0) }
                    substituted = true
                }
            }
            var bytesRead = 0
            spy.read = { descriptor, buffer, requested in
                let count = Darwin.read(descriptor, buffer, requested)
                if count > 0 { bytesRead += count }
                return count
            }
            let model = model(using: spy)
            XCTAssertEqual(model.scanFolder(source), .found(1))
            let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
            if kind == "fifo" {
                // The helper's writer remains on the same FIFO inode when it is renamed into the source.
                _ = try boundedImportScan(fifo: guardFIFO) {
                    model.importSelected(context: ModelContext(container))
                    return []
                }
            } else { model.importSelected(context: container.mainContext) }
            XCTAssertTrue(substituted)
            XCTAssertNil(model.error)
            XCTAssertEqual(bytesRead, Data("included".utf8).count)
            XCTAssertNil(try files.entryTypeWithoutFollowingLinks(at: store + "/skills/" + kind + "/changing"))
            XCTAssertEqual(try files.readFile(at: store + "/skills/" + kind + "/retained"), "included")
            XCTAssertEqual(model.importNotices, ["\(kind): Skipped changing: changed during the copy."])
            try assertNoTemps()
        }
    }

    private func makeSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThan(path.utf8.count, capacity)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, source, capacity) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(descriptor); throw POSIXError(.EIO) }
        return descriptor
    }
}
