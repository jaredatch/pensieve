import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewContextTests: XCTestCase {
    func testBundlePreviewUsesDocumentFolderAndLibraryFileServiceWithinSkillRoot() async throws {
        let files = PreviewImageFileSpy()
        let base = files.files.realPath(at: TestTemporaryDirectory.path) + "/PreviewContext-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: base) }
        let root = base + "/skill"
        try files.files.writeData(at: root + "/references/diagram.png", data: PreviewImageFixture.png())
        try files.files.writeData(at: base + "/outside.png", data: PreviewImageFixture.png())
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: files, baseDir: base),
            fileService: files, fileWatchService: FileWatchService(rootDir: base), manifestRoot: base
        )
        let preview = tab(library, file: "references/guide.md")
            .preview(markdownBody: "", skillsBase: base, onSelectFile: { _ in })
        let provider = preview.imageProvider(budget: PreviewImageDecodeBudget(), colorScheme: .light)
        let loaded = await provider.loadImage(url: URL(string: "diagram.png"))
        XCTAssertEqual(try XCTUnwrap(loaded).width, 32)
        let expectedPath = URL(fileURLWithPath: root + "/references/diagram.png").standardizedFileURL.path
        XCTAssertEqual(files.reads.map(\.path), [expectedPath])
        XCTAssertEqual(files.reads.map(\.root), [root])
        let escaped = await provider.loadImage(url: URL(string: "../../outside.png"))
        XCTAssertNil(escaped)
        XCTAssertEqual(files.reads.count, 1, "Escaping paths must never reach the file service")
    }

    func testHistoryPreviewRefusesCurrentLocalImagesButLoadsEmbeddedData() async throws {
        let files = PreviewImageFileSpy()
        let base = files.files.realPath(at: TestTemporaryDirectory.path) + "/HistoryPreview-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: base) }
        try files.files.writeData(at: base + "/skills/skill/diagram.png", data: PreviewImageFixture.png())
        let skill = Skill(name: "Skill", directoryName: "skill")
        let history = SkillHistoryView(
            skill: skill,
            git: TestPaths.git,
            fileService: files,
            store: SkillStore(fileService: files, baseDir: base + "/skills"),
            workingDir: base,
            onDismiss: {}
        )
        let preview = history.preview(for: SkillHistorySelection(sha: "old", document: "Past version"))
        let provider = preview.imageProvider(budget: PreviewImageDecodeBudget(), colorScheme: .light)
        let local = await provider.loadImage(url: URL(string: "diagram.png"))
        XCTAssertNil(local)
        let absolute = await provider.loadImage(url: URL(fileURLWithPath: base + "/skills/skill/diagram.png"))
        XCTAssertNil(absolute)
        XCTAssertTrue(files.reads.isEmpty, "A historical preview cannot read today's assets")
        let data = "data:image/png;base64," + (try PreviewImageFixture.png()).base64EncodedString()
        let embedded = await provider.loadImage(url: URL(string: data))
        XCTAssertEqual(try XCTUnwrap(embedded).width, 32)
    }

    func testWatcherEventReloadsMountedLocalImagesWithoutReselectingSkill() async throws {
        let files = PreviewImageFileSpy()
        let base = files.files.realPath(at: TestTemporaryDirectory.path) + "/ImageRefresh-" + UUID().uuidString
        defer { try? files.files.deleteDirectory(at: base) }
        let store = SkillStore(fileService: files, baseDir: base)
        let slug = try store.createSkill(name: "Skill", description: "D", body: "Body")
        XCTAssertEqual(slug, "skill")
        let imagePath = base + "/skill/diagram.png"
        try files.files.writeData(at: imagePath, data: PreviewImageFixture.png())
        let watcher = RecordingWatcher()
        let library = SkillLibraryViewModel(skillStore: store, fileService: files, fileWatchService: watcher, manifestRoot: base)
        let skill = Skill(name: "Skill", directoryName: "skill")
        _ = library.editorBody(for: skill)
        library.startWatching()
        let host = NSHostingView(rootView: RefreshHarness(library: library, skill: skill, base: base))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        await TestWait.until(failureMessage: "Mounted block and inline images must load") { files.finishedReads == 2 }
        let before = files.bytesRead
        let token = library.reloadToken
        let changed = try croppedPNG()
        try files.files.writeData(at: imagePath, data: changed)
        watcher.emit(slug)
        await TestWait.until(failureMessage: "The same mounted preview must reload both changed local images") {
            files.finishedReads == 4
        }
        XCTAssertEqual(files.bytesRead - before, changed.count * 2)
        let preview = tab(library, file: "SKILL.md").preview(markdownBody: "", skillsBase: base, onSelectFile: { _ in })
        let provider = preview.imageProvider(budget: PreviewImageDecodeBudget(), colorScheme: .light)
        let decoded = await provider.loadImage(url: URL(string: "diagram.png"))
        XCTAssertEqual(try XCTUnwrap(decoded).width, 16)
        XCTAssertEqual(try XCTUnwrap(decoded).height, 12)
        XCTAssertEqual(library.reloadToken, token, "An asset change is an echo for SKILL.md")
    }

    private func croppedPNG() throws -> Data {
        let image = try XCTUnwrap(try PreviewImageFixture.decodedPNG().cropping(to: CGRect(x: 0, y: 0, width: 16, height: 12)))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func tab(_ library: SkillLibraryViewModel, file: String) -> SkillContentTab {
        let choice = SkillContentPresentation.FileChoice(relativePath: file)
        return SkillContentTab(skill: Skill(name: "Skill", directoryName: "skill"), snapshot: DetailContentSnapshot(),
                               library: library, presentation: .init(choices: [choice], choice: choice, shownMode: .rendered),
                               onSelectFile: { _ in }, onSelectMode: { _ in })
    }
}

private struct RefreshHarness: View {
    @Bindable var library: SkillLibraryViewModel
    let skill: Skill
    let base: String

    var body: some View {
        let choice = SkillContentPresentation.FileChoice(relativePath: "SKILL.md")
        let tab = SkillContentTab(skill: skill, snapshot: DetailContentSnapshot(),
                                  library: library, presentation: .init(choices: [choice], choice: choice, shownMode: .rendered),
                                  onSelectFile: { _ in }, onSelectMode: { _ in })
        tab.preview(markdownBody: "![Block](diagram.png)\n\nText ![Inline](diagram.png) neighbor.",
                    skillsBase: base, onSelectFile: { _ in })
    }
}
