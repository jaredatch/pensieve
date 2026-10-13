import XCTest
@testable import Pensieve

extension SkillDocumentSaveTests {
    func testGeneratedSaveShapesPreserveBytesRefuseInvalidEditsAndRepeatWithoutChange() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        var count = 0
        for ending in ["\n", "\r\n"] {
            for bom in ["", "\u{feff}"] {
                for body in ["", "\nBody\n"] {
                    for yaml in ["name: Test\ndescription: Before", "", "name: Test\ndescription: [",
                                 "name: Test\ndescription: before---after", "? [x, y]\n: z\nname: Test"] {
                        let header = "---\n" + yaml + "\n---\n"
                        let source = bom + (header + body).replacingOccurrences(of: "\n", with: ending)
                        let edits: [(String, Bool)] = [
                            (header + body + "Edited\n", true),
                            (header.replacingOccurrences(of: "Before", with: "After") + body, yaml.contains("Before")),
                            ("\n" + header + body, false),
                            ("  " + header + body, false),
                            ("---\n" + yaml + "\n" + body, false)
                        ]
                        for (text, accepted) in edits {
                            try fixture.write(source)
                            fixture.library.discardDraft(fixture.skill)
                            _ = fixture.library.editorBody(for: fixture.skill)
                            // Empty or unreadable YAML is changed to another unreadable block for the frontmatter edit.
                            let draft = bom + (text == header + body
                                ? text.replacingOccurrences(of: "---\n", with: "---\n# edit\n", options: [],
                                                            range: text.startIndex..<text.index(text.startIndex, offsetBy: 4))
                                : text)
                            fixture.library.noteEditorChanged(fixture.skill, body: draft)
                            let succeeded = fixture.library.saveDraft(fixture.skill)
                            XCTAssertEqual(succeeded, accepted, "case \(count): \(draft.debugDescription)")
                            if accepted {
                                let expected = draft.replacingOccurrences(of: "\n", with: ending)
                                XCTAssertEqual(Data(try fixture.read().utf8), Data(expected.utf8), "case \(count)")
                                fixture.library.noteEditorChanged(fixture.skill, body: draft)
                                XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
                                XCTAssertEqual(Data(try fixture.read().utf8), Data(expected.utf8), "repeat \(count)")
                            } else {
                                XCTAssertEqual(Data(try fixture.read().utf8), Data(source.utf8), "case \(count)")
                                XCTAssertEqual(fixture.library.drafts["test"]?.body, draft, "case \(count)")
                            }
                            count += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(count, 200)
    }

    func testGeneratedHeaderlessShapesKeepFallbackAndAdmitAddedFrontmatter() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        var count = 0
        for ending in ["\n", "\r\n"] {
            for bom in ["", "\u{feff}"] {
                for body in ["", "\nBody\n"] {
                    for yaml in ["name: Test\ndescription: Before", "", "name: Test\ndescription: [",
                                 "name: Test\ndescription: before---after", "? [x, y]\n: z\nname: Test"] {
                        let header = "---\n" + yaml + "\n---\n"
                        for text in ["---\n" + yaml + "\n" + body, "  " + header + body, "\n" + header + body] {
                            for addFrontmatter in [false, true] {
                                fixture.library.discardDraft(fixture.skill)
                                fixture.skill.skillDescription = "Before"
                                let source = bom + text.replacingOccurrences(of: "\n", with: ending)
                                try fixture.write(source)
                                XCTAssertEqual(fixture.library.editorBody(for: fixture.skill), source)
                                XCTAssertEqual(fixture.library.readBody(fixture.skill),
                                    text.trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: ending),
                                    "Rendered and token estimates retain their body-only read, case \(count)")
                                let draftText = addFrontmatter
                                    ? "---\nname: Test\ndescription: After\n---\n" + text
                                    : text + "Edited\n"
                                let draft = bom + draftText
                                fixture.library.noteEditorChanged(fixture.skill, body: draft)
                                XCTAssertTrue(fixture.library.saveDraft(fixture.skill), "case \(count)")
                                let suffix = String(text.reversed().prefix { $0 == "\n" }.reversed())
                                let expectedText = addFrontmatter ? draftText
                                    : "---\nname: Test\ndescription: Before\n---\n\n"
                                        + draftText.trimmingCharacters(in: .newlines) + suffix
                                let expected = bom + expectedText.replacingOccurrences(of: "\n", with: ending)
                                XCTAssertEqual(Data(try fixture.read().utf8), Data(expected.utf8), "case \(count)")
                                let saved = fixture.library.editorBody(for: fixture.skill)
                                fixture.library.noteEditorChanged(fixture.skill, body: saved)
                                XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
                                XCTAssertEqual(Data(try fixture.read().utf8), Data(expected.utf8), "repeat \(count)")
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(count, 240)
        try checkHeaderlessBoundaryEdits(fixture)
        try checkHeaderlessMissingDescription(fixture)
    }

    private func checkHeaderlessMissingDescription(_ fixture: DocumentSaveFixture) throws {
        for description in ["", " \t\n"] {
            fixture.library.discardDraft(fixture.skill)
            fixture.skill.skillDescription = description
            try fixture.write("Body")
            _ = fixture.library.editorBody(for: fixture.skill)
            fixture.library.noteEditorChanged(fixture.skill, body: "Edited")
            XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
            XCTAssertEqual(try fixture.read(), "---\nname: Test\ndescription: Test\n---\n\nEdited")
            XCTAssertEqual(fixture.skill.skillDescription, "Test", "The row follows the fallback header")
        }
    }

    private func checkHeaderlessBoundaryEdits(_ fixture: DocumentSaveFixture) throws {
        for source in ["Body", "\nBody\n"] {
            for draft in ["\n\nBody\n\n", "Body"] where draft != source {
                fixture.library.discardDraft(fixture.skill)
                try fixture.write(source)
                _ = fixture.library.editorBody(for: fixture.skill)
                fixture.library.noteEditorChanged(fixture.skill, body: draft)
                let token = fixture.library.reloadToken
                XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
                let saved = try fixture.read()
                XCTAssertTrue(saved.hasPrefix("---\nname: Test\n"), "A boundary edit still takes the legacy fallback write")
                XCTAssertEqual(fixture.library.editorBody(for: fixture.skill), saved)
                XCTAssertGreaterThan(fixture.library.reloadToken, token, "The mounted editor reloads canonical fallback text")
            }
        }
    }

    func testBodyAppendToUnreadableHeaderAtEOFAndUnicodeSpellingRemainEdits() throws {
        let fixture = try DocumentSaveFixture()
        defer { fixture.cleanup() }
        for source in ["---\nname: Test\ndescription: before---after\n---",
                       "---\nname: Test\ndescription: Caf\u{e9}\n---\nBody"] {
            try fixture.write(source)
            _ = fixture.library.editorBody(for: fixture.skill)
            let draft = source.contains("Caf")
                ? source.replacingOccurrences(of: "Caf\u{e9}", with: "Cafe\u{301}") + "\n"
                : source + "\nAdded body\n"
            fixture.library.noteEditorChanged(fixture.skill, body: draft)
            XCTAssertTrue(fixture.library.hasUnsavedChanges)
            XCTAssertTrue(fixture.library.saveDraft(fixture.skill))
            XCTAssertEqual(Data(try fixture.read().utf8), Data(draft.utf8))
        }
    }
}
