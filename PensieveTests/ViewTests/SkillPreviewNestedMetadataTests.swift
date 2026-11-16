import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

@MainActor
final class SkillPreviewNestedMetadataTests: XCTestCase {
    func testNestedMappingShowsKeysOverValuesInFileOrder() async throws {
        let fixture = try await mount("""
        metadata:
          tags: "ADHD, Output Style, Productivity, Formatting"
          category: "productivity"
        ordered: {zebra: Z, alpha: A, mike: M, bravo: B, echo: E}
        alike: {1: numeric, "1": quoted}
        empty: {missing: , present: here}
        """)
        defer { fixture.close() }
        try assertMapping(["tags", "category"], ["ADHD, Output Style, Productivity, Formatting", "productivity"], in: fixture)
        try assertMapping(["zebra", "alpha", "mike", "bravo", "echo"], ["Z", "A", "M", "B", "E"], in: fixture)
        let alike = cells("1", in: fixture)
        XCTAssertEqual(alike.count, 2)
        let numeric = try cell("numeric", in: fixture), quoted = try cell("quoted", in: fixture)
        for (key, value) in zip(alike, [numeric, quoted]) {
            XCTAssertEqual(key.minX, value.minX, accuracy: 0.5)
            XCTAssertGreaterThan(key.minY, value.maxY)
        }
        let missing = try cell("missing", in: fixture), present = try cell("present", in: fixture)
        let here = try cell("here", in: fixture)
        XCTAssertLessThan(missing.minX, present.minX)
        XCTAssertEqual(present.minX, here.minX, accuracy: 0.5)
        XCTAssertEqual(missing.maxY, present.maxY, accuracy: 0.5)
        XCTAssertLessThan(try cell("Body text.", in: fixture).maxY, here.minY)
        assertNoCombinedYAML(in: fixture)
    }

    func testListsAndDeeperNestingShowACellPerValue() async throws {
        let fixture = try await mount("""
        block:
          - Read
          - Bash(git:*)
        flowlist: [left, middle, right]
        repeated: [again, again]
        empty:
          - before
          -
          - after
        neighbors: [near, next]
        flow: {one: [1, 2], two: "value"}
        records: [{first: alpha}, {second: beta}]
        """)
        defer { fixture.close() }
        try assertLine(["Read", "Bash(git:*)"], in: fixture)
        try assertLine(["left", "middle", "right"], in: fixture)
        let repeated = cells("again", in: fixture)
        XCTAssertEqual(repeated.count, 2)
        if repeated.count == 2 {
            XCTAssertLessThan(repeated[0].maxX, repeated[1].minX)
            XCTAssertEqual(repeated[0].maxY, repeated[1].maxY, accuracy: 0.5)
        }
        try assertLine(["before", "after"], in: fixture)
        let emptyGap = try cell("after", in: fixture).minX - cell("before", in: fixture).minX
        let neighborGap = try cell("next", in: fixture).minX - cell("near", in: fixture).minX
        XCTAssertGreaterThan(emptyGap, neighborGap * 1.5, "The empty item retains its column")
        try assertMapping(["one", "two"], ["1", "value"], in: fixture, sameValueLine: false)
        try assertLine(["1", "2"], in: fixture)
        XCTAssertGreaterThan(try cell("one", in: fixture).minY, try cell("2", in: fixture).maxY)
        try assertMapping(["first", "second"], ["alpha", "beta"], in: fixture)
        for key in ["block", "flowlist", "repeated"] {
            let frame = try cell(key, in: fixture)
            let item = try cell(key == "block" ? "Read" : key == "flowlist" ? "left" : "again", in: fixture)
            XCTAssertLessThan(abs(frame.maxY - item.maxY), 12, "Lists have no header row")
        }
        assertNoCombinedYAML(in: fixture)
    }

