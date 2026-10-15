import XCTest
@testable import Pensieve

private struct ReceiptSweepCase {
    let source: String
    let text: String
    let safe: [String]
    let unsafe: [String]
    let malformed: Bool
}

extension SyncBytePreservationTests {
    func testGeneratedReceiptRewritePreservesSafePathsDropsUnsafeAndIsIdempotent() throws {
        try NativeTestWork.run { [self] in
            let safe = ["skills/x/assets/legacy", "skills/x/a [*?!#]", "skills/\u{0600}/\u{0301}asset",
                        "skills/x/references/SKILL.md", "skills/x/SKILL.mdx"]
            let unsafe = ["skills", "skills/x", "manifest", "manifest/categories", ".pensieve-retired-paths",
                          ".gitattributes", ".gitignore", "outside/child"] + manifestCaseVariants()
            let mixes: [[String]] = [[], safe, unsafe, safe + unsafe, unsafe + safe + safe]
            let faults = ["", "# Pensieve retired path: %%%",
                          "# Pensieve retired path: " + Data("skills/x/../bad".utf8).base64EncodedString()]
            var cases = 0
            for source in [".gitattributes", ".pensieve-retired-paths"] {
                for ending in ["\n", "\r\n", "\r", "mixed"] {
                    for finalNewline in [false, true] {
                        for paths in mixes {
                            for fault in faults {
                                let lines = paths.map { "# Pensieve retired path: " + Data($0.utf8).base64EncodedString() }
                                    + (fault.isEmpty ? [] : [fault])
                                let sample = ReceiptSweepCase(source: source,
                                    text: sweepText(lines, ending: ending, finalNewline: finalNewline),
                                    safe: Array(Set(paths.filter { safe.contains($0) })).sorted(),
                                    unsafe: Array(Set(paths.filter { unsafe.contains($0) })),
                                    malformed: !fault.isEmpty || (ending == "\r" && !lines.isEmpty
                                        && (finalNewline || lines.count > 1)))
                                try assertReceiptRewrite(sample, at: base + "/sweep-\(cases)")
                                cases += 1
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(cases, 240)
            try assertReceiptRecordBoundaries()
            try assertEmptyReceiptLinesAndIgnoreText()
        }
    }

    private func assertEmptyReceiptLinesAndIgnoreText() throws {
        let path = "skills/x/assets/legacy"
        let line = "# Pensieve retired path: " + Data(path.utf8).base64EncodedString()
        for ending in ["\n", "\r\n", "mixed"] {
            for finalNewline in [false, true] {
                for source in [".gitattributes", ".pensieve-retired-paths"] {
                    let sample = ReceiptSweepCase(source: source,
                        text: sweepText(["", line, "", line, ""], ending: ending, finalNewline: finalNewline),
                        safe: [path], unsafe: [], malformed: false)
                    try assertReceiptRewrite(sample, at: base + "/empty-lines-" + UUID().uuidString)
                }
                for input in ["", "\n\n", line, "*.bin\n!keep", String(repeating: "x", count: 1_048_577)] {
                    let root = base + "/ignore-text-" + UUID().uuidString
                    try files.createDirectory(at: root)
                    try TestPaths.git.initRepository(at: root)
                    let text = sweepText(input.components(separatedBy: "\n"), ending: ending, finalNewline: finalNewline)
                    try files.writeFile(at: root + "/.gitignore", content: text)
                    let spy = RetirementFileService()
                    try StoreIgnoreRules.prepare(at: root, files: spy)
                    XCTAssertEqual(try files.readFile(at: root + "/.gitignore"), ".DS_Store\n")
                    spy.writes.removeAll()
                    try StoreIgnoreRules.prepare(at: root, files: spy)
                    XCTAssertTrue(spy.writes.isEmpty)
                }
            }
        }
    }

    private func assertReceiptRecordBoundaries() throws {
        let line = "# Pensieve retired path: " + Data("skills/a/b".utf8).base64EncodedString()
        for source in [".gitattributes", ".pensieve-retired-paths"] {
            for separator in ["\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
                for tail in [false, true] {
                    let text = tail ? line + separator + "junk\n" : "x" + separator + line + "\n"
                    let sample = ReceiptSweepCase(source: source, text: text, safe: [], unsafe: [], malformed: tail)
                    try assertReceiptRewrite(sample, at: base + "/record-boundary-" + UUID().uuidString)
                }
            }
        }
    }

    private func manifestCaseVariants() -> [String] {
        let spellings = "SKILL.md".reduce([""]) { prefixes, letter in
            prefixes.flatMap { prefix in
                Set([String(letter).lowercased(), String(letter).uppercased()]).sorted().map { prefix + $0 }
            }
        }
        XCTAssertEqual(spellings.count, 128)
        return spellings.map { "skills/x/" + $0 }
    }

    private func sweepText(_ lines: [String], ending: String, finalNewline: Bool) -> String {
        lines.enumerated().map { index, line in
            guard index < lines.count - 1 || finalNewline else { return line }
            return line + (ending == "mixed" ? (index.isMultiple(of: 2) ? "\n" : "\r\n") : ending)
        }.joined()
    }

    private func assertReceiptRewrite(_ sample: ReceiptSweepCase, at store: String) throws {
        try files.createDirectory(at: store)
        try TestPaths.git.initRepository(at: store)
        try files.writeFile(at: store + "/" + sample.source, content: sample.text)
        let spy = RetirementFileService()
        var dropped: [String] = []
        if sample.malformed {
            XCTAssertThrowsError(try StoreIgnoreRules.prepare(at: store, files: spy, log: { dropped.append($0) }), store)
            XCTAssertTrue(spy.writes.isEmpty)
            XCTAssertTrue(dropped.isEmpty, "A malformed source must fail before dropping anything")
            return
        }
        XCTAssertEqual(try StoreIgnoreRules.retiredPaths(at: store, files: spy), sample.safe,
                       "Read \(store) must ignore unsafe receipts immediately")
        try StoreIgnoreRules.prepare(at: store, files: spy, log: { dropped.append($0) })
        XCTAssertEqual(try StoreIgnoreRules.retiredPaths(at: store, files: files), sample.safe)
        XCTAssertEqual(Set(dropped), Set(sample.unsafe), "The log must name each dropped path")
        if sample.source == ".pensieve-retired-paths" || !sample.safe.isEmpty || !sample.unsafe.isEmpty {
            let canonical = sample.safe.map {
                "# Pensieve retired path: " + Data($0.utf8).base64EncodedString() + "\n"
            }.joined()
            XCTAssertEqual(try files.readFile(at: store + "/.pensieve-retired-paths"), canonical)
        }
        spy.writes.removeAll()
        dropped.removeAll()
        try StoreIgnoreRules.prepare(at: store, files: spy, log: { dropped.append($0) })
        XCTAssertTrue(spy.writes.isEmpty, "Second pass \(store) must write nothing")
        XCTAssertTrue(dropped.isEmpty)
    }
}
