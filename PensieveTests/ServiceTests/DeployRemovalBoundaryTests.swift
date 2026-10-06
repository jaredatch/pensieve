import XCTest
@testable import Pensieve

final class DeployRemovalBoundaryTests: XCTestCase {
    /// Textual architecture guard over the current removal owners and all deploy-state retirements.
    /// It follows declarations across extension files, allowing file moves and splits. Aliased calls
    /// and deliberately hidden deletions are outside this audit, like the other source guards.
    func testRemovalOwnersUseOneArtifactAndStateSink() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = try swiftSources(root: root)
        let primitiveName = String(describing: DeployRemovalService.self)
        let primitive = try XCTUnwrap(sources.first { _, source in
            source.range(of: "\\bstruct\\s+" + primitiveName + "\\b", options: .regularExpression) != nil
        }?.key)
        let owners: [Any.Type] = [LinkService.self, CursorCompiler.self, PlatformViewModel.self,
                                  ProjectRemovalPlan.self, DeployReconciler.self]
        let ownerNames = owners.map { String(describing: $0) }.joined(separator: "|")
        let declaration = "\\b(?:class|struct|extension)\\s+(?:" + ownerNames + ")\\b"
        var artifactBypasses: [String] = [], stateSinks: [String] = [], operationSinks: [String] = []
        for (path, source) in sources {
            if source.range(of: declaration, options: .regularExpression) != nil,
               source.range(of: "\\.\\s*deleteFile\\s*\\(", options: .regularExpression) != nil {
                artifactBypasses.append(path)
            }
            if source.range(of: "\\.\\s*remove\\s*\\(\\s*artifactPaths?\\s*:", options: .regularExpression) != nil {
                stateSinks.append(path)
            }
            if source.range(of: "\\.\\s*delete\\s*\\(\\s*\\)", options: .regularExpression) != nil {
                operationSinks.append(path)
            }
        }
        XCTAssertTrue(artifactBypasses.isEmpty, "Artifact deletes bypass the primitive: \(artifactBypasses.sorted())")
        XCTAssertEqual(stateSinks, [primitive], "Deploy-state retirement belongs to the removal primitive")
        XCTAssertEqual(operationSinks, [primitive], "Only the primitive invokes prepared artifact deletes")
    }

    private func swiftSources(root: URL) throws -> [String: String] {
        var sources: [String: String] = [:]
        for directory in ["Pensieve", "PensieveDaemon"] {
            let folder = root.appendingPathComponent(directory)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: nil)?.allObjects as? [URL])
            for file in files where file.pathExtension == "swift" {
                sources[file.path] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        return sources
    }
}
