import XCTest
@testable import Pensieve

/// Textual API audit: checks the closure exposure and delegation requested by the stage read.
/// Runtime deploy tests separately prove filesystem behavior. Comments are excluded from the audit.
final class FileServiceProjectContractTests: XCTestCase {
    private let files = FileService()
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testRecursiveWritersDelegateToTheNonrecursiveImplementations() throws {
        let source = try serviceSource()
        let write = try body("writeFile", in: source)
        XCTAssertTrue(write.contains("writeFileWithoutParents("), "Recursive text writes must delegate")
        XCTAssertFalse(write.contains("content.write("), "One text-write implementation")
        let link = try body("createSymlink", in: source)
        XCTAssertTrue(link.contains("createSymlinkWithoutParents("), "Recursive links must delegate")
        XCTAssertFalse(link.contains("createSymbolicLink("), "One link-write implementation")
        XCTAssertFalse(link.contains("removeItem("), "Replacement belongs to the shared writer")
    }

    func testProjectWriterCannotAcceptAnArbitraryWriteClosure() throws {
        let source = try serviceSource()
        let declarations = source.components(separatedBy: "\n").filter {
            $0.contains("func ") && !$0.contains("private func ")
        }
        XCTAssertFalse(declarations.contains { $0.contains("write: () throws -> Void") },
                       "An exposed project writer must take content or a link target, never an arbitrary write")
    }

    func testMkdirSeamCannotReplaceTheCreateOperation() throws {
        let source = try serviceSource()
        XCTAssertFalse(source.contains("create: (String) throws -> Void"),
                       "The race seam may observe before mkdir but cannot supply mkdir")
    }

    private func serviceSource() throws -> String {
        let directory = sourceRoot.appendingPathComponent("Pensieve/Services").path
        return try files.listDirectory(at: directory).sorted()
            .filter { $0.hasPrefix("FileService") && $0.hasSuffix(".swift") }
            .map { try files.readFile(at: directory + "/" + $0) }.joined(separator: "\n")
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func body(_ name: String, in source: String) throws -> String {
        let declaration = try XCTUnwrap(source.range(
            of: "func " + name + #"\([^\n]*\) throws \{"#, options: .regularExpression))
        let opening = source.index(before: declaration.upperBound)
        var depth = 1
        var index = source.index(after: opening)
        let start = index
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            if depth == 0 { return String(source[start..<index]) }
            index = source.index(after: index)
        }
        XCTFail("Unclosed function \(name)")
        throw CocoaError(.fileReadCorruptFile)
    }
}
