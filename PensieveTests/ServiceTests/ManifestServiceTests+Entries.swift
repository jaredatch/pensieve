import Darwin
import XCTest
@testable import Pensieve

extension ManifestServiceTests {
    func testGeneratedManifestSlotOccupantsHaveExplicitReadVerdicts() throws {
        let machine = "11111111-1111-4111-8111-111111111111"
        let category = "categories/" + ManifestService.categoryFileName("Swift")
        let slots = ["", "manifest.yaml", "categories", category, "skills", "skills/plain.yaml",
                     "deploys", "deploys/" + machine, "deploys/" + machine + "/plain.yaml", "projects.yaml"]
        let directories: Set<String> = ["", "categories", "skills", "deploys", "deploys/" + machine]
        let occupants = ["missing", "file", "folder", "file link", "folder link", "FIFO", "unreadable"]
        for slot in slots {
            for occupant in occupants {
                let root = tempDir + "/cell-" + UUID().uuidString
                var input = sampleManifestSnapshot()
                input.deployIntents = [DeployIntentRecord(machineID: machine, skillSlug: "plain", platformRaw: "claude")]
                try service.write(input, toRoot: root)
                let baseline = try service.read(fromRoot: root)
                let path = root + "/manifest" + (slot.isEmpty ? "" : "/" + slot)
                let isDirectory = directories.contains(slot)
                let data = isDirectory ? Data("not a directory".utf8) : try fileService.readData(at: path)
                try fileService.deleteDirectory(at: path)
                try installManifestOccupant(occupant, at: path, target: root + "/target", data: data, directory: isDirectory)
                defer { if occupant == "unreadable" { _ = chmod(path, 0o700) } }
                let label = "\(slot.isEmpty ? "manifest" : slot), \(occupant)"
                if occupant == "missing" || (isDirectory && occupant == "folder") || (!isDirectory && occupant == "file") {
                    let result = try ManifestService.classifiedRead(using: service, root: root, files: fileService).snapshot
                    let expected = expectedManifestRead(baseline, slot: slot, category: category,
                                                        preservesFile: occupant == "file")
                    XCTAssertEqual(result, expected, label)
                } else {
                    XCTAssertThrowsError(
                        try ManifestService.classifiedRead(using: service, root: root, files: fileService), label
                    ) {
                        XCTAssertEqual($0 as? ManifestError, .damaged, label)
                    }
                }
            }
        }
    }

    private func installManifestOccupant(_ occupant: String, at path: String, target: String,
                                         data: Data, directory: Bool) throws {
        switch occupant {
        case "missing": break
        case "file": try fileService.writeData(at: path, data: data)
        case "folder": try fileService.createDirectory(at: path)
        case "file link":
            try fileService.writeData(at: target, data: data)
            try fileService.createSymlink(at: path, pointingTo: target)
        case "folder link":
            try fileService.createDirectory(at: target)
            try fileService.createSymlink(at: path, pointingTo: target)
        case "FIFO": XCTAssertEqual(mkfifo(path, 0o600), 0)
        default:
            if directory { try fileService.createDirectory(at: path) } else {
                try fileService.writeData(at: path, data: data)
            }
            XCTAssertEqual(chmod(path, 0), 0)
        }
    }

    private func expectedManifestRead(_ baseline: ManifestSnapshot, slot: String,
                                      category: String, preservesFile: Bool) -> ManifestSnapshot {
        guard !preservesFile else { return baseline }
        var expected = baseline
        if slot.isEmpty || slot == "categories" { expected.categories = [] }
        if slot == category { expected.categories.removeAll { $0.name == "Swift" } }
        if slot.isEmpty || slot == "skills" { expected.skills = [] }
        if slot == "skills/plain.yaml" { expected.skills.removeAll { $0.slug == "plain" } }
        if slot.isEmpty || slot.hasPrefix("deploys") { expected.deployIntents = [] }
        if slot.isEmpty || slot == "projects.yaml" { expected.projects = [] }
        return expected
    }

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
