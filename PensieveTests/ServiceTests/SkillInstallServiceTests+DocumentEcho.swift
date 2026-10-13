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
    }
}