    func testNestedCellsStayLiteralWithInvisibleCharactersMarked() async throws {
        let literal = "**bold** [link](https://example.com) ![local](diagram.png) ![web](https://example.com/image.png)"
        let fixture = try await mount("""
        metadata:
          "hidden\\u200Bkey": "before\\u202Eafter"
          literal: '\(literal)'
          lines: "first\\nsecond\\n\\n"
        """)
        defer { fixture.close() }
        try assertMapping(["hidden⟨U+200B⟩key", "literal", "lines"],
                          ["before⟨U+202E⟩after", literal, "first\nsecond"], in: fixture)
        let marked = try XCTUnwrap(elements(in: fixture.host).first {
            ($0.accessibilityValue() as? String) == "before⟨U+202E⟩after"
        })
        let attributes = try XCTUnwrap(marked.accessibilityAttributedString(for: NSRange(location: 0, length: 1)))
        let font = try XCTUnwrap(attributes.attribute(NSAttributedString.Key("AXFont"), at: 0,
                                                    effectiveRange: nil) as? [String: Any])
        XCTAssertEqual((font["AXFontSize"] as? NSNumber)?.doubleValue, 13)
        XCTAssertFalse(elements(in: fixture.host).contains { $0.accessibilityRole() == .link })
        XCTAssertTrue(fixture.files.reads.isEmpty)
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        assertNoCombinedYAML(in: fixture)
        fixture.selection.file = "reference.md"
        await TestWait.until(failureMessage: "Body image exercises the real file provider") {
            fixture.host.layoutSubtreeIfNeeded()
            return fixture.files.finishedReads == 1
        }
        XCTAssertEqual(fixture.files.reads.count, 1)
    }

    func testNestedTableFitsItsCellAtAnyPaneWidth() async throws {
        let long = Array(repeating: "Long value wraps with readable words.", count: 12).joined(separator: " ")
        let fixture = try await mount("metadata: {long: '\(long)', sibling: visible}\nafter: next-row")
        defer { fixture.close() }
        let value = try cell(long, in: fixture)
        XCTAssertGreaterThan(value.height, 50)
        try assertInside(["long", "sibling", long, "visible"], fixture: fixture)
        XCTAssertLessThan(try cell("after", in: fixture).maxY, value.minY)
        let tight = try await mount("""
        metadata: {a-very-long-header-that-needs-to-wrap: '\(long)', b: short, c: [nested]}
        after: next
        """)
        defer { tight.close() }
        try await resize(tight, width: 360)
        try assertInside(["a-very-long-header-that-needs-to-wrap", long, "b", "short", "c", "nested"], fixture: tight)
        let wrapped = try cell(long, in: tight)
        XCTAssertGreaterThan(wrapped.height, 30)
        let lineHeight = try cell("short", in: tight).height
        XCTAssertLessThan(wrapped.height / lineHeight, CGFloat(long.count) / 4, "Never one glyph per line")
        XCTAssertLessThan(try cell("after", in: tight).maxY, wrapped.minY)
        let six = try await mount("metadata: [aa, bb, cc, dd, ee, ff]")
        defer { six.close() }
        try assertLine(["aa", "bb", "cc", "dd", "ee", "ff"], in: six)
        try await resize(six, width: 360)
        _ = try cell("[aa, bb, cc, dd, ee, ff]", in: six)
        for item in ["aa", "bb", "cc", "dd", "ee", "ff"] { XCTAssertTrue(cells(item, in: six).isEmpty) }
        try await resize(six, width: 644)
        try assertLine(["aa", "bb", "cc", "dd", "ee", "ff"], in: six)
        assertNoCombinedYAML(in: six)
    }

