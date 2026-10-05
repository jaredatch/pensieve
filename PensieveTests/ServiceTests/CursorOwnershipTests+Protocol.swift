import XCTest
@testable import Pensieve

extension CursorOwnershipTests {
    func testServiceConformersMustChooseOwnershipExplicitly() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let products = checkout + "/DerivedData/Build/Products/Debug"
        let fixtures = [
            """
            struct Probe: LinkServiceProtocol {
                func link(skill: Skill, platform: PlatformTarget, projectPath: String?) throws {}
                func unlink(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { false }
                func isLinked(skill: Skill, platform: PlatformTarget, projectPath: String?) -> Bool { false }
                func linkPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String { "" }
                func targetPath(skill: Skill, platform: PlatformTarget, projectPath: String?) -> String { "" }
                func validateAll(skills: [Skill]) -> [BrokenLink] { [] }
                OWNERSHIP
            }
            """,
            """
            struct Probe: CursorCompilerProtocol {
                func compile(skill: Skill, projectPath: String?) throws {}
                func remove(skill: Skill, projectPath: String?) throws -> Bool { false }
                func isUpToDate(skill: Skill, projectPath: String?) -> Bool { false }
                func probeRulePresence(skill: Skill, projectPath: String?) throws -> Bool { false }
                func hasOwnershipMark(skill: Skill, projectPath: String?) throws -> Bool { false }
                func outputPath(skill: Skill, projectPath: String?) -> String { "" }
                OWNERSHIP
            }
            """
        ]
        for (index, fixture) in fixtures.enumerated() {
            let ownership = index == 0
                ? "func ownsArtifact(skill: Skill, platform: PlatformTarget, projectPath: String?) throws -> Bool { true }"
                : "func ownsArtifact(skill: Skill, projectPath: String?) throws -> Bool { true }"
            for explicit in [true, false] {
                let source = root + "/protocol-probe.swift"
                try files.writeFile(at: source, content: "@testable import Pensieve\n"
                    + fixture.replacingOccurrences(of: "OWNERSHIP", with: explicit ? ownership : ""))
                let (status, diagnostics) = try typecheckOwnershipProbe(source, products: products, checkout: checkout)
                if explicit {
                    XCTAssertEqual(status, 0, diagnostics)
                } else {
                    XCTAssertNotEqual(status, 0, "A conformer omitted ownership and still compiled")
                    XCTAssertTrue(diagnostics.contains("ownsArtifact"), diagnostics)
                }
            }
        }
    }
    func testRealizationKeepsCompilerBehindPlatformViewModel() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        let products = checkout + "/DerivedData/Build/Products/Debug"
        for bypass in [false, true] {
            let source = root + "/realization-probe.swift"
            let expression = bypass ? "vm.cursorCompiler" : "vm.isRealized(skill: skill, platform: .cursor)"
            try files.writeFile(at: source, content: "@testable import Pensieve\n"
                + "func probe(_ vm: PlatformViewModel, _ skill: Skill) { _ = \(expression) }\n")
            let (status, diagnostics) = try typecheckOwnershipProbe(source, products: products, checkout: checkout)
            if bypass {
                XCTAssertNotEqual(status, 0, "Reconciliation must use the view model's realization policy")
                XCTAssertTrue(diagnostics.contains("inaccessible"), diagnostics)
            } else { XCTAssertEqual(status, 0, diagnostics) }
        }
    }

    private func typecheckOwnershipProbe(_ source: String, products: String, checkout: String) throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", "-I", products, "-F", products,
            "-I", checkout + "/DerivedData/SourcePackages/checkouts/Yams/Sources/CYaml/include", source]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, diagnostics)
    }

}
