import Darwin
import SwiftData
import XCTest
@testable import Pensieve

final class ImportWholeFileTests: XCTestCase {
    private var root: String!
    private var files: FileService!

    override func setUpWithError() throws {
        root = TestTemporaryDirectory.path + "ImportWholeFile-" + UUID().uuidString
        files = FileService()
        try files.createDirectory(at: root)
    }

    override func tearDownWithError() throws {
        try files.deleteDirectory(at: root)
    }

    @MainActor
    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: Skill.self, Project.self, SkillProjectAssignment.self, DeployRecord.self, Pensieve.Category.self, Scenario.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func scanner(files: FileServiceProtocol? = nil) -> ImportScanner {
        ImportScanner(
            fileService: files ?? self.files,
            claudeSkillsDir: root + "/claude",
            grokSkillsDir: root + "/grok",
            cursorRulesDir: root + "/cursor",
            codexSkillsDir: root + "/codex",
            storeRoot: root + "/store"
        )
    }

    @MainActor
    private func model() -> ImportViewModel {
        ImportViewModel(
            scanner: scanner(),
            skillStore: SkillStore(fileService: files, baseDir: root + "/store/skills"),
            lockPath: TestTemporaryDirectory.path + "import-lock-" + UUID().uuidString,
            manifestService: ManifestService(fileService: files), manifestRoot: root + "/store"
        )
    }

    /// Expected files are built from fixture slices, never from the production parser or normalizer.
    @MainActor
    func testGeneratedSourceShapeSweepPreservesBytesAndReportsFallbacks() throws {
        try assertImports(Self.shapes)
    }

    @MainActor
    func testBOMSourcesUseFrontmatterAndDropEncodingSignature() throws {
        try assertImports(Self.shapes.filter { $0.source.hasPrefix("\u{FEFF}") })
    }

    @MainActor
    func testBlankSourceNamesUseFolderIdentity() throws {
        try assertImports(Self.shapes.filter { $0.label.hasPrefix("blank name") })
    }

    @MainActor
    func testCraftedFrontmatterFallsBackWithoutLosingEntries() throws {
        try assertImports(Self.craftedShapes)
    }

    @MainActor
    func testDuplicateKeysCannotHideLostSourceEntries() throws {
        try assertImports(Self.duplicateShapes)
    }

    func testSourceBytesDropOnlyALeadingEncodingSignature() {
        let signature = Data([0xEF, 0xBB, 0xBF])
        let body = Data("Body".utf8)
        for (source, expected) in [
            (signature + body, body), (signature, Data()), (body, body), (Data(), Data()),
            (body + signature, body + signature), (Data([0xEF, 0xBB]), Data([0xEF, 0xBB]))
        ] {
            XCTAssertEqual(ImportScanner.sourceTextBytes(source), expected)
        }
    }

    @MainActor
    private func assertImports(_ shapes: [Shape]) throws {
        for (index, fixture) in shapes.enumerated() {
            let folder = root + "/case-\(index)"
            let source = fixture.source
            try files.writeFile(at: folder + "/SKILL.md", content: source)
            let model = model()
            let context = try context()
            XCTAssertEqual(model.scanFolder(folder), .found(1), fixture.label)
            model.importSelected(context: context)
            XCTAssertNil(model.error, fixture.label)
            let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
            let written = try files.readData(at: root + "/store/skills/\(row.directoryName)/SKILL.md")
            let sourceText = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
            let expected = fixture.expected?.replacingOccurrences(of: "{folder}", with: "case-\(index)")
                ?? "---\nname: case-\(index)\ndescription: case-\(index)\n---\n\n" + sourceText
            XCTAssertEqual(written, Data(expected.utf8), fixture.label)
            let parsed = SkillParser.parse(try XCTUnwrap(String(bytes: written, encoding: .utf8)))
            XCTAssertFalse(written.starts(with: [0xEF, 0xBB, 0xBF]), fixture.label)
            XCTAssertTrue(parsed.hasRequiredFrontmatter, fixture.label)
            XCTAssertEqual(row.name, parsed.name, fixture.label)
            if let tags = fixture.expectedTags { XCTAssertEqual(row.tags, tags, fixture.label) }
            XCTAssertEqual(row.skillDescription, parsed.description, fixture.label)
            let notices = fixture.notice ? ["\(row.name): frontmatter was kept as text."] : []
            XCTAssertEqual(model.importNotices, notices, fixture.label)
        }
    }

