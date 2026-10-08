import XCTest
@testable import Pensieve

/// Architecture contract: both Resolve controls consume SyncModel.canResolve, which additionally
/// fences an in-flight cycle. The model's transition tests own the predicate's behavior. The XCTest
/// host exposes these SwiftUI controls as AXUnknown, so this check owns their actual bindings.
final class SyncStatusWiringTests: XCTestCase {
    func testResolveControlsReadCentralEligibility() throws {
        let footer = try source("Pensieve/Views/SyncViews/SyncStatusView.swift")
        let header = try source("Pensieve/Views/SkillViews/Detail/SkillDetailHeader.swift")
        let detail = try source("Pensieve/Views/MainWindow/DetailView.swift")
        let owner = #"[A-Za-z_][A-Za-z0-9_]*"#
        XCTAssertEqual(matches(#"canResolve\s*:\s*"# + owner + #"\.canResolve\s*,"#, in: footer), 1,
                       "the footer must read canResolve, including its in-flight fence")
        XCTAssertEqual(matches(#"\.disabled\s*\(\s*!\s*"# + owner + #"\.canResolve\s*\)"#, in: header), 1,
                       "the detail Resolve button must read the same eligibility")
        let headerModel = try XCTUnwrap(capture(#"(?:let|var)\s+(\w+)\s*:\s*SyncModel\b"#, in: header))
        let detailModel = try XCTUnwrap(capture(#"(?:let|var)\s+(\w+)\s*:\s*SyncModel\b"#, in: detail))
        XCTAssertEqual(matches(headerModel + #"\s*:\s*"# + detailModel + #"\s*,"#, in: detail), 1,
                       "DetailView must pass its live sync model to the header")
    }

    func testBranchlessCopyIsWiredIntoDetailBanner() throws {
        let header = try source("Pensieve/Views/SkillViews/Detail/SkillDetailHeader.swift")
        let binding = #"if\s+[A-Za-z_][A-Za-z0-9_]*\.state\s*==\s*\.branchless\s*\{\s*Label\("#
            + #"\"Can't sync yet: the store has no branch\""#
        XCTAssertEqual(matches(binding, in: header), 1, "the branchless status must reach the detail banner")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try FileService().readFile(at: root.appendingPathComponent(path).path)
        // Comments supply no wiring evidence. Whitespace and the local model variable's name are free.
        return text.replacingOccurrences(of: #"(?s)/\*.*?\*/|(?m)//[^\n]*"#, with: "",
                                         options: .regularExpression)
    }

    private func capture(_ pattern: String, in source: String) -> String? {
        guard let match = (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: source, range: NSRange(source.startIndex..., in: source)),
            let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private func matches(_ pattern: String, in source: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
            in: source, range: NSRange(source.startIndex..., in: source)) ?? 0
    }
}
