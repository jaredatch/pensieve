import Darwin
import SwiftData
import XCTest
@testable import Pensieve

extension ImportFolderTests {
    func testEntryLimitStopsAt1001AndContinuesOtherSelections() async throws {
        let oversized = try source("Oversized")
        for index in 0..<1_200 { try files.writeFile(at: oversized + "/entry-\(index)", content: "") }
        let good = try source("Good")
        try files.writeFile(at: good + "/retained", content: "good bytes")
        let spy = ImportPublicationFileService()
        var entries = 0
        spy.importCheckpoint = { checkpoint in
            if case .entry = checkpoint { entries += 1 }
        }
        let model = model(using: spy)
        model.scan()
        model.importSelected(context: try context())
        XCTAssertEqual(model.importedSkillCount, 1)
        XCTAssertEqual(entries, 1_001 + 2, "The oversized skill stops before reading entry 1,002")
        XCTAssertEqual(try files.listDirectory(at: store + "/skills"), ["good"])
        XCTAssertEqual(try files.readFile(at: store + "/skills/good/retained"), "good bytes")
        let notice = "Oversized: The skill folder is too large (more than 1,000 entries)."
        XCTAssertTrue(model.importNotices.contains(notice))
        try await assertRendered([notice], model: model)
        try assertNoTemps()

        let exact = try source("Exact")
        for index in 0..<999 { try files.writeFile(at: exact + "/entry-\(index)", content: "") }
        XCTAssertEqual(model.scanFolder(exact), .found(1))
        model.importSelected(context: try context())
        XCTAssertNil(model.error, "Exactly 1,000 entries is admitted")
        XCTAssertEqual(try files.listDirectory(at: store + "/skills/exact").count, 1_000)
    }

    func testByteLimitBoundsMeasuredOversizeAndGrowthDuringReadAndContinues() async throws {
        for growing in [false, true] {
            let name = growing ? "Growing" : "Measured"
            let source = try source(name)
            let textBytes = try files.readData(at: source + "/SKILL.md").count
            let firstSize = 32 * 1_024 * 1_024
            let secondSize = 64 * 1_024 * 1_024 - textBytes - firstSize
            try sparseFile(at: source + "/first", size: firstSize)
            try sparseFile(at: source + "/second", size: secondSize + (growing ? 0 : 1))
            let good = try self.source("Good")
            let spy = ImportPublicationFileService()
            var readBytes = 0
            var grew = false
            spy.read = { descriptor, buffer, requested in
                // Grow the second file after its first chunk, with the first file already charged.
                if growing && !grew && readBytes >= firstSize + 64 * 1_024 {
                    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    XCTAssertEqual(fcntl(descriptor, F_GETPATH, &path), 0)
                    XCTAssertTrue(String(cString: path).hasSuffix("/second"))
                    do {
                        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: String(cString: path)))
                        defer { try? writer.close() }
                        try writer.truncate(atOffset: UInt64(secondSize + 1_024))
                        grew = true
                    } catch { XCTFail("Growth fixture failed: \(error)"); errno = EIO; return -1 }
                }
                let count = Darwin.read(descriptor, buffer, requested)
                if count > 0 { readBytes += count }
                return count
            }
            let model = model(using: spy)
            model.scan()
            model.selectedSkills = [source + "/SKILL.md", good + "/SKILL.md"]
            let context = try context()
            model.importSelected(context: context)
            XCTAssertEqual(model.importedSkillCount, 1)
            XCTAssertNil(try files.entryTypeWithoutFollowingLinks(at: store + "/skills/" + name.lowercased()))
            let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            XCTAssertEqual(saved.name, "Good")
            XCTAssertTrue(files.fileExists(at: store + "/skills/" + saved.directoryName + "/SKILL.md"))
            if growing {
                XCTAssertTrue(grew)
                XCTAssertEqual(readBytes + textBytes, 64 * 1_024 * 1_024 + 1)
            } else { XCTAssertEqual(readBytes, 0, "Measured oversize is refused before copying any asset") }
            let notice = "\(name): The skill folder is too large (more than 64 MiB of file data)."
            XCTAssertTrue(model.importNotices.contains(notice))
            try await assertRendered([notice], model: model)
            try assertNoTemps()
        }
        try assertExactByteLimit()
    }

    private func assertExactByteLimit() throws {
        let exact = try source("ExactBytes")
        let textBytes = try files.readData(at: exact + "/SKILL.md").count
        try sparseFile(at: exact + "/asset", size: 64 * 1_024 * 1_024 - textBytes)
        let model = model()
        XCTAssertEqual(model.scanFolder(exact), .found(1))
        model.importSelected(context: try context())
        XCTAssertNil(model.error, "Exactly 64 MiB of source data is admitted")
        XCTAssertEqual(try files.readData(at: store + "/skills/exactbytes/asset").count,
                       64 * 1_024 * 1_024 - textBytes)
    }

    func sparseFile(at path: String, size: Int) throws {
        try files.writeData(at: path, data: Data())
        let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? writer.close() }
        try writer.truncate(atOffset: UInt64(size))
    }

    func testReadErrorAfterFirstChunkFailsOnlyThatSkillAndCleansTemp() throws {
        let bad = try source("Unreadable")
        try files.writeData(at: bad + "/asset", data: Data(repeating: 42, count: 128 * 1_024))
        let good = try source("Good")
        let spy = ImportPublicationFileService()
        var successfulReads = 0
        spy.read = { descriptor, buffer, requested in
            if successfulReads == 1 { errno = EIO; return -1 }
            let count = Darwin.read(descriptor, buffer, requested)
            if count > 0 { successfulReads += 1 }
            return count
        }
        let model = model(using: spy)
        model.scan()
        model.selectedSkills = [bad + "/SKILL.md", good + "/SKILL.md"]
        let context = try context()
        model.importSelected(context: context)
        XCTAssertEqual(successfulReads, 1, "A read succeeded before EIO, exercising partial cleanup")
        XCTAssertTrue(model.error?.contains("Input/output error") == true)
        XCTAssertEqual(model.importedSkillCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Skill>()).map(\.directoryName), ["good"])
        XCTAssertEqual(try files.listDirectory(at: store + "/skills"), ["good"])
        try assertNoTemps()
    }
}
