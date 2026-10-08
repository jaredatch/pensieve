import Darwin
import XCTest
@testable import Pensieve

extension ImportFolderTests {
    func assertChangedRegularCopiesAreSkipped() async throws {
        let cases = [("PreReplace", "replace", false), ("PreResize", "resize", false),
                     ("PreTimestamp", "timestamp", false), ("MidRewrite", "rewrite", true),
                     ("MidResize", "resize", true), ("MidReplace", "replace", true)]
        var final: (ImportViewModel, String)?
        for (name, change, duringRead) in cases {
            let source = try source(name)
            let changing = source + "/changing"
            try files.writeData(at: changing, data: Data(repeating: 42, count: 128 * 1_024))
            try files.writeFile(at: source + "/retained", content: "included")
            let spy = ImportPublicationFileService()
            var changed = false
            spy.importCheckpoint = { checkpoint in
                guard !changed else { return }
                let eligible: Bool
                switch checkpoint {
                case .copying("changing"): eligible = !duringRead
                case .copiedChunk("changing", _): eligible = duringRead
                default: eligible = false
                }
                guard eligible else { return }
                try self.changeRegularSource(at: changing, change: change)
                changed = true
            }
            var bytesRead = 0
            spy.read = { descriptor, buffer, requested in
                let count = Darwin.read(descriptor, buffer, requested)
                if count > 0 { bytesRead += count }
                return count
            }
            let model = model(using: spy)
            XCTAssertEqual(model.scanFolder(source), .found(1))
            model.importSelected(context: try context())
            XCTAssertTrue(changed, name)
            XCTAssertNil(model.error, name)
            XCTAssertEqual(model.importedSkillCount, 1, name)
            let imported = store + "/skills/" + name.lowercased()
            XCTAssertFalse(files.fileExists(at: imported + "/changing"), name)
            XCTAssertEqual(try files.readFile(at: imported + "/retained"), "included", name)
            let notice = name + ": Changed during import, so left out: changing"
            XCTAssertEqual(model.importNotices, [notice], name)
            if duringRead { XCTAssertGreaterThanOrEqual(bytesRead, 64 * 1_024 + 8, name) } else {
                XCTAssertEqual(bytesRead, 8, "A change since inventory is skipped before any source bytes are read")
            }
            final = (model, notice)
            try assertNoTemps()
        }
        let (model, notice) = try XCTUnwrap(final)
        try await assertRendered([notice], model: model)
    }

    private func changeRegularSource(at path: String, change: String) throws {
        if change == "replace" {
            try files.writeData(at: path, data: Data(repeating: 99, count: 128 * 1_024))
        } else if change == "timestamp" {
            try files.touchRegularFile(at: path, date: Date(timeIntervalSince1970: 1_000))
        } else {
            let writer = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? writer.close() }
            if change == "resize" { try writer.truncate(atOffset: UInt64(128 * 1_024 + 16)) } else {
                try writer.write(contentsOf: Data(repeating: 99, count: 128 * 1_024))
            }
        }
    }

    func assertDepthLimitFailsOnlyThatSelection() async throws {
        let deep = try source("TooDeep")
        let path = String(repeating: "d/", count: 65) + "leaf"
        try files.writeFile(at: deep + "/" + path, content: "too deep")
        let good = try source("DepthGood")
        try files.writeFile(at: good + "/retained", content: "included")
        let model = model()
        model.scan()
        model.selectedSkills = [deep + "/SKILL.md", good + "/SKILL.md"]
        model.importSelected(context: try context())
        XCTAssertEqual(model.importedSkillCount, 1)
        XCTAssertFalse(files.directoryExists(at: store + "/skills/toodeep"))
        XCTAssertEqual(try files.readFile(at: store + "/skills/depthgood/retained"), "included")
        let notice = "TooDeep: The skill folder is too large (more than 64 folders deep)."
        XCTAssertTrue(model.importNotices.contains(notice))
        try await assertRendered([notice], model: model, uniqueFailure: "The skill folder is too large")
        try assertNoTemps()

        let exact = try source("ExactDepth")
        let allowed = String(repeating: "d/", count: 64) + "leaf"
        try files.writeFile(at: exact + "/" + allowed, content: "at the depth bound")
        XCTAssertEqual(model.scanFolder(exact), .found(1))
        model.importSelected(context: try context())
        XCTAssertNil(model.error)
        XCTAssertEqual(try files.readFile(at: store + "/skills/exactdepth/" + allowed), "at the depth bound")
        try assertNoTemps()
    }
}
