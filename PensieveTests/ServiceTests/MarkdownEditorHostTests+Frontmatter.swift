import XCTest
@testable import Pensieve

extension MarkdownEditorHostTests {
    func testClosedFrontmatterUsesYAMLStylesAndKeepsMarkdownBodyStyles() {
        let (coordinator, window) = makeReadyEditor()
        defer { window.close() }
        let body = "# Heading\n**bold** and *italic* with `code` and [link](https://example.com)\n"
            + "- item\n\n---\n\n```yaml\n- code\n```"
        for theme in ["light", "dark"] {
            coordinator.setTheme(theme)
            coordinator.setBody(body)
            let bodyStyles = lineStyles(coordinator)
            let blue = theme == "light" ? "rgb(15, 93, 181)" : "rgb(111, 179, 255)"
            let brown = theme == "light" ? "rgb(138, 90, 43)" : "rgb(217, 160, 102)"
            let primary = theme == "light" ? "rgb(29, 29, 31)" : "rgb(230, 230, 230)"
            for opening in ["---", "\u{feff}--- \t"] {
                for ending in ["\n", "\r\n"] {
                    let header = [opening, "name: Example # trailing", "description: \"quoted\"", "# comment",
                                  "metadata:", "  version: '1.0'", "items: [one, two]", "tools:", "  - one", "long: |",
                                  "  # literal text", "---\t "].joined(separator: ending)
                    let document = header + ending + body
                    XCTAssertNotNil(SkillParser.parse(document, retainingBOM: true).preservedFile)
                    coordinator.setBody(document)
                    XCTAssertEqual(tokenStyle(coordinator, line: 1, text: "---"), "rgb(127, 132, 142)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 2, text: "name"), "\(blue)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 2, text: "Example"), "\(primary)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 2, text: "# trailing"), "rgb(127, 132, 142)|12px|400|italic")
                    XCTAssertEqual(tokenStyle(coordinator, line: 3, text: "\"quoted\""), "\(brown)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 4, text: "# comment"), "rgb(127, 132, 142)|12px|400|italic")
                    XCTAssertEqual(tokenStyle(coordinator, line: 6, text: "version"), "\(blue)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 6, text: "'1.0'"), "\(brown)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 11, text: "# literal"), "\(primary)|12px|400|normal")
                    XCTAssertEqual(tokenStyle(coordinator, line: 12, text: "---"), "rgb(127, 132, 142)|12px|400|normal")
                    let styles = lineStyles(coordinator)
                    XCTAssertEqual(Array(styles.dropFirst(12)), bodyStyles, "Body style changed: \(theme), \(opening)")
                    XCTAssertTrue(styles.prefix(12).allSatisfy {
                        $0.hasPrefix("0px;") && !$0.contains("|700|") && !$0.contains("15px") && !$0.contains("17px")
                    })
                }
            }
            for document in ["---\n---", "---\nname: End\n---"] {
                coordinator.setBody(document)
                XCTAssertEqual(tokenStyle(coordinator, line: 1, text: "---"), "rgb(127, 132, 142)|12px|400|normal")
            }
        }
    }

    func testUnrecognizedFrontmatterKeepsMarkdownStyling() {
        let (coordinator, window) = makeReadyEditor()
        defer { window.close() }
        let shapes = [
            " ---\nname: Example\n---", "\t---\nname: Example\n---",
            "\n---\nname: Example\n---", "\u{feff}\u{feff}---\nname: Example\n---",
            "---\u{a0}\nname: Example\n---", "----\nname: Example\n---",
            "---\nname: Example\n ---", "---\nname: Example\n...", "---\nname: Example"
        ]
        for shape in shapes {
            let document = shape + "\n\n# Markdown heading"
            XCTAssertNil(SkillParser.parse(document, retainingBOM: true).preservedFile, shape)
            coordinator.setBody(document)
            guard let index = document.components(separatedBy: "\n").firstIndex(of: "name: Example") else {
                return XCTFail("Missing fixture key")
            }
            let line = index + 1
            let expected = shape.hasSuffix("---")
                ? "rgb(15, 93, 181)|15px|700|normal" : "rgb(29, 29, 31)|12px|400|normal"
            XCTAssertEqual(tokenStyle(coordinator, line: line, text: "name"), expected, shape)
            XCTAssertEqual(tokenStyle(coordinator, line: lineStyles(coordinator).count, text: "Markdown"),
                           "rgb(15, 93, 181)|17px|700|normal", shape)
        }
    }

    func testTypingAClosingFenceReparsesTheOpeningAndUndoRestoresMarkdown() {
        let (coordinator, window) = makeReadyEditor()
        defer { window.close() }
        let text = "---\nname: Example\ndescription: |\n  " + String(repeating: "long text ", count: 100) + "\n# comment"
        coordinator.setBody(text)
        XCTAssertEqual(tokenStyle(coordinator, line: 5, text: "# comment"), "rgb(15, 93, 181)|17px|700|normal")
        XCTAssertEqual(probe(coordinator, "(function(){var c=document.querySelector('.cm-content');c.focus();"
            + "var s=window.getSelection();s.selectAllChildren(c);s.collapseToEnd();"
            + "return String(document.execCommand('insertText',false,'\\n---'));})()"), "true")
        XCTAssertEqual(probe(coordinator, "window.Editor.getContent()"), text + "\n---")
        XCTAssertEqual(tokenStyle(coordinator, line: 2, text: "name"), "rgb(15, 93, 181)|12px|400|normal")
        XCTAssertEqual(tokenStyle(coordinator, line: 5, text: "# comment"), "rgb(127, 132, 142)|12px|400|italic")
        XCTAssertEqual(probe(coordinator, "window.Editor.undo()"), "true")
        XCTAssertEqual(probe(coordinator, "window.Editor.getContent()"), text)
        XCTAssertEqual(tokenStyle(coordinator, line: 5, text: "# comment"), "rgb(15, 93, 181)|17px|700|normal")
    }

    private func tokenStyle(_ coordinator: MarkdownEditorWebView.Coordinator, line: Int, text: String) -> String {
        let literal = EditorTransport.jsonString(for: text)
        return probe(coordinator, "(function(){var l=document.querySelectorAll('.cm-line')[\(line - 1)];"
            + "if(!l)return 'missing line';var i=l.textContent.indexOf(\(literal));if(i<0)return 'missing text';"
            + "var w=document.createTreeWalker(l,NodeFilter.SHOW_TEXT),n;while(n=w.nextNode()){"
            + "if(i<n.length){var s=getComputedStyle(n.parentElement);"
            + "return [s.color,s.fontSize,s.fontWeight,s.fontStyle].join('|')}i-=n.length}return 'missing style';})()")
    }

    private func lineStyles(_ coordinator: MarkdownEditorWebView.Coordinator) -> [String] {
        let json = probe(coordinator, "JSON.stringify(Array.from(document.querySelectorAll('.cm-line'),function(l){"
            + "var w=document.createTreeWalker(l,NodeFilter.SHOW_TEXT),n,r='';while(n=w.nextNode()){"
            + "var s=getComputedStyle(n.parentElement);var v=[s.color,s.fontSize,s.lineHeight,s.fontWeight,"
            + "s.fontStyle,s.backgroundColor,s.borderRadius,s.textDecorationLine].join('|');"
            + "r+=Array.from(n.textContent,function(c){return c+':'+v}).join(';')}"
            + "return getComputedStyle(l).textIndent+';'+r}))")
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? ["invalid style probe: " + json]
    }
}
