import XCTest
@testable import Pensieve

/// The library's two bundle reads in their static forms (PLAN-34 / 34.1), over the real `FileService` in a
/// temp skills base: the file read and the four refusals — a traversal, a dot component, a symlink, a
/// non-UTF-8 file.
final class SkillLibraryBundleReadTests: XCTestCase {
    private var base = ""
    private let slug = "bundle-skill"
    private let fileService = FileService()

    override func setUpWithError() throws {
        base = TestTemporaryDirectory.path + "SkillLibraryBundleReadTests-" + UUID().uuidString
        try fileService.createDirectory(at: base + "/" + slug + "/references")
        try fileService.writeFile(at: base + "/" + slug + "/SKILL.md", content: "---\nname: Bundle\ndescription: d\n---\n\nBody")
        try fileService.writeFile(at: base + "/" + slug + "/references/voice.md", content: "Voice notes")
        try fileService.writeFile(at: base + "/outside.md", content: "outside the skill")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    func testBundleFileTextReadsARegularTextFile() {
        let library = SkillLibraryViewModel(skillStore: SkillStore(fileService: fileService, baseDir: base, storeRoot: base),
            fileService: fileService, fileWatchService: FileWatchService(rootDir: base), manifestRoot: base + "/manifest-store")
        let skill = Skill(name: "Bundle", directoryName: slug)
        XCTAssertEqual(library.bundleFileText(skill, relativePath: "references/voice.md"), "Voice notes")
        XCTAssertEqual(library.bundleInventory(skill).files.map(\.relativePath), ["SKILL.md", "references/voice.md"])
        XCTAssertEqual(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: "references/voice.md",
                                                             base: base, fileService: fileService), "Voice notes")
        XCTAssertEqual(SkillLibraryViewModel.bundleInventory(slug: slug, base: base, fileService: fileService)
                           .files.map(\.relativePath), ["SKILL.md", "references/voice.md"])
    }

    func testAMissingSkillDirectoryReadsAsEmpty() {
        XCTAssertEqual(SkillLibraryViewModel.bundleInventory(slug: "gone", base: base, fileService: fileService), .empty)
    }

    func testBundleFileTextRefusesATraversalComponent() {
        XCTAssertNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: "../outside.md",
                                                          base: base, fileService: fileService))
        XCTAssertNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: "references/../../outside.md",
                                                          base: base, fileService: fileService))
    }

    func testBundleFileTextRefusesADotComponent() throws {
        try fileService.createDirectory(at: base + "/" + slug + "/.hidden")
        try fileService.writeFile(at: base + "/" + slug + "/.hidden/x.md", content: "hidden")

        XCTAssertNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: ".hidden/x.md",
                                                          base: base, fileService: fileService))
    }

    func testBundleFileTextRefusesASymlinkedComponent() throws {
        try fileService.createSymlink(at: base + "/" + slug + "/link.md", pointingTo: base + "/outside.md")
        try fileService.createSymlink(at: base + "/" + slug + "/linked", pointingTo: base)

        XCTAssertNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: "link.md",
                                                          base: base, fileService: fileService))
        XCTAssertNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: "linked/outside.md",
                                                          base: base, fileService: fileService))
    }

    func testBundleFileTextRefusesANonUTF8File() throws {
        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: base + "/" + slug + "/logo.bin"))

        XCTAssertNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: "logo.bin",
                                                          base: base, fileService: fileService))
        XCTAssertNil(SkillLibraryViewModel.bundleInventory(slug: slug, base: base, fileService: fileService)
                         .files.first { $0.relativePath == "logo.bin" }?.tokens)
    }

    func testEveryTextFileTheInventoryListsReads() throws {
        try fileService.writeFile(at: base + "/" + slug + "/references/voice notes.md", content: "Spaced notes")
        try fileService.writeFile(at: base + "/" + slug + "/a\\b.md", content: "backslash")
        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: base + "/" + slug + "/logo.bin"))

        let inventory = SkillLibraryViewModel.bundleInventory(slug: slug, base: base, fileService: fileService)

        XCTAssertEqual(inventory.files.map(\.relativePath),
                       ["SKILL.md", "logo.bin", "references/voice notes.md", "references/voice.md"])
        XCTAssertEqual(inventory.textFiles.map(\.relativePath),
                       ["SKILL.md", "references/voice notes.md", "references/voice.md"])
        for file in inventory.textFiles {
            XCTAssertNotNil(SkillLibraryViewModel.bundleFileText(slug: slug, relativePath: file.relativePath,
                                                                 base: base, fileService: fileService))
        }
    }
}
