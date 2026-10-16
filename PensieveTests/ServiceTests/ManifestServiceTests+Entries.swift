import Darwin
import XCTest
@testable import Pensieve

extension ManifestServiceTests {
    func testManifestReadsRefuseLinkedAndSpecialEntriesWithoutFollowingTargets() throws {
        var snapshot = sampleManifestSnapshot()
        let machine = UUID().uuidString
        snapshot.deployIntents = [DeployIntentRecord(machineID: machine, skillSlug: "plain", platformRaw: "claude")]
        try service.write(snapshot, toRoot: tempDir)
        let entries = ["manifest.yaml", "projects.yaml", "skills/plain.yaml",
            "categories/" + ManifestService.categoryFileName("Swift"), "deploys/" + machine + "/plain.yaml"]
        for entry in entries {
            let path = tempDir + "/manifest/" + entry
            let data = try fileService.readData(at: path)
            let target = tempDir + "/outside.yaml"
            try fileService.writeData(at: target, data: data)
            try fileService.deleteFile(at: path)
            try fileService.createSymlink(at: path, pointingTo: target)
            let refused = (try? service.read(fromRoot: tempDir)) == nil
            XCTAssertTrue(refused, "Manifest links must be damaged: \(entry)")
            guard refused else { return } // Do not let the old reader open the FIFO below.
            try fileService.deleteFile(at: target)
            XCTAssertThrowsError(try service.read(fromRoot: tempDir), "A dangling link is not an absent optional file")
            XCTAssertEqual(mkfifo(target, 0o600), 0)
            XCTAssertThrowsError(try service.read(fromRoot: tempDir), "A FIFO link must refuse without opening")
            try fileService.deleteFile(at: path)
            try fileService.deleteFile(at: target)
            XCTAssertEqual(mkfifo(path, 0o600), 0)
            XCTAssertThrowsError(try service.read(fromRoot: tempDir))
            try fileService.deleteFile(at: path)
            try fileService.createSymlink(at: path, pointingTo: "/dev/zero")
            XCTAssertThrowsError(try service.read(fromRoot: tempDir), "A device link must refuse without opening")
            try fileService.deleteFile(at: path)
            try fileService.writeData(at: path, data: data)
        }
        try fileService.deleteFile(at: tempDir + "/manifest/projects.yaml")
        XCTAssertTrue(try service.read(fromRoot: tempDir).projects.isEmpty, "Missing optional projects still read")
    }
}
