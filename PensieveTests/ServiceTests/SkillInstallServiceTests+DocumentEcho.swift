import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testInstallAndFrontmatterOnlyUpdateRegisterWholeFileAtReplacement() throws {
        let documents = [("test", ""), ("bom-test", "\u{feff}")]
        let repository = try NativeTestWork.run { [self] in try makeRepository() }
        let container = try AppRuntime.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/store/skills", storeRoot: tempDir + "/store")
        let watcher = RecordingWatcher()
        let library = SkillLibraryViewModel(skillStore: store, fileService: fileService, fileWatchService: watcher,
            manifestRoot: tempDir + "/store")
        library.startWatching()
        let registration = SyncBodyWriteRegistration(begin: library.beginAppAuthoredBodyWrite,
            end: { library.finishAppAuthoredBodyWrite(directoryName: $0, succeeded: $1) })
        for updating in [false, true] {
            try NativeTestWork.run { [self] in
                for (slug, prefix) in documents {
                    try write("skills/\(slug)/SKILL.md",
                        content: prefix + "---\nname: Test\ndescription: \(updating ? "After" : "Before")\n---\nbody\n",
                        in: repository)
                }
                try commit(repository)
            }
            let source = try NativeTestWork.run { [self] in try service.fetch(repo: repository, ref: nil, credential: nil) }
            for (slug, prefix) in documents {
                let candidate = try XCTUnwrap(source.candidates.first { $0.slug == slug })
                try NativeTestWork.run(container: container) { [self] jobContext in
                    if updating {
                        try service.update(existingSlug: slug, candidate: candidate, from: source,
                            bodyWriteRegistration: registration, context: jobContext)
                    } else {
                        _ = try service.install(candidate: candidate, from: source,
                            bodyWriteRegistration: registration, context: jobContext)
                    }
                }
                let expected = prefix + "---\nname: Test\ndescription: \(updating ? "After" : "Before")\n---\nbody\n"
                XCTAssertEqual(try store.readData(directoryName: slug), Data(expected.utf8))
                XCTAssertTrue(library.wasLastWrittenByApp(directoryName: slug, currentBody: expected),
                    "\(slug), updating: \(updating)")
                let token = library.reloadToken
                library.noteAppAuthoredBodies(directoryNames: [slug])
                watcher.emit(slug)
                XCTAssertEqual(library.reloadToken, token)
                XCTAssertFalse(library.externallyModified.contains(slug), "\(slug), updating: \(updating)")
            }
        }
        try NativeTestWork.run { [self] in try checkVendorReadAdmission(repository: repository) }
    }

    @MainActor
    private func checkVendorReadAdmission(repository: String) throws {
        let source = try service.fetch(repo: repository, ref: nil, credential: nil)
        let candidate = try XCTUnwrap(source.candidates.first { $0.slug == "test" })
        for updating in [false, true] {
            for kind in ["regular", "invalid UTF-8", "symlink", "directory"] {
                let root = tempDir + "/admission-" + UUID().uuidString
                let context = try makeInstallContext()
                if updating {
                    _ = try makeInstallService(root: root).install(candidate: candidate, from: source, context: context)
                }
                let destination = root + "/skills/test/SKILL.md"
                let before = updating ? try fileService.readData(at: destination) : nil
                let spy = ImportPublicationFileService()
                var sampled: String?
                spy.beforeDataRead = { path, maximum in
                    guard sampled == nil, path.hasSuffix("/skills/test/SKILL.md") else { return }
                    sampled = path
                    XCTAssertEqual(maximum, Int.max, "Install and update use the store's bounded regular-file read")
                    try self.changeVendorLeaf(kind: kind, path: path, root: root, files: spy.files)
                }
                let installer = makeInstallService(root: root, using: spy)
                let apply = {
                    if updating {
                        try installer.update(existingSlug: "test", candidate: candidate, from: source, context: context)
                    } else { _ = try installer.install(candidate: candidate, from: source, context: context) }
                }
                if kind == "regular" { try apply() } else {
                    XCTAssertThrowsError(try apply()) { error in
                        if kind == "invalid UTF-8" {
                            XCTAssertEqual((error as NSError).userInfo[NSFilePathErrorKey] as? String, sampled)
                            XCTAssertTrue(error.localizedDescription.contains("SKILL.md"))
                        }
                    }
                    if let before { XCTAssertEqual(try fileService.readData(at: destination), before) } else {
                        XCTAssertFalse(fileService.fileExists(at: destination))
                    }
                }
                XCTAssertNotNil(sampled, "The vendor read must be reached: \(kind), update: \(updating)")
            }
        }
    }
    private func changeVendorLeaf(kind: String, path: String, root: String, files: FileService) throws {
        switch kind {
        case "invalid UTF-8": try files.writeData(at: path, data: Data([0xff]))
        case "symlink":
            let target = root + "/linked-source"
            try files.writeFile(at: target, content: "linked bytes")
            try files.deleteFile(at: path)
            try files.createSymlink(at: path, pointingTo: target)
        case "directory":
            try files.deleteFile(at: path)
            try files.createDirectory(at: path)
        default: break
        }
    }

}
