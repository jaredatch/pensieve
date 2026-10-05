import Foundation
import XCTest
@testable import Pensieve

/// Audits direct constructors throughout the test target without constructing a view model.
/// PlatformViewModel must name non-nil detection and deploy state; DeployStateStore must name its root.
/// Comments and strings are ignored. This is an argument guard, not a runtime filesystem sandbox:
/// dependency implementations and paths supplied through variables still need fixture review.
final class PlatformViewModelTestSafetyTests: XCTestCase {
    func testTestTargetInjectsDetectionAndIsolatedDeployState() throws {
        let files = FileService()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
        for path in try swiftFiles(in: root, using: files) {
            XCTAssertEqual(try missingArguments(in: files.readFile(at: path)), [], path)
        }
    }

    func testGuardRejectsEitherMissingDependencyAndDefaultStoreRoot() throws {
        XCTAssertEqual(try missingArguments(in: "PlatformViewModel(deployStateStore: store)"), ["agentDetection"])
        XCTAssertEqual(try missingArguments(in: "PlatformViewModel(agentDetection: stub)"), ["deployStateStore"])
        XCTAssertEqual(try missingArguments(in: "DeployStateStore(fileService: files)"), ["appSupportDir"])
        XCTAssertEqual(try missingArguments(in:
            "PlatformViewModel(agentDetection: stub, "
            + "deployStateStore: DeployStateStore(fileService: files, appSupportDir: root))"), [])
        XCTAssertEqual(try missingArguments(in:
            "PlatformViewModel(fileService: nested(agentDetection: stub), deployStateStore: store)"), ["agentDetection"])
    }

    func testGuardRejectsExplicitNilDependencies() throws {
        for value in ["nil", " nil ", "(nil)"] {
            XCTAssertEqual(try missingArguments(in:
                "PlatformViewModel(agentDetection: \(value), deployStateStore: store)"), ["agentDetection"])
            XCTAssertEqual(try missingArguments(in:
                "PlatformViewModel(agentDetection: stub, deployStateStore: \(value))"), ["deployStateStore"])
        }
        XCTAssertEqual(try missingArguments(in:
            "PlatformViewModel(agentDetection: nil, deployStateStore: nil)"), ["agentDetection", "deployStateStore"])
        XCTAssertEqual(try missingArguments(in:
            "PlatformViewModel(agentDetection: Stub(options: nil), deployStateStore: .memoryBacked)"), [])
    }

    private func swiftFiles(in root: String, using files: FileServiceProtocol) throws -> [String] {
        var paths: [String] = []
        for name in try files.listDirectory(at: root) {
            let path = root + "/" + name
            if files.directoryExists(at: path) {
                paths += try swiftFiles(in: path, using: files)
            } else if name.hasSuffix(".swift") {
                paths.append(path)
            }
        }
        return paths
    }

    private func missingArguments(in source: String) throws -> [String] {
        let literals = try NSRegularExpression(pattern: #"\"(?:\\.|[^\"\\])*\"|//[^\n]*|/\*[\s\S]*?\*/"#)
        let stripped = literals.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source),
                                                        withTemplate: " ")
        let constructors = try NSRegularExpression(pattern: #"\b(PlatformViewModel|DeployStateStore)\s*\("#)
        let text = stripped as NSString
        return constructors.matches(in: stripped, range: NSRange(location: 0, length: text.length)).flatMap { match in
            let type = text.substring(with: match.range(at: 1))
            let required = type == "PlatformViewModel" ? ["agentDetection", "deployStateStore"] : ["appSupportDir"]
            let arguments = topLevelArguments(in: text, startingAt: NSMaxRange(match.range))
            return required.filter { label in
                guard let value = arguments[label] else { return true }
                let literal = value.trimmingCharacters(in: .whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: "()")))
                return literal == "nil"
            }
        }
    }

    private func topLevelArguments(in text: NSString, startingAt start: Int) -> [String: String] {
        var depth = 1
        var position = start
        var argument = ""
        var parts: [String] = []
        while position < text.length, depth > 0 {
            let character = text.substring(with: NSRange(location: position, length: 1))
            if ["(", "[", "{"].contains(character) { depth += 1 }
            if [")", "]", "}"].contains(character) { depth -= 1 }
            if depth == 0 || (depth == 1 && character == ",") {
                parts.append(argument)
                argument = ""
            } else {
                argument += character
            }
            position += 1
        }
        var arguments: [String: String] = [:]
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let label = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            arguments[label] = String(part[part.index(after: colon)...])
        }
        return arguments
    }
}