    @MainActor
    func testNewScansAndEarlyReturningImportsClearOldNotices() throws {
        let folder = root + "/fallback"
        try files.writeFile(at: folder + "/SKILL.md", content: "---\nlicense: MIT\n---\nBody")
        let model = model()
        let context = try context()
        for action in ["scan", "folder", "empty folder", "inside library", "empty selection", "failed fetch"] {
            XCTAssertEqual(model.scanFolder(folder), .found(1))
            model.importSelected(context: context)
            XCTAssertEqual(model.importNotices, ["fallback: frontmatter was kept as text."])
            model.error = "Previous import failed"
            switch action {
            case "scan": model.scan()
            case "folder": XCTAssertEqual(model.scanFolder(folder), .found(1))
            case "empty folder": XCTAssertEqual(model.scanFolder(root + "/missing"), .nothingFound)
            case "inside library": XCTAssertEqual(model.scanFolder(root + "/store"), .insideLibrary)
            case "empty selection":
                model.selectedSkills = []
                model.importSelected(context: context)
            default:
                model.importSelected(context: context, takenSlugs: { _ in throw CocoaError(.fileReadUnknown) })
            }
            XCTAssertTrue(model.importNotices.isEmpty, action)
            if action == "failed fetch" {
                XCTAssertTrue(model.error?.contains("couldn't read the library") == true)
            } else {
                XCTAssertNil(model.error, action)
            }
            XCTAssertEqual(model.scanFolder(folder), .found(1))
            model.error = "Previous import failed"
            model.importSelected(context: context)
            XCTAssertNil(model.error, "later clean import")
        }
    }

    @MainActor
    func testAgentAndFolderImportsKeepExtraKeysAndTagOverlay() throws {
        let source = "---\nname: 'A'\ndescription: \"D\"\nlicense: MIT\nallowed-tools: [Read, Edit]\n"
            + "# keep this comment\nmetadata:\n  author: Someone\ntags: [Swift, swift, review]\n---\n\nBody\n"
        let expected = source.replacingOccurrences(of: "name: 'A'", with: "name: A")
            .replacingOccurrences(of: "description: \"D\"", with: "description: D")
        for platform in ["claude", "grok", "codex", "folder"] {
            try files.writeFile(at: root + "/\(platform)/skill/SKILL.md", content: source)
        }
        let model = model()
        let context = try context()
        model.scan()
        XCTAssertEqual(Set(model.discoveredSkills.map(\.sourcePlatform)), ["claude-code", "grok", "codex"])
        model.importSelected(context: context)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.scanFolder(root + "/folder/skill"), .found(1))
        model.importSelected(context: context)
        XCTAssertNil(model.error)
        let rows = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertEqual(rows.count, 4)
        let manifest = try ManifestService(fileService: files).read(fromRoot: root + "/store")
        for row in rows {
            XCTAssertEqual(row.name, "A")
            XCTAssertEqual(row.skillDescription, "D")
            XCTAssertEqual(row.tags, ["Swift", "review"])
            XCTAssertEqual(manifest.skills.first { $0.slug == row.directoryName }?.tags, ["Swift", "review"])
            let bytes = try files.readData(at: root + "/store/skills/\(row.directoryName)/SKILL.md")
            XCTAssertEqual(bytes, Data(expected.utf8))
        }
    }

    @MainActor
    func testCursorRuleKeepsLegacyComposition() throws {
        try files.writeFile(
            at: root + "/cursor/rule.mdc",
            content: "---\ndescription: Cursor description\nglobs: *.swift\nalwaysApply: true\n---\n\n# Rule\n"
        )
        let model = model()
        let context = try context()
        model.scan()
        model.importSelected(context: context)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.importNotices.isEmpty)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<Skill>()).first)
        XCTAssertEqual(row.cursorConfig?.alwaysApply, true)
        let bytes = try files.readData(at: root + "/store/skills/\(row.directoryName)/SKILL.md")
        XCTAssertEqual(bytes, Data("---\nname: rule\ndescription: Cursor description\n---\n\n# Rule".utf8))
    }

    func testUnsafeLeavesAreNeverReadAndLinkedFolderIsOffered() throws {
        let collection = root + "/claude"
        for name in ["inside", "outside", "pipe"] {
            try files.createDirectory(at: collection + "/\(name)")
        }
        try files.writeFile(at: collection + "/inside/target", content: "inside sentinel")
        try files.writeFile(at: root + "/target", content: "outside sentinel")
        try files.createSymlink(at: collection + "/inside/SKILL.md", pointingTo: "target")
        try files.createSymlink(at: collection + "/outside/SKILL.md", pointingTo: root + "/target")
        let fifo = collection + "/pipe/SKILL.md"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try files.writeFile(at: root + "/real/SKILL.md", content: "Regular body")
        try files.createSymlink(at: collection + "/linked", pointingTo: root + "/real")
        let spy = ImportReadSpy(files: files)
        let scanner = scanner(files: spy)
        XCTAssertEqual(try boundedImportScan(fifo: fifo) { scanner.scan() }.map(\.name), ["linked"])
        for name in ["inside", "outside", "pipe"] {
            XCTAssertTrue(try boundedImportScan(fifo: fifo) { scanner.scanFolder(collection + "/\(name)") }.isEmpty)
        }
        XCTAssertFalse(spy.returnedBytes.contains(Data("inside sentinel".utf8)))
        XCTAssertFalse(spy.returnedBytes.contains(Data("outside sentinel".utf8)))
    }
}

