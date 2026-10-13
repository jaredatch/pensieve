import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewFrontmatterTests: XCTestCase {
    func testRenderedTableKeepsFileOrderBlockLinesAndNestedYAMLAboveBody() async throws {
        let longLine = Array(repeating: "Long description text that wraps.", count: 12).joined(separator: " ")
        let description = "First line.\n" + longLine
        let document = orderedDocument(longLine)
        var paintedRows: [SkillFrontmatterRow]?
        for (ending, chomp) in [("\n", "|-"), ("\r\n", "|-"), ("\n", "|"), ("\r\n", "|+")] {
            let source = document.replacingOccurrences(of: "CHOMP", with: chomp)
            let fixture = try host("\u{feff}" + source.replacingOccurrences(of: "\n", with: ending))
            defer { fixture.close() }
            let expected: [(String, String)] = [
                ("license", "MIT"), ("name", "Example"), ("description", description),
                ("metadata", "version: \"3.1.0\"\nenabled: true\n# Keep this nested note."),
                ("tools", "- Read\n- Bash(git:*)"),
                ("flow", "{one: [1, 2], two: \"value\"}"),
                ("tagged", "!tag\nversion: 1\n# Keep the nested comment."),
                ("flow-control", "[one, two]"), ("count", "42")
            ]
            XCTAssertEqual(fixture.snapshot.frontmatterRows.map(\.value), expected.map(\.1))
            let previousY = try await assertRows(expected, in: fixture.host)
            if let paintedRows { XCTAssertEqual(fixture.snapshot.frontmatterRows, paintedRows) }
            paintedRows = fixture.snapshot.frontmatterRows
            let descriptionFrame = try await text(description, in: fixture.host).accessibilityFrame()
            XCTAssertGreaterThan(descriptionFrame.height, 100, "Long values wrap in full")
            let body = try await text("Body heading", in: fixture.host)
            XCTAssertLessThan(body.accessibilityFrame().maxY, previousY, "The Markdown body follows the table")
            let scalar = try await text("MIT", in: fixture.host)
            let collection = try await text(expected[3].1, in: fixture.host)
            XCTAssertEqual(try fontSize(of: scalar), 13, accuracy: 0.01)
            XCTAssertEqual(try fontSize(of: collection), 11, accuracy: 0.01)
        }
        try assertGridPaint(XCTUnwrap(paintedRows))
    }

    func testReadableMappingWithoutRequiredStringIdentityStillShowsItsEntries() async throws {
        for header in ["license: MIT", "name: 42\nlicense: MIT"] {
            let fixture = try host("---\n\(header)\n---\n\nBody text.")
            defer { fixture.close() }
            _ = try await text("license", in: fixture.host)
            _ = try await text("MIT", in: fixture.host)
            _ = try await text("Body text.", in: fixture.host)
        }
    }

    func testFrontmatterMarkdownLinksAndImagesAreLiteralAndLoadNothing() async throws {
        let literal = "**bold** [link](https://example.com) ![local](diagram.png) ![web](https://example.com/image.png)"
        let fixture = try host("---\nname: Example\ndescription: '\(literal)'\n---\n\nBody text.")
        defer { fixture.close() }
        _ = try await text(literal, in: fixture.host)
        _ = try await text("Body text.", in: fixture.host)
        let links = elements(in: fixture.host).filter { $0.accessibilityRole() == .link }
        XCTAssertTrue(links.isEmpty, "Frontmatter references must not become clickable links")
        XCTAssertTrue(fixture.files.reads.isEmpty, "Frontmatter images must not read assets")
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        // The same mounted Content preview must still load a real body image through the spy.
        fixture.selection.file = "reference.md"
        await TestWait.until(failureMessage: "Body image must exercise the real image provider") {
            fixture.host.layoutSubtreeIfNeeded()
            return fixture.files.finishedReads == 1 && !self.elements(in: fixture.host).contains {
                ($0.accessibilityValue() as? String) == literal
            }
        }
        XCTAssertEqual(fixture.files.reads.count, 1)
        XCTAssertTrue(fixture.files.reads[0].path.hasSuffix("/diagram.png"))
        XCTAssertFalse(elements(in: fixture.host).contains { ($0.accessibilityValue() as? String) == literal },
                       "Other bundle files must not inherit SKILL.md's table")
    }

    func testFrontmatterMarksInvisibleScalarsInKeysAndValues() async throws {
        let fixture = try host("""
        ---
        name: Example
        description: "before\\u200B\\u202E\\u0007\\u000D\\u200D\\uFE0Fafter\\r\\n\\u2028\\u2029"
        hidden\u{200b}key: literal ⟨U+200B⟩
        \(terminalBreakFields)
        ---
        Body text.
        """)
        defer { fixture.close() }
        let expected: [(String, String)] = [
            ("Final line", "Final line"),
            ("Final line\r", "Final line␍"),
            ("Final line\r", "Final line␍"),
            ("Final line\u{000b}", "Final line⟨U+000B⟩"),
            ("Final line\u{000c}", "Final line⟨U+000C⟩"),
            ("Final line\u{0085}", "Final line⟨U+0085⟩"),
            ("Final line\u{2028}", "Final line⟨U+2028⟩"),
            ("Final line\u{2029}", "Final line⟨U+2029⟩"),
            ("Final line\r\n\u{2028}\u{2029}", "Final line␍\n⟨U+2028⟩⟨U+2029⟩"),
            ("Final line", "Final line")
        ]
        XCTAssertEqual(fixture.snapshot.frontmatterRows.dropFirst(3).map(\.value),
                       expected.map(\.0), "Only terminal LF scalars are trimmed; marked characters and internal breaks stay")
        for (index, entry) in expected.enumerated() {
            let keyFrame = try await text("terminal\(index)", in: fixture.host).accessibilityFrame()
            let ownCells = elements(in: fixture.host).filter {
                ($0.accessibilityValue() as? String) == entry.1 && $0.accessibilityFrame().width > 0
                    && abs($0.accessibilityFrame().maxY - keyFrame.maxY) < 0.5
                    && $0.accessibilityFrame().minX > keyFrame.minX
            }
            XCTAssertEqual(ownCells.count, 1, "terminal\(index) must draw its own marked value")
        }
        _ = try await text("before⟨U+200B⟩⟨U+202E⟩⟨U+0007⟩␍⟨U+200D⟩⟨U+FE0F⟩after␍\n⟨U+2028⟩⟨U+2029⟩", in: fixture.host)
        _ = try await text("hidden⟨U+200B⟩key", in: fixture.host)
        _ = try await text("literal ⟨U+200B⟩", in: fixture.host)
    }

    func testUnreadableUntrustedAndAbsentFrontmatterKeepTheExistingBodyWithoutATable() async throws {
        let headers = [
            "description: [broken", "? [non, scalar]\n: value", "{name: Example, description: flow}",
            "name: Example\ndescription: before---after", "name: Example\ndescription: &x anchored\nother: *x",
            "name: Example\nname: Duplicate\ndescription: D", "name: Example\ndescription:\tTabbed",
            "name: Example\ndescription: line\u{2028}break"
        ]
        let body = "# Body heading\n\nBody text."
        let indented = " ---\nname: Example\n---\n\n\(body)"
        let unclosed = "---\nname: Example\n\n\(body)"
        let documents = headers.map { ("---\n\($0)\n---\n\n\(body)", body) }
            + [(body, body), (indented, indented), (unclosed, unclosed), ("---\n---\n\n\(body)", body)]
        for (document, expectedBody) in documents {
            let fixture = try host(document)
            defer { fixture.close() }
            _ = try await text("Body heading", in: fixture.host)
            _ = try await text("Body text.", in: fixture.host)
            XCTAssertTrue(fixture.snapshot.frontmatterRows.isEmpty, document)
            XCTAssertEqual(fixture.snapshot.body, expectedBody, document)
            XCTAssertFalse(elements(in: fixture.host).contains { ($0.accessibilityValue() as? String) == "name" }, document)
        }
    }

    private func orderedDocument(_ longLine: String) -> String {
        """
        ---
        license: MIT
        name: Example
        description: CHOMP
          First line.
          \(longLine)
        metadata:
          version: "3.1.0"
          enabled: true
          # Keep this nested note.
        # Notes for the following entry.
        tools:
          - Read
          - Bash(git:*)
        # deploy notes
        flow: {one: [1, 2], two: "value"}
          # Trailing indented flow comment.

        # Notes after the inline value.
        tagged: !tag
          version: 1
          # Keep the nested comment.
         # Lower-indent note after the block.
        flow-control: [one, two]
          # Trailing flow note.

        count: 42
        ---
        # Body heading

        Body remains Markdown.
        """
    }

    func host(_ document: String) throws -> FrontmatterHost {
        try FrontmatterHost(document: document)
    }

    private var terminalBreakFields: String {
        ["\\n", "\\r", "\\r\\n", "\\v", "\\f", "\\N", "\\L", "\\P", "\\r\\n\\L\\P", "\\n\\n"]
            .enumerated().map { "terminal\($0.offset): \"Final line\($0.element)\"" }.joined(separator: "\n")
    }

    private func assertGridPaint(_ rows: [SkillFrontmatterRow]) throws {
        let renderer = ImageRenderer(content: SkillFrontmatterTable(rows: rows)
            .frame(width: 612).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "Production table must render offscreen")
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func luminance(_ x: Int, _ y: Int) -> CGFloat {
            let offset = y * context.bytesPerRow + x * 4
            return CGFloat(Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 765
        }
        XCTAssertGreaterThan(width, 100)
        XCTAssertGreaterThan(height, 50)
        // A blank capture must fail before any comparisons of borders or fills.
        let ink = (12..<min(width / 3, 200)).flatMap { x in (4..<height - 4).map { luminance(x, $0) } }
        XCTAssertLessThan(ink.min() ?? 1, 0.2, "Capture must include visible key text")
        XCTAssertGreaterThan(ink.max() ?? 0, 0.8, "Capture must include the light table background")
        let candidates = (12..<width / 3).map { x in
            (x, (4..<height - 4).filter { y in
                luminance(x, y) + 0.02 < min(luminance(x - 4, y), luminance(x + 4, y))
            }.count)
        }
        let divider = try XCTUnwrap(candidates.max { $0.1 < $1.1 })
        XCTAssertGreaterThan(divider.1, height - 8 - rows.count * 4,
                             "One straight divider must span the rows, apart from horizontal rule intersections")
        // Blank padding gutters must have the same row fill and bottom rule on both sides of the divider.
        let gaps = (4..<height - 4).filter { y in
            let left = luminance(6, y), middle = luminance(divider.0 - 6, y), right = luminance(width - 6, y)
            return max(left, middle, right) - min(left, middle, right) > 0.01
        }
        XCTAssertTrue(gaps.isEmpty, "Both cells' fills and bottom rules must span the full row height: \(gaps.count) gaps")
    }

    private func assertRows(_ rows: [(String, String)], in host: NSView) async throws -> CGFloat {
        var previousY = CGFloat.infinity
        var valueX: CGFloat?
        for (key, value) in rows {
            let keyFrame = try await text(key, in: host).accessibilityFrame()
            let element = try await text(value, in: host)
            let valueFrame = element.accessibilityFrame()
            XCTAssertEqual(element.accessibilityValue() as? String, value, "Values end at their last text line")
            XCTAssertLessThan(keyFrame.maxY, previousY, "Rows must follow file order")
            XCTAssertGreaterThan(valueFrame.minX, keyFrame.minX)
            if let valueX { XCTAssertEqual(valueFrame.minX, valueX, accuracy: 0.5) }
            valueX = valueFrame.minX
            previousY = keyFrame.minY
        }
        return previousY
    }

    func text(_ value: String, in host: NSView) async throws -> NSAccessibilityProtocol {
        var found: NSAccessibilityProtocol?
        await TestWait.until(timeout: .seconds(TestWait.hostedActionTimeoutSeconds),
                             failureMessage: "Rendered literal text must appear: \(value)") {
            host.layoutSubtreeIfNeeded()
            found = self.elements(in: host).first {
                guard let actual = $0.accessibilityValue() as? String else { return false }
                return actual == value && $0.accessibilityFrame().width > 0
            }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func fontSize(of element: NSAccessibilityProtocol) throws -> CGFloat {
        let attributed = try XCTUnwrap(element.accessibilityAttributedString(for: NSRange(location: 0, length: 1)))
        let font = try XCTUnwrap(attributed.attribute(NSAttributedString.Key("AXFont"), at: 0,
                                                     effectiveRange: nil) as? [String: Any])
        return CGFloat(try XCTUnwrap(font["AXFontSize"] as? NSNumber).doubleValue)
    }

    private func elements(in root: NSView) -> [NSAccessibilityProtocol] {
        var pending: [Any] = [root] + NSAccessibility.unignoredChildrenForOnlyChild(from: root)
        var visited: Set<ObjectIdentifier> = []
        var result: [NSAccessibilityProtocol] = []
        while let candidate = pending.popLast() {
            guard let object = candidate as? NSObject, visited.insert(ObjectIdentifier(object)).inserted,
                  let element = candidate as? NSAccessibilityProtocol else { continue }
            result.append(element)
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            if let view = candidate as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }
}

extension SkillPreviewFrontmatterTests {
    func testRenderedTableAdmitsLiteralPunctuationAndRefusesYAMLAnchors() async throws {
        for syntax in FrontmatterRewriteFixture.syntaxCases {
            let fixture = try host(syntax.document(name: "Example"))
            defer { fixture.close() }
            _ = try await text("Original body", in: fixture.host)
            if syntax.trusted {
                _ = try await text("description", in: fixture.host)
                _ = try await text("Use for *.md files", in: fixture.host)
                if syntax.label == "plain star" {
                    _ = try await text("allowed-tools", in: fixture.host)
                    _ = try await text("Bash(npm run *)", in: fixture.host)
                }
            } else {
                XCTAssertTrue(fixture.snapshot.frontmatterRows.isEmpty, syntax.label)
                XCTAssertFalse(elements(in: fixture.host).contains {
                    ($0.accessibilityValue() as? String) == "description"
                }, syntax.label)
            }
        }
    }
}

@MainActor final class FrontmatterHost {
    let files = PreviewImageFileSpy()
    let selection = PreviewFileSelection()
    let snapshot: DetailContentSnapshot
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let root: String
    var openedURLs: [URL] = []

    init(document: String) throws {
        root = TestTemporaryDirectory.path + "Frontmatter-" + UUID().uuidString
        try files.files.writeFile(at: root + "/skills/example/SKILL.md", content: document)
        try files.files.writeFile(at: root + "/skills/example/reference.md", content: "![Body image](diagram.png)")
        try files.files.writeData(at: root + "/skills/example/diagram.png", data: PreviewImageFixture.png())
        let library = SkillLibraryViewModel(
            skillStore: SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root),
            fileService: files, fileWatchService: RecordingWatcher(), manifestRoot: root)
        let skill = Skill(name: "Example", directoryName: "example")
        let platform = PlatformViewModel(fileService: files, linkService: TestPaths.linkService(fileService: files),
                                         cursorCompiler: TestPaths.cursorCompiler(fileService: files),
                                         agentDetection: NoFrontmatterAgents(), deployStateStore: .memoryBacked,
                                         skillsDirectory: root + "/skills")
        snapshot = DetailContentSnapshot.load(skill: skill, projects: [], library: library, platformVM: platform)
        host = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 644, height: 1200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        host.rootView = AnyView(PreviewContentHarness(skill: skill, snapshot: snapshot, library: library,
                                                      selection: selection, chromeHeight: 1,
                                                      onSelectFile: { [selection] in selection.file = $0 })
            .environment(\.openURL, OpenURLAction { [weak self] url in self?.openedURLs.append(url); return .handled }))
        window.contentView = host
        window.orderFront(nil)
    }

    func close() {
        window.close()
        window.contentView = nil
        host.rootView = AnyView(EmptyView())
        try? files.files.deleteDirectory(at: root)
    }
}

private struct NoFrontmatterAgents: AgentDetectionServiceProtocol {
    func installedPlatforms() -> [PlatformTarget] { [] }
    func isInstalled(_ platform: PlatformTarget) -> Bool { false }
}
