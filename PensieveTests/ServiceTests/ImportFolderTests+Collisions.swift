import Darwin
import XCTest
@testable import Pensieve

extension ImportFolderTests {
    func assertCaseCollisionsFailWithoutReplacingFiles() throws {
        // A real case-sensitive source is needed to keep both spellings as distinct inodes.
        let image = root + "/case-source.sparseimage"
        let mount = root + "/case-source"
        try files.createDirectory(at: mount)
        try runDiskImageTool(["create", "-size", "64m", "-fs", "HFSX", "-type", "SPARSE",
                              "-volname", "ImportCases", image])
        try runDiskImageTool(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount, image])
        defer {
            do { try runDiskImageTool(["detach", mount, "-force"]) } catch { XCTFail("Case source cleanup: \(error)") }
        }
        for name in ["Files", "Types", "LowerSkill", "MixedSkill", "CaseGood"] {
            try files.writeFile(at: mount + "/" + name + "/SKILL.md",
                                content: body.replacingOccurrences(of: "Folder", with: name))
        }
        try files.writeFile(at: mount + "/Files/refs/API.md", content: "upper bytes")
        try files.writeFile(at: mount + "/Files/refs/api.md", content: "lower bytes")
        XCTAssertEqual(Set(try files.listDirectory(at: mount + "/Files/refs")), ["API.md", "api.md"])
        XCTAssertNotEqual(files.fileIdentity(at: mount + "/Files/refs/API.md", followingLinks: false),
                          files.fileIdentity(at: mount + "/Files/refs/api.md", followingLinks: false))
        try files.writeFile(at: mount + "/Types/refs/API", content: "file bytes")
        try files.writeFile(at: mount + "/Types/refs/api/leaf", content: "folder bytes")
        try files.writeFile(at: mount + "/LowerSkill/skill.md", content: "not the prepared skill")
        try files.writeFile(at: mount + "/MixedSkill/Skill.md", content: "also not the prepared skill")
        try files.writeFile(at: mount + "/CaseGood/retained", content: "included")
        let model = model()
        XCTAssertEqual(model.scanFolder(mount), .found(5))
        model.importSelected(context: try context())
        XCTAssertEqual(model.importedSkillCount, 1, "All four collisions fail; the other selection still imports")
        for name in ["Files", "Types", "LowerSkill", "MixedSkill"] {
            XCTAssertFalse(files.directoryExists(at: store + "/skills/" + name.lowercased()), name)
            XCTAssertTrue(model.importNotices.contains { $0.hasPrefix(name + ": ") && $0.contains("differ only by case") }, name)
        }
        XCTAssertEqual(try files.readFile(at: store + "/skills/casegood/retained"), "included")
        XCTAssertEqual(try files.readFile(at: mount + "/Files/refs/API.md"), "upper bytes")
        XCTAssertEqual(try files.readFile(at: mount + "/Files/refs/api.md"), "lower bytes")
        try assertNoTemps()
    }

    private func runDiskImageTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + TestWait.timeoutSeconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let data = try errors.fileHandleForReading.readToEnd() ?? Data()
        let detail = String(bytes: data, encoding: .utf8) ?? "Unreadable tool error"
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ImportCaseSource", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? ""): \(detail)"])
        }
    }
}