private extension ImportWholeFileTests {
    struct Shape {
        let label: String
        let source: String
        let expected: String?
        let notice: Bool
        var expectedTags: [String]?
    }

    static var shapes: [Shape] {
        let blocks = [
            "name: A\n",
            "name: A\ndescription: D\n",
            "name: A\ndescription: D\nlicense: MIT\nallowed-tools: [Read]\n",
            "name: A\ndescription: D\nmetadata:\n  author: Me\n",
            "# before\nname: A\n# between\ndescription: D\n# after\n",
            "name: A\ndescription: D\ntags: [swift, swift, review]\n",
            "name: A\ndescription: ''\n"
        ]
        var shapes: [Shape] = []
        for (index, block) in blocks.enumerated() {
            for ending in ["\n", "\r\n"] {
                for body in ["", "Body", "\nBody\n"] {
                    let resolved = block.contains("description:")
                        ? block.replacingOccurrences(of: "description: ''", with: "description: A")
                        : block.replacingOccurrences(of: "name: A\n", with: "name: A\ndescription: A\n")
                    shapes.append(Shape(
                        label: "block \(index), ending \(ending.debugDescription), body \(body.debugDescription)",
                        source: ("---\n" + block + "---\n" + body).replacingOccurrences(of: "\n", with: ending),
                        expected: ("---\n" + resolved + "---\n" + body).replacingOccurrences(of: "\n", with: ending),
                        notice: false
                    ))
                }
            }
        }
        for source in [
            "---\n---\nBody", "---\nname: A\nBody",
            "---\n{name: A, description: D, license: MIT}\n---\nBody",
            "---\ndescription: D\nlicense: MIT\n---\nBody",
            "---\nname: A\n? [x]\n: y\n---\nBody", "---\n- sequence\n---\nBody"
        ] {
            // A flow mapping still supplies identity, but its complete source must become the body.
            let expected = source.contains("{name:") ? "---\nname: A\ndescription: D\n---\n\n" + source : nil
            shapes.append(Shape(label: source, source: source, expected: expected, notice: true))
        }
        for source in ["Body", "\nBody\r\n\r\n", "", "\u{FEFF}Body", "---not a fence\nBody"] {
            shapes.append(Shape(label: source, source: source, expected: nil, notice: false))
        }
        let bomFrontmatter = "---\nname: Real\ndescription: D\ntags: [x]\n---\nBody"
        shapes.append(Shape(label: "BOM preservable", source: "\u{FEFF}" + bomFrontmatter,
                            expected: bomFrontmatter, notice: false, expectedTags: ["x"]))
        shapes.append(Shape(label: "BOM unpreservable", source: "\u{FEFF}---\nlicense: MIT\n---\nBody",
                            expected: nil, notice: true))
        for name in ["", "   "] {
            shapes.append(Shape(
                label: "blank name \(name.debugDescription)",
                source: "---\nname: '\(name)'\ndescription: ''\nlicense: MIT\n---\nBody",
                expected: "---\nname: {folder}\ndescription: {folder}\nlicense: MIT\n---\nBody",
                notice: false
            ))
        }
        return shapes + craftedShapes + duplicateShapes
    }

    static var duplicateShapes: [Shape] {
        let blocks = [
            "name: A\nlicense : MIT\ndescription: D\nlicense: MIT",
            "license: MIT\nname: A\ndescription: D\nlicense : MIT",
            "name: A\ndescription: D\nlicense : MIT\nlicense: MIT"
        ]
        return blocks.map { block in
            let source = "---\n" + block + "\n---\nBody\n"
            return Shape(label: "duplicate " + block, source: source,
                         expected: nil, notice: true)
        }
    }

    static var craftedShapes: [Shape] {
        var blocks: [(String, String)] = [
            ("name: demo\ndescription : \"\"\nlicense: \"MIT\ndescription: x\n # end\"", "name: demo\ndescription: demo"),
            ("name : real\ndescription: d\nlicense: \"MIT\nname: x\"", "name: real\ndescription: d"),
            ("name: demo\nallowed-tools : Bash(*)\nlicense: \"MIT\nallowed-tools: x\n # end\"\ndescription: d",
             "name: demo\ndescription: d")
        ]
        for lineBreak in ["\r", "\u{85}", "\u{2028}"] {
            blocks.append((
                "name: demo\nlicense: MIT\(lineBreak)description: \"\"\nmetadata: \"value\ndescription: x\n # end\"",
                "name: demo\ndescription: demo"
            ))
        }
        return blocks.map { block, identity in
            let source = "---\n" + block + "\n---\nBody\n"
            return Shape(label: "crafted " + block, source: source,
                         expected: "---\n" + identity + "\n---\n\n" + source, notice: true)
        }
    }
}
