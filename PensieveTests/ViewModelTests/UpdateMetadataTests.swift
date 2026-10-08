import SwiftData
import XCTest
@testable import Pensieve

final class UpdateMetadataTests: XCTestCase {
    private struct Fixture {
        let library: SkillLibraryViewModel
        let context: ModelContext
        let skill: Skill
    }

    private var tempDir: String!
    private var fileService: FileService!
    private var manifest: ManifestService!

    override func setUpWithError() throws {
        tempDir = TestTemporaryDirectory.path + "PensieveUpdateMetadata-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fileService = FileService()
        manifest = ManifestService(fileService: fileService)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir) {
            try FileManager.default.removeItem(atPath: tempDir)
        }
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, Pensieve.Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @MainActor
    private func makeLibrary(notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) throws
        -> Fixture {
        let context = try makeContext()
        let store = SkillStore(fileService: fileService, baseDir: tempDir + "/skills")
        let library = SkillLibraryViewModel(
            skillStore: store, fileWatchService: FileWatchService(rootDir: TestPaths.skillsDir),
            manifestService: manifest, manifestRoot: tempDir,
            notifier: notifier
        )
        library.createSkill(name: "Editable", description: "d", body: "# b", tags: [], context: context)
        let skill = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        return Fixture(library: library, context: context, skill: skill)
    }

    @MainActor
    func testUpdateMetadataWritesTagsToOverlayAndNotSkillFile() throws {
        let fixture = try makeLibrary()
        let skillPath = tempDir + "/skills/\(fixture.skill.directoryName)/SKILL.md"
        let bytesBefore = try fileService.readData(at: skillPath)
        let updatedAtBefore = fixture.skill.updatedAt

        fixture.library.updateMetadata(fixture.skill, tags: ["a", "b"], scope: .user, context: fixture.context)

        let overlay = try XCTUnwrap(
            try manifest.read(fromRoot: tempDir).skills.first { $0.slug == fixture.skill.directoryName }
        )
        XCTAssertEqual(overlay.tags, ["a", "b"])
        XCTAssertEqual(try fileService.readData(at: skillPath), bytesBefore)
        XCTAssertGreaterThan(fixture.skill.updatedAt, updatedAtBefore)
    }

    @MainActor
    func testUpdateMetadataNotifies() throws {
        var notificationCount = 0
        let fixture = try makeLibrary { notificationCount += 1 }
        notificationCount = 0

        fixture.library.updateMetadata(fixture.skill, tags: ["a"], scope: .user, context: fixture.context)

        XCTAssertEqual(notificationCount, 1)
    }

    @MainActor
    func testUpdateMetadataClearsErrorOnSuccess() throws {
        let fixture = try makeLibrary()
        fixture.library.error = "previous error"

        fixture.library.updateMetadata(fixture.skill, tags: ["a"], scope: .user, context: fixture.context)

        XCTAssertNil(fixture.library.error)
    }

    @MainActor
    func testUpdateMetadataRefusesASkillWhoseDeletionWasSaved() throws {
        var notificationCount = 0
        let fixture = try makeLibrary { notificationCount += 1 }
        fixture.context.delete(fixture.skill)
        try fixture.context.save()
        notificationCount = 0
        let overlaysBefore = try manifest.read(fromRoot: tempDir).skills

        fixture.library.updateMetadata(fixture.skill, tags: ["late"], scope: .user, context: fixture.context)

        XCTAssertEqual(try manifest.read(fromRoot: tempDir).skills, overlaysBefore)   // no regenerate
        XCTAssertEqual(notificationCount, 0)                                          // no nudge
        XCTAssertNil(fixture.library.error)
    }
}