    func testOversizedAndEmptyEntriesKeepTheirYAMLText() async throws {
        let deep = (0..<40).reduce("leaf") { value, index in "{level\(index): \(value)}" }
        let fixture = try await mount("""
        six: [s1, s2, s3, s4, s5, s6]
        seven: [t1, t2, t3, t4, t5, t6, t7]
        split: {a: [1, 2, 3, 4], b: [5, 6, 7, 8]} # preserve this note
        empties: {a: [u1, u2, u3], b: [], c: {}, d: x}
        over: {a: [v1, v2, v3, v4], b: [], c: {}, d: y}
        three: {b3: {c3: {d3: deepest}}}
        four: {b4: {c4: {d4: {e4: too-deep}}}}
        empty: []
        empty-map: {}
        deep: \(deep)
        """)
        defer { fixture.close() }
        try assertLine(["s1", "s2", "s3", "s4", "s5", "s6"], in: fixture)
        for key in ["seven", "split", "over", "four", "empty", "empty-map", "deep"] {
            let row = try XCTUnwrap(fixture.snapshot.frontmatterRows.first { $0.key == key })
            _ = try cell(row.value, in: fixture)
        }
        for item in ["t1", "1", "8", "v1", "too-deep", "leaf"] { XCTAssertTrue(cells(item, in: fixture).isEmpty) }
        try assertMapping(["b3"], ["c3"], in: fixture)
        _ = try cell("deepest", in: fixture)
        try assertLine(["u1", "u2", "u3"], in: fixture)
        try assertMapping(["a", "b", "c", "d"], ["u1", "[]", "{}", "x"], in: fixture,
                          sameValueLine: false)
        let emptyList = cells("[]", in: fixture), emptyMap = cells("{}", in: fixture)
        XCTAssertEqual(emptyList.count, 2)
        XCTAssertEqual(emptyMap.count, 2)
        for key in ["six", "empties", "three"] {
            let row = try XCTUnwrap(fixture.snapshot.frontmatterRows.first { $0.key == key })
            XCTAssertTrue(cells(row.value, in: fixture).isEmpty)
        }
    }

