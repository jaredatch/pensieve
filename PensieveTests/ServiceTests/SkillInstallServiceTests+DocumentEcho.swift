import SwiftData
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    @MainActor
    func testInstallAndFrontmatterOnlyUpdateRegisterWholeFileAtReplacement() throws {
        let repository = try NativeTestWork.run { [self] in
            let repository = try makeRepository()
            try writeSkill("skills/test", name: "Test", description: "Before", in: repository)
            try commit(repository)
            return repository
        }
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
            if updating {
                try NativeTestWork.run { [self] in
                    try writeSkill("skills/test", name: "Test", description: "After", in: repository)
                    try commit(repository)
                }
            }
            let source = try NativeTestWork.run { [self] in try service.fetch(repo: repository, ref: nil, credential: nil) }
            let candidate = try XCTUnwrap(source.candidates.first)
            try NativeTestWork.run(container: container) { [self] jobContext in
                if updating {
                    try service.update(existingSlug: "test", candidate: candidate, from: source,
                        bodyWriteRegistration: registration, context: jobContext)
                } else {
                    _ = try service.install(candidate: candidate, from: source,
                        bodyWriteRegistration: registration, context: jobContext)
                }
            }
            let expected = "---\nname: Test\ndescription: \(updating ? "After" : "Before")\n---\nbody\n"
            XCTAssertEqual(try store.readBody(directoryName: "test"), expected)
            XCTAssertTrue(library.wasLastWrittenByApp(directoryName: "test", currentBody: expected))
            let token = library.reloadToken
            library.noteAppAuthoredBodies(directoryNames: ["test"])
            watcher.emit("test")
            XCTAssertEqual(library.reloadToken, token)
            XCTAssertFalse(library.externallyModified.contains("test"))
        }
    }
}
