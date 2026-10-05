import Darwin
import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    func testGeneratedMarkTextShapes() throws {
        var cases = 0
        let path = root + "/text.mdc"
        for ending in ["\n", "\r\n"] {
            for bom in ["", "\u{FEFF}"] {
                for framing in ["none", "unterminated", "empty", "closed"] {
                    for position in ["frontmatter", "body", "none"] {
                        for value in ["managed", "other", ""] {
                            for size in ["small", "large-body", "large-header"] {
                                for empty in [false, true] {
                                    let text = markText(framing: framing, position: position, value: value,
                                                        size: size, ending: ending)
                                    try files.writeFile(at: path, content: empty ? "" : bom + text)
                                    let data = try files.readRegularFileHeader(
                                        at: path, maximumBytes: DeployArtifactOwnership.maximumHeaderBytes)
                                    let expected = !empty && framing == "closed" && position == "frontmatter"
                                        && value == "managed" && size != "large-header"
                                    XCTAssertEqual(CursorMDC.hasOwnershipMark(in: data), expected,
                                                   "\(framing) / \(position) / \(value) / \(size) / BOM=\(!bom.isEmpty)")
                                    cases += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 864)
    }

    private func markText(framing: String, position: String, value: String, size: String, ending: String) -> String {
        let mark = "# pensieve: " + value
        var header = position == "frontmatter" ? mark + ending : ""
        if size == "large-header" {
            header = String(repeating: "x", count: DeployArtifactOwnership.maximumHeaderBytes) + ending + header
        }
        let body = (position == "body" ? mark + ending : "")
            + (size == "large-body" ? String(repeating: "b", count: 70_000) : "body")
        switch framing {
        case "closed": return "---" + ending + header + "---" + ending + body
        case "unterminated": return "---" + ending + header + body
        case "empty": return "---" + ending + "---" + ending + body
        default: return header + body
        }
    }

    func testHeaderReadStopsBeforeLargeBodyAndHonorsCap() throws {
        let path = root + "/bounded.mdc"
        let cap = DeployArtifactOwnership.maximumHeaderBytes
        for text in ["---\n# pensieve: managed\n---\n" + String(repeating: "b", count: cap * 2),
                     "---\n" + String(repeating: "x", count: cap * 2)] {
            try files.writeFile(at: path, content: text)
            var consumed = 0
            let data = try files.readRegularFileHeader(at: path, maximumBytes: cap) { descriptor, bytes, count in
                let result = Darwin.read(descriptor, bytes, count)
                consumed += max(result, 0)
                return result
            }
            if text.contains("managed") {
                XCTAssertTrue(CursorMDC.hasOwnershipMark(in: data))
                XCTAssertLessThanOrEqual(consumed, 512)
                XCTAssertEqual(String(data: data, encoding: .utf8), "---\n# pensieve: managed\n---\n")
            } else {
                XCTAssertFalse(CursorMDC.hasOwnershipMark(in: data))
                XCTAssertEqual(consumed, cap)
            }
        }
    }

    func testTruncatedFenceInvalidUTF8AndNestedMarksAreNotAuthority() throws {
        let cap = DeployArtifactOwnership.maximumHeaderBytes
        let start = "---\n# pensieve: managed\n"
        let truncated = start + String(repeating: "x", count: cap - start.utf8.count - 4) + "\n---evil\n"
        let path = root + "/truncated.mdc"
        try files.writeFile(at: path, content: truncated)
        let data = try files.readRegularFileHeader(at: path, maximumBytes: cap)
        XCTAssertFalse(CursorMDC.hasOwnershipMark(in: data))
        for bytes in [Data([0xFF]), Data("---\n  # pensieve: managed\n---\n".utf8),
                      Data("---\n# pensieve: managed-extra\n---\n".utf8)] {
            XCTAssertFalse(CursorMDC.hasOwnershipMark(in: bytes))
        }
    }
}
