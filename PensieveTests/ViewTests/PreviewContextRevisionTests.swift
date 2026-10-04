import XCTest
@testable import Pensieve

@MainActor
final class PreviewContextRevisionTests: XCTestCase {
    func testExistingAndMissingRelativeImagesReachContainedReadUnderPrivateAliasedRoot() async throws {
        let files = PreviewImageFileSpy()
        let root = files.files.realPath(at: NSTemporaryDirectory()) + "/AliasedImages-" + UUID().uuidString + "/skill"
        defer { try? files.files.deleteDirectory(at: URL(fileURLWithPath: root).deletingLastPathComponent().path) }
        try files.files.writeData(at: root + "/existing.png", data: PreviewImageFixture.png())
        XCTAssertTrue(root.hasPrefix("/private/"), "Exercise macOS's aliased temporary root")
        let standardized = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        XCTAssertNotEqual(root, standardized, "Both spellings must be exercised")
        let loader = PreviewImageLoader(fileService: files)
        XCTAssertEqual(try loader.loadImage(at: URL(string: "existing.png")!, skillDirectory: root).width, 32)
        XCTAssertThrowsError(try loader.loadImage(at: URL(string: "missing.png")!, skillDirectory: root))
        XCTAssertEqual(files.reads.map(\.path), [standardized + "/existing.png", standardized + "/missing.png"],
                       "Existence must not decide whether a contained relative leaf reaches the reader")
        XCTAssertEqual(files.reads.map(\.root), [root, root])
        let provider = PreviewImageProvider(loader: loader, skillDirectory: root, budget: PreviewImageDecodeBudget())
        let existing = await provider.loadImage(url: URL(string: "existing.png"))
        XCTAssertEqual(try XCTUnwrap(existing).width, 32)
        let missing = await provider.loadImage(url: URL(string: "missing.png"))
        XCTAssertNil(missing)
        XCTAssertEqual(files.reads.map(\.path), [standardized + "/existing.png", standardized + "/missing.png",
                                               standardized + "/existing.png", standardized + "/missing.png"],
                       "Provider and direct loader must share the standardized resolution base")
        XCTAssertEqual(files.reads.map(\.root), [root, root, root, root])
    }

    func testPreviewRevisionIgnoresOtherSkillsAndSyncButTracksItsOwnFolder() throws {
        let files = FileService()
        let base = NSTemporaryDirectory() + "ScopedImages-" + UUID().uuidString
        defer { try? files.deleteDirectory(at: base) }
        let store = SkillStore(fileService: files, baseDir: base)
        let slug = try store.createSkill(name: "Skill", description: "D", body: "Body")
        let other = try store.createSkill(name: "Other", description: "D", body: "Other body")
        let watcher = RecordingWatcher()
        let library = SkillLibraryViewModel(skillStore: store, fileWatchService: watcher)
        let skill = Skill(name: "Skill", directoryName: slug)
        _ = library.editorBody(for: skill)
        library.startWatching()
        let original = preview(library, skill: skill, base: base).imageRevision
        watcher.emit(other)
        XCTAssertEqual(preview(library, skill: skill, base: base).imageRevision, original,
                       "An event in another skill must keep the open preview's identity")
        library.beginCoordinatorChanges()
        library.finishCoordinatorChanges(hasUnsyncedChanges: false)
        XCTAssertEqual(preview(library, skill: skill, base: base).imageRevision, original,
                       "A sync cycle must keep the open preview's identity")
        watcher.emit(slug)
        XCTAssertEqual(preview(library, skill: skill, base: base).imageRevision, original + 1)
    }

    func testRelativeImageResolutionHasOneRuleAndSkillDirectoryHasOneName() throws {
        let loader = try sourceFile("Pensieve/Services/PreviewImageLoader.swift")
        let provider = try sourceFile("Pensieve/Views/SkillViews/PreviewImageProvider.swift")
        XCTAssertEqual((loader + provider).components(separatedBy: "relativeTo:").count - 1, 1,
                       "Document-relative image resolution must have one implementation")
        XCTAssertFalse(loader.contains("static func skillDirectory("), "Use the store's one skill-directory name")
        let store = try sourceFile("Pensieve/Services/SkillStore.swift")
        let helper = try XCTUnwrap(store.range(of: "static func skillDirectoryPath("))
        let privateMark = try XCTUnwrap(store.range(of: "// MARK: - Private"))
        XCTAssertLessThan(helper.lowerBound, privateMark.lowerBound, "The shared path helper belongs above Private")
    }

    private func preview(_ library: SkillLibraryViewModel, skill: Skill, base: String) -> SkillPreviewView {
        let choice = SkillContentPresentation.FileChoice(relativePath: "SKILL.md")
        let tab = SkillContentTab(skill: skill, snapshot: DetailContentSnapshot(), library: library,
                                  presentation: .init(choices: [choice], choice: choice, shownMode: .rendered),
                                  onSelectFile: { _ in }, onSelectMode: { _ in })
        return tab.preview(markdownBody: "Body", skillsBase: base)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try FileService().readFile(at: root.appendingPathComponent(relativePath).path)
    }
}