    func testNestedTableDrawsItsFrameAndRules() throws {
        let parsed = SkillParser.parse("""
        ---
        metadata: {tags: "ADHD, Output Style, Productivity, Formatting", category: "productivity"}
        ---
        Body text.
        """)
        let renderer = ImageRenderer(content: SkillFrontmatterTable(rows: SkillFrontmatterRow.rows(from: parsed))
            .frame(width: 612).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func light(_ x: Int, _ y: Int) -> CGFloat {
            let offset = (y * width + x) * 4
            return CGFloat(Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 765
        }
        XCTAssertGreaterThan(height, 40)
        XCTAssertTrue((8..<width / 5).contains { x in (8..<height - 8).contains { light(x, $0) < 0.2 } },
                      "Capture contains visible key ink")
        // Straight rules have separator pixels for almost the entire height; letters do not.
        let verticals = (4..<width - 4).filter { x in
            let ys = (4..<height - 4).filter { y in light(x, y) + 0.025 < min(light(x - 3, y), light(x + 3, y)) }
            return ys.count > height - 40
        }
        let groups = verticals.reduce(into: [[Int]]()) { groups, x in
            if let last = groups.last?.last, x == last + 1 {
                groups[groups.count - 1].append(x)
            } else {
                groups.append([x])
            }
        }.compactMap { $0.first }
        XCTAssertGreaterThanOrEqual(groups.count, 4, "Outer divider plus nested left, middle and right rules")
        guard groups.count >= 4 else { return }
        let divider = groups[0], left = groups[1], middle = groups[2], right = groups[3]
        XCTAssertGreaterThan(left - divider, 8, "Nested frame is inset inside the outer value cell")
        XCTAssertGreaterThan(width - right, Int(DesignTokens.markdownTableCellHorizontal * 2), "Short table hugs its text")
        let horizontals = (4..<height - 4).filter { y in
            (left + 4..<right - 4).filter { x in
                light(x, y) + 0.025 < min(light(x, y - 3), light(x, y + 3))
            }.count > right - left - 24
        }
        XCTAssertGreaterThanOrEqual(horizontals.count, 3, "Frame top and bottom plus header rule")
        if let top = horizontals.first, let bottom = horizontals.last {
            XCTAssertGreaterThan((top...bottom).filter { light(middle, $0) < 0.95 }.count,
                                 bottom - top - 6, "Column rule spans header and values")
        }
    }

}

extension SkillPreviewNestedMetadataTests {
    func testShortNestedWordsStayOnOneLineWhileLongValuesWrap() async throws {
        let tags = "ADHD, Output Style, Productivity, Formatting"
        let fixture = try await mount("""
        description: A single line.
        metadata: {tags: "\(tags)", category: "productivity"}
        """)
        defer { fixture.close() }
        // Content's 16-point margins leave tables 460 and 360 points wide.
        for width: CGFloat in [492, 392] {
            try await resize(fixture, width: width)
            let lineHeight = try cell("A single line.", in: fixture).height
            XCTAssertEqual(try cell("productivity", in: fixture).height, lineHeight, accuracy: 0.5,
                           "A short word stays whole while the wider column can wrap")
            XCTAssertEqual(try cell("category", in: fixture).height, lineHeight, accuracy: 0.5,
                           "The short header also stays on one line")
            XCTAssertGreaterThan(try cell(tags, in: fixture).height, lineHeight,
                                 "The tags value wraps to make room for the short column")
            try assertInside(["tags", tags, "category", "productivity"], fixture: fixture)
        }
    }

    private func mount(_ header: String) async throws -> FrontmatterHost {
        let fixture = try FrontmatterHost(document: "---\n\(header)\n---\n\nBody text.")
        XCTAssertFalse(fixture.snapshot.frontmatterRows.isEmpty, "Fixture must have readable, trusted YAML")
        await TestWait.until(failureMessage: "Content preview must mount") {
            fixture.host.layoutSubtreeIfNeeded()
            return !self.cells("Body text.", in: fixture).isEmpty
        }
        return fixture
    }

    private func resize(_ fixture: FrontmatterHost, width: CGFloat) async throws {
        fixture.window.setContentSize(NSSize(width: width, height: 1200))
        await TestWait.until(failureMessage: "Content width follows its window") {
            fixture.host.layoutSubtreeIfNeeded()
            return abs(fixture.host.bounds.width - width) < 1
        }
        // Allow the conditional table/text view to update its accessibility children.
        await Task.yield()
        fixture.host.layoutSubtreeIfNeeded()
    }

    private func cells(_ value: String, in fixture: FrontmatterHost) -> [CGRect] {
        elements(in: fixture.host).filter {
            ($0.accessibilityValue() as? String) == value && $0.accessibilityFrame().width > 0
        }.map { $0.accessibilityFrame() }.sorted { $0.minX < $1.minX }
    }

    private func cell(_ value: String, in fixture: FrontmatterHost, file: StaticString = #filePath,
                      line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(cells(value, in: fixture).first, "Exact cell: \(value)", file: file, line: line)
    }

    private func assertLine(_ values: [String], in fixture: FrontmatterHost,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = try values.map { try cell($0, in: fixture, file: file, line: line) }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThan(left.maxX, right.minX, file: file, line: line)
            XCTAssertEqual(left.maxY, right.maxY, accuracy: 0.5, file: file, line: line)
        }
    }

    private func assertMapping(_ keys: [String], _ values: [String], in fixture: FrontmatterHost,
                               sameValueLine: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        try assertLine(keys, in: fixture, file: file, line: line)
        let headers = try keys.map { try cell($0, in: fixture, file: file, line: line) }
        let contents = try zip(headers, values).map { header, value in
            let nextX = headers.first(where: { $0.minX > header.minX + 0.5 })?.minX ?? .infinity
            return try XCTUnwrap(cells(value, in: fixture).filter {
                $0.minX >= header.minX - 0.5 && $0.minX < nextX && $0.maxY < header.minY
            }.max { $0.maxY < $1.maxY }, "Value belongs below its own key: \(value)", file: file, line: line)
        }
        for (header, value) in zip(headers, contents) {
            XCTAssertGreaterThan(header.minY, value.maxY, file: file, line: line)
            // A table inside a value adds its own padding; the value still belongs under its header.
            XCTAssertGreaterThanOrEqual(value.minX, header.minX - 0.5, file: file, line: line)
            if headers.count > 1, let next = headers.first(where: { $0.minX > header.minX + 0.5 }) {
                XCTAssertLessThan(value.minX, next.minX, file: file, line: line)
            }
        }
        if sameValueLine, let first = contents.first {
            for value in contents { XCTAssertEqual(value.maxY, first.maxY, accuracy: 0.5, file: file, line: line) }
        }
    }

    private func assertInside(_ values: [String], fixture: FrontmatterHost) throws {
        let rightEdge = fixture.host.accessibilityFrame().maxX - 16
        for value in values {
            XCTAssertLessThanOrEqual(try cell(value, in: fixture).maxX, rightEdge + 0.5, value)
        }
    }

    private func assertNoCombinedYAML(in fixture: FrontmatterHost) {
        for row in fixture.snapshot.frontmatterRows {
            XCTAssertTrue(cells(row.value, in: fixture).isEmpty, "No old combined YAML cell for \(row.key)")
        }
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
