import XCTest
@testable import Pensieve

final class PreservedFrontmatterExternalChangeTests: XCTestCase {
    private final class StubWatcher: FileWatchServiceProtocol {
        var onChange: (String) -> Void = { _ in }
        func start() -> Bool { true }
        func stop() {}
        func fire(_ directoryName: String) { onChange(directoryName) }
    }

    private var tempRoot: String!
    private var fileService: FileService!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "PensievePreservedExternalTests-\(UUID().uuidString)"
        fileService = FileService()
        try fileService.createDirectory(at: tempRoot + "/preserved")
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot) {
            try FileManager.default.removeItem(atPath: tempRoot)
        }
    }

    func testExternalChangeKeepsDraftAndFingerprintBehaviorUnchanged() throws {
        let watcher = StubWatcher()
        let store = SkillStore(fileService: fileService, baseDir: tempRoot)
        let viewModel = SkillLibraryViewModel(skillStore: store, fileWatchService: watcher)
        var prompts: [(UnsavedChangesPrompt, (UnsavedChangesChoice) -> Void)] = []
        viewModel.unsavedChangesPresenter = { prompt, resolve in prompts.append((prompt, resolve)) }
        let skill = Skill(
            name: "Preserved",
            skillDescription: "Preserved description",
            directoryName: "preserved"
        )
        let frontmatter = """
        name: Preserved
        description: Preserved description
        license: MIT
        metadata:
          owner: upstream
        """
        try write(frontmatter: frontmatter, body: "A")
        viewModel.startWatching()
        XCTAssertEqual(viewModel.editorBody(for: skill), "A")
        viewModel.noteEditorChanged(skill, body: "B")

        try write(frontmatter: frontmatter, body: "C")
        watcher.fire("preserved")

        XCTAssertEqual(viewModel.readBody(skill), "C")
        XCTAssertEqual(viewModel.drafts["preserved"]?.body, "B")
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
        XCTAssertTrue(viewModel.externallyModified.contains("preserved"))
        XCTAssertEqual(prompts.map { $0.0.reason }, [.externalChange])
        XCTAssertTrue(viewModel.wasLastWrittenByApp(directoryName: "preserved", currentBody: "C"))

        prompts[0].1(.cancel)
        let reloadToken = viewModel.reloadToken
        watcher.fire("preserved")

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(viewModel.reloadToken, reloadToken)
        XCTAssertEqual(viewModel.drafts["preserved"]?.body, "B")
        XCTAssertTrue(viewModel.hasUnsavedChanges(for: skill))
    }

    private func write(frontmatter: String, body: String) throws {
        try fileService.writeFile(
            at: tempRoot + "/preserved/SKILL.md",
            content: "---\n\(frontmatter)\n---\n\n\(body)\n"
        )
    }
}
