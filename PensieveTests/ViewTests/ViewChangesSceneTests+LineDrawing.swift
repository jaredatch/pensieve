import AppKit
import SwiftUI
import XCTest
@testable import Pensieve

extension ViewChangesSceneTests {
    func testAChangeWithSeveralEditsDrawsEveryLine() async throws {
        var before = (1...27).map { "line \($0)" }
        for index in [1, 11, 14] { before[index] = "repeated" }
        for index in [2, 12, 24] { before[index] = "" }
        var after = before
        after[0] = "changed first"
        after[13] = "changed middle"
        after.removeLast()
        let preview = try drawingPreview(old: before.joined(separator: "\n") + "\n",
                                         new: after.joined(separator: "\n") + "\n")
        let diff = try XCTUnwrap(preview.files.first?.diff)
        XCTAssertEqual(diff.hunks.count, 3)
        let counts = diff.hunks.map { $0.lines.count }
        guard counts.count == 3 else { return }
        XCTAssertGreaterThan(counts[1], counts[0])
        XCTAssertLessThan(counts[2], counts[0])
        XCTAssertLessThanOrEqual(counts.reduce(3, +), 25)
        let bodies = diff.hunks.map { $0.lines.map { drawingBody($0.text) } }
        XCTAssertTrue(bodies[0].contains("repeated"))
        XCTAssertEqual(bodies[1].filter { $0 == "repeated" }.count, 2)
        XCTAssertGreaterThanOrEqual(bodies.flatMap { $0 }.filter(\.isEmpty).count, 3)
        XCTAssertGreaterThanOrEqual(bodies.filter { $0.contains("") }.count, 2)

        try await expectDrawing(preview)
    }

    func testALineEndingChangeDrawsItsNoteUnderEveryLine() async throws {
        let preview = try drawingPreview(old: "first\nsecond\nthird\n", new: "first\r\nsecond\r\nthird\r\n")
        let file = try XCTUnwrap(preview.files.first)
        let diff = try XCTUnwrap(file.diff)
        XCTAssertEqual(diff.hunks.count, 1)
        let hunk = try XCTUnwrap(diff.hunks.first)
        XCTAssertEqual(hunk.lines.map(\.kind), [.removed, .removed, .removed, .added, .added, .added])
        let note = "Line ending changed: LF → CRLF"
        XCTAssertEqual(diff.hunks.map { ViewChangesPresentation.lineNotes($0.lines) },
                       [[3: [note], 4: [note], 5: [note]]])
        try await expectDrawing(preview)

        let unterminated = try drawingPreview(old: "old last", new: "new last")
        XCTAssertEqual(unterminated.files.first?.diff?.hunks.map { ViewChangesPresentation.lineNotes($0.lines) },
                       [[0: ["\\ No newline at end of file"], 1: ["\\ No newline at end of file"]]])
        try await expectDrawing(unterminated)
    }

    private func drawingPreview(old: String, new: String) throws -> PinnedSkillDiff {
        try PinnedSkillDiff.build(comparison: FileTreeComparison(changes: [
            FileTreeChange(path: "SKILL.md", kind: .modified, content: .text(old: old, new: new))
        ], unreadFileCount: 0, bytesRead: old.utf8.count + new.utf8.count))
    }

    private func expectDrawing(_ preview: PinnedSkillDiff,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try UpdateReviewFixture()
        defer { try? fixture.cleanup() }
        let skill = try fixture.skill("line-drawing")
        let row = try UpdatesViewModel.makeRow(skill: skill, driftedLocally: false)
        let model = ViewChangesViewModel(library: fixture.library,
                                        operations: fixture.operations(rows: [row], preview: preview))
        let window = makeWindow(id: "line-drawing")
        let host = NSHostingView(rootView: ViewChangesView(model: model, library: fixture.library, onUpdate: {})
            .modelContainer(fixture.container))
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); window.contentView = nil }
        model.open(skillID: skill.id, context: fixture.context)
        await TestWait.until(failureMessage: "Drawing preview did not load") { model.state != .loading }
        guard case .loaded = model.state else {
            XCTFail("Drawing preview failed to load: \(model.state)", file: file, line: line)
            return
        }
        await TestWait.until(failureMessage: "The live diff render tree did not appear") {
            RenderedViewTestSupport.values(in: host).compactMap { $0 as? Text }
                .flatMap(RenderedViewTestSupport.strings).contains { $0.hasPrefix("@@ ") }
        }
        let drawn = drawingRows(in: host)
        XCTAssertFalse(drawn.isEmpty, "Missing live diff render debug data", file: file, line: line)
        let selected = try XCTUnwrap(preview.files.first)
        let diff = try XCTUnwrap(selected.diff)
        let notes = diff.hunks.map { ViewChangesPresentation.lineNotes($0.lines) }
        var expected: [DiffDrawingRow] = []
        for (hunkIndex, hunk) in diff.hunks.enumerated() {
            expected.append(.header(hunk.header))
            for (index, line) in hunk.lines.enumerated() {
                let marker = line.kind == .added ? "+" : line.kind == .removed ? "−" : ""
                expected.append(.line(old: line.oldLineNumber, new: line.newLineNumber,
                                      marker: marker, text: drawingBody(line.text)))
                expected += (notes[hunkIndex][index] ?? []).map(DiffDrawingRow.note)
            }
        }
        XCTAssertEqual(drawn, expected,
                       "Every header, numbered line and following note must draw in order", file: file, line: line)
    }

    private func drawingRows(in host: NSView) -> [DiffDrawingRow] {
        let rendered = RenderedViewTestSupport.layoutValues(in: host)
        let drawn = rendered.compactMap { value -> (row: DiffDrawingRow, frame: CGRect?)? in
            if String(reflecting: type(of: value.value)).hasPrefix("SwiftUI.HStack<") {
                let labels = drawingStrings(value.value, depth: 20)
                guard labels.count == 4,
                      labels[0].isEmpty || Int(labels[0]) != nil,
                      labels[1].isEmpty || Int(labels[1]) != nil,
                      ["", "+", "−"].contains(labels[2]) else { return nil }
                if labels[3].hasPrefix("@@ ") {
                    return (.header(labels[3]), value.frame)
                }
                return (.line(old: Int(labels[0]), new: Int(labels[1]), marker: labels[2], text: labels[3]), value.frame)
            }
            if let text = value.value as? Text,
               let note = RenderedViewTestSupport.strings(in: text).first,
               note.hasPrefix("Line ending changed:") || note == "\\ No newline at end of file" {
                return (.note(note), value.frame)
            }
            return nil
        }
        // Geometry owns visible order when supplied. Older SDKs may only expose traversal order.
        let ordered = drawn.allSatisfy { $0.frame != nil }
            ? drawn.sorted { $0.frame!.minY < $1.frame!.minY } : drawn
        return ordered.map(\.row)
    }

    private func drawingStrings(_ value: Any, depth: Int) -> [String] {
        if let text = value as? Text { return RenderedViewTestSupport.strings(in: text) }
        guard depth > 0, Mirror(reflecting: value).displayStyle != .class else { return [] }
        return Mirror(reflecting: value).children.flatMap { drawingStrings($0.value, depth: depth - 1) }
    }

    private func drawingBody(_ text: String) -> String {
        text.unicodeScalars.last?.value == 10 ? String(text.dropLast()) : text
    }
}

private enum DiffDrawingRow: Equatable {
    case header(String)
    case line(old: Int?, new: Int?, marker: String, text: String)
    case note(String)
}
